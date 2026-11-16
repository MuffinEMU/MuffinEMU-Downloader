import Foundation

/// Orchestrates a full title download from Nintendo's public NUS/CCS endpoints: TMD, ticket
/// (or a locally-generated fallback), certificate chain, every content + its H3 hash file, then
/// (optionally) decryption/extraction to a playable layout. This is the direct SwiftUI-app-facing
/// entry point — everything else in the package is a building block this type composes.
public final class Downloader {
    private let session = NUSSession()
    private let keyStore: KeyStore

    public enum DownloaderError: Error {
        case invalidTitleIDHex
    }

    public init(keyStore: KeyStore = .shared) {
        self.keyStore = keyStore
    }

    public struct Options {
        public var titleIDHex: String
        public var outputDirectory: URL
        public var version: Int = versionLatest
        public var decryptContents: Bool = false
        public var deleteEncryptedAfterDecrypt: Bool = false
        public var decryptOutputDirectory: URL?
        public var titleDatabase: [TitleEntry] = []

        public init(titleIDHex: String, outputDirectory: URL, version: Int = versionLatest, decryptContents: Bool = false, deleteEncryptedAfterDecrypt: Bool = false, decryptOutputDirectory: URL? = nil, titleDatabase: [TitleEntry] = []) {
            self.titleIDHex = titleIDHex
            self.outputDirectory = outputDirectory
            self.version = version
            self.decryptContents = decryptContents
            self.deleteEncryptedAfterDecrypt = deleteEncryptedAfterDecrypt
            self.decryptOutputDirectory = decryptOutputDirectory
            self.titleDatabase = titleDatabase
        }
    }

    public func downloadTitle(_ options: Options, progress: ProgressReporter?) async throws {
        guard let titleID = UInt64(options.titleIDHex, radix: 16) else { throw DownloaderError.invalidTitleIDHex }
        let entry = TitleDatabaseHelpers.entry(forTitleID: titleID, in: options.titleDatabase)

        progress?.resetTotals()
        progress?.setGameTitle(entry?.name.isEmpty == false ? entry!.name : options.titleIDHex)
        guard await progress?.waitIfPaused() ?? true else { return }

        let outputDir = options.outputDirectory
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let baseURL = "http://ccs.cdn.c.shop.nintendowifi.net/ccs/download/\(options.titleIDHex)"

        // TMD
        let tmdURL = options.version >= 0 ? "\(baseURL)/tmd.\(options.version)" : "\(baseURL)/tmd"
        let tmdPath = outputDir.appendingPathComponent("title.tmd")
        try await session.downloadFile(
            urlString: tmdURL, to: tmdPath,
            options: DownloadOptions(doRetries: true, allowResume: true, validate: { url in
                try ContentValidation.validateTMDFile(at: url, expectedTitleID: titleID)
            }),
            progress: progress
        )

        let tmdData = try Data(contentsOf: tmdPath)
        let tmd = try TMDFormat.parse([UInt8](tmdData))

        // Ticket (real, or a locally-built fallback if NUS doesn't serve one for this title)
        let tikPath = outputDir.appendingPathComponent("title.tik")
        do {
            try await session.downloadFile(
                urlString: "\(baseURL)/cetk", to: tikPath,
                options: DownloadOptions(doRetries: false, allowResume: true, validate: { url in
                    try ContentValidation.validateTicketFile(at: url, expectedTitleID: tmd.titleID, expectedTitleVersion: tmd.titleVersion)
                }),
                progress: progress
            )
        } catch {
            let passwordKind = TitleKeyPasswordKind(rawValue: entry?.titleID == titleID ? (entry?.key ?? 0) : 0) ?? .mypass
            let commonKey = try keyStore.load(.wiiUCommon)
            let titleKey = try TitleKeyGenerator.generateKey(titleIDHex: options.titleIDHex, passwordKind: passwordKind, commonKey: commonKey)
            let ticketBytes = try TicketBuilder.makeTicket(titleID: tmd.titleID, titleKey: titleKey, titleVersion: tmd.titleVersion)
            try Data(ticketBytes).write(to: tikPath)
        }

        let titleSize = tmd.contents.reduce(Int64(0)) { $0 + ContentValidation.expectedContentDownloadSize($1) + ContentValidation.expectedH3DownloadSize($1) }
        progress?.setDownloadSize(titleSize)

        // Certificate chain
        let certData = try await CertificateBuilder.makeCertificate(tmd: tmd, session: session)
        try Data(certData).write(to: outputDir.appendingPathComponent("title.cert"))

        progress?.setStartTime(Date())

        try await withThrowingTaskGroup(of: Void.self) { group in
            let semaphore = AsyncSemaphore(limit: 8)
            for content in tmd.contents {
                group.addTask { [session] in
                    await semaphore.wait()
                    defer { Task { await semaphore.signal() } }
                    guard await progress?.waitIfPaused() ?? true else { return }

                    let filePath = outputDir.appendingPathComponent(String(format: "%08X.app", content.id))
                    try await session.downloadFile(
                        urlString: "\(baseURL)/\(String(format: "%08X", content.id))", to: filePath,
                        options: DownloadOptions(expectedSize: ContentValidation.expectedContentDownloadSize(content), doRetries: true, allowResume: true),
                        progress: progress
                    )

                    if content.type & 0x02 != 0 {
                        let h3Path = outputDir.appendingPathComponent(String(format: "%08X.h3", content.id))
                        try await session.downloadFile(
                            urlString: "\(baseURL)/\(String(format: "%08X", content.id)).h3", to: h3Path,
                            options: DownloadOptions(expectedSize: ContentValidation.expectedH3DownloadSize(content), doRetries: true, allowResume: true, validate: { url in
                                guard try ContentValidation.verifyH3File(at: url, content: content) else {
                                    throw ContentDecryptor.DecryptError.h3HashMismatch
                                }
                            }),
                            progress: progress
                        )
                    }
                }
            }
            try await group.waitForAll()
        }

        if options.decryptContents {
            try await decryptDownloadedTitle(outputDir: outputDir, tmd: tmd, titleID: titleID, tikPath: tikPath, deleteEncrypted: options.deleteEncryptedAfterDecrypt, decryptOutputDirectory: options.decryptOutputDirectory, progress: progress)
        }
    }

    private func decryptDownloadedTitle(outputDir: URL, tmd: TMDFormat.Metadata, titleID: UInt64, tikPath: URL, deleteEncrypted: Bool, decryptOutputDirectory: URL?, progress: ProgressReporter?) async throws {
        let tikData = [UInt8](try Data(contentsOf: tikPath))
        let encryptedTitleKey = Array(tikData[TicketBuilder.encryptedKeyOffset..<(TicketBuilder.encryptedKeyOffset + TicketBuilder.encryptedKeySize)])
        let ticketKeyIndex = tikData[0x1F1]

        let titleKey = try ContentDecryptor.decryptedTitleKey(encryptedTitleKey: encryptedTitleKey, titleID: tmd.titleID, tmdVersion: tmd.version, ticketKeyIndex: ticketKeyIndex, keyStore: keyStore)

        let destinationDir = decryptOutputDirectory ?? outputDir
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        if tmd.version == TMDFormat.versionWiiU {
            try ContentExtractor.extractWiiUContents(sourceDir: outputDir, destinationDir: destinationDir, tmd: tmd, titleKey: titleKey)
        } else {
            try ContentExtractor.extractWiiContents(sourceDir: outputDir, destinationDir: destinationDir, tmd: tmd, titleKey: titleKey)
        }

        progress?.updateDecryptionProgress(1.0)

        if deleteEncrypted {
            let fm = FileManager.default
            for entry in try fm.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil) {
                let name = entry.lastPathComponent
                if name.hasSuffix(".app") || name.hasSuffix(".h3") || name == "title.tmd" || name == "title.tik" || name == "title.cert" {
                    try? fm.removeItem(at: entry)
                }
            }
        }
    }

    /// Fetches just a title's TMD to compute its download size, for "show size before queueing".
    public func fetchTitleSize(titleIDHex: String, version: Int) async throws -> UInt64 {
        guard let titleID = UInt64(titleIDHex, radix: 16) else { throw DownloaderError.invalidTitleIDHex }
        let baseURL = "http://ccs.cdn.c.shop.nintendowifi.net/ccs/download/\(String(format: "%016llx", titleID))"
        let tmdURL = version >= 0 ? "\(baseURL)/tmd.\(version)" : "\(baseURL)/tmd"
        let tmdBytes = try await session.download(urlString: tmdURL)
        let tmd = try TMDFormat.parse(tmdBytes)
        return tmd.contents.reduce(UInt64(0)) { $0 + UInt64(ContentValidation.expectedContentDownloadSize($1)) + UInt64(ContentValidation.expectedH3DownloadSize($1)) }
    }
}

/// Minimal async semaphore for bounding concurrent content downloads (URLSession has no
/// built-in per-task concurrency cap suitable for this).
actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.value = limit }

    func wait() async {
        if value > 0 {
            value -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            value += 1
        }
    }
}
