import Foundation
import WUDCore

/// User-facing settings, persisted to UserDefaults. Mirrors the upstream desktop tool's
/// config.json fields; dark mode is dropped since iOS handles that system-wide.
@Observable
final class AppConfig {
    var decryptContents: Bool {
        didSet { defaults.set(decryptContents, forKey: Keys.decryptContents) }
    }
    var deleteEncryptedContents: Bool {
        didSet { defaults.set(deleteEncryptedContents, forKey: Keys.deleteEncryptedContents) }
    }
    var continueOnError: Bool {
        didSet { defaults.set(continueOnError, forKey: Keys.continueOnError) }
    }
    var suggestRelatedContent: Bool {
        didSet { defaults.set(suggestRelatedContent, forKey: Keys.suggestRelatedContent) }
    }
    var selectedRegion: UInt8 {
        didSet { defaults.set(Int(selectedRegion), forKey: Keys.selectedRegion) }
    }
    var didInitialSetup: Bool {
        didSet { defaults.set(didInitialSetup, forKey: Keys.didInitialSetup) }
    }
    var getSizeOnQueue: Bool {
        didSet { defaults.set(getSizeOnQueue, forKey: Keys.getSizeOnQueue) }
    }
    var keepScreenOn: Bool {
        didSet { defaults.set(keepScreenOn, forKey: Keys.keepScreenOn) }
    }
    var showCoverArt: Bool {
        didSet { defaults.set(showCoverArt, forKey: Keys.showCoverArt) }
    }
    /// Bookmark to a user-picked folder (Files app, iCloud Drive, external drive…). Nil means
    /// the app's own Documents/Downloads, which is visible in Files under "On My iPhone".
    private(set) var downloadFolderBookmark: Data? {
        didSet { defaults.set(downloadFolderBookmark, forKey: Keys.downloadFolderBookmark) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let decryptContents = "decryptContents"
        static let deleteEncryptedContents = "deleteEncryptedContents"
        static let continueOnError = "continueOnError"
        static let suggestRelatedContent = "suggestRelatedContent"
        static let selectedRegion = "selectedRegion"
        static let didInitialSetup = "didInitialSetup"
        static let getSizeOnQueue = "getSizeOnQueue"
        static let keepScreenOn = "keepScreenOn"
        static let showCoverArt = "showCoverArt"
        static let downloadFolderBookmark = "downloadFolderBookmark"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.decryptContents = defaults.object(forKey: Keys.decryptContents) as? Bool ?? false
        self.deleteEncryptedContents = defaults.object(forKey: Keys.deleteEncryptedContents) as? Bool ?? false
        self.continueOnError = defaults.object(forKey: Keys.continueOnError) as? Bool ?? true
        self.suggestRelatedContent = defaults.object(forKey: Keys.suggestRelatedContent) as? Bool ?? true
        let defaultRegion = Int(MCPRegion.europe | MCPRegion.usa | MCPRegion.japan)
        self.selectedRegion = UInt8(defaults.object(forKey: Keys.selectedRegion) as? Int ?? defaultRegion)
        self.didInitialSetup = defaults.object(forKey: Keys.didInitialSetup) as? Bool ?? false
        self.getSizeOnQueue = defaults.object(forKey: Keys.getSizeOnQueue) as? Bool ?? true
        self.keepScreenOn = defaults.object(forKey: Keys.keepScreenOn) as? Bool ?? true
        self.showCoverArt = defaults.object(forKey: Keys.showCoverArt) as? Bool ?? true
        self.downloadFolderBookmark = defaults.data(forKey: Keys.downloadFolderBookmark)
    }

    /// The app's own Documents/Downloads folder — the default destination.
    var defaultDownloadsDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var hasCustomDownloadFolder: Bool { downloadFolderBookmark != nil }

    /// Display name of the chosen destination for Settings.
    var downloadFolderDisplayName: String {
        guard let url = resolveBookmark() else { return "On My iPhone › Muffin Downloader › Downloads" }
        return url.lastPathComponent
    }

    /// Saves a folder the user picked with the document picker. The URL must still be inside
    /// its security scope when this is called.
    func setDownloadFolder(_ url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        downloadFolderBookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resetDownloadFolder() {
        downloadFolderBookmark = nil
    }

    private func resolveBookmark() -> URL? {
        guard let bookmark = downloadFolderBookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale, let refreshed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            downloadFolderBookmark = refreshed
        }
        return url
    }

    /// Opens the destination for writing. Call `stop` when the queue finishes so the security
    /// scope on a user-picked folder is released.
    func openDownloadDestination() throws -> (root: URL, stop: () -> Void) {
        guard downloadFolderBookmark != nil else { return (defaultDownloadsDirectory, {}) }
        guard let url = resolveBookmark() else { throw DestinationError.folderUnavailable }
        guard url.startAccessingSecurityScopedResource() else { throw DestinationError.folderUnavailable }
        return (url, { url.stopAccessingSecurityScopedResource() })
    }

    enum DestinationError: LocalizedError {
        case folderUnavailable

        var errorDescription: String? {
            "The download folder can't be opened. It may have been moved, deleted or disconnected — pick it again in Settings."
        }
    }
}

extension TitleEntry {
    /// Folder name for a title's files, matching upstream/Mobile: "Name [Kind] [TitleID]".
    var outputFolderName: String {
        let base = name.isEmpty ? titleIDHex : name
        let safe = base.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return "\(safe) [\(TitleDatabaseHelpers.formattedKind(forTitleID: titleID))] [\(titleIDHex)]"
    }
}
