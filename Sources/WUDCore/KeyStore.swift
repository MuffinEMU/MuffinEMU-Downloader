import CryptoKit
import Foundation
import Security

/// Named decryption keys this app needs, none of which ship with the app.
/// The user imports their own `keys.txt` (or a console `otp.bin`) from a console they own;
/// every value here comes only from that import.
public enum KeyName: String, CaseIterable {
    case wiiUCommon = "commonKey"
    case wiiCommon = "common_key"
    case wiiKorean = "korean_key"
    case vWiiCommon = "vwii_common_key"

    public var displayName: String {
        switch self {
        case .wiiUCommon: return "Wii U common key"
        case .wiiCommon: return "Wii common key"
        case .wiiKorean: return "Wii Korean key"
        case .vWiiCommon: return "vWii common key"
        }
    }

    /// SHA-256 of the correct key. Lets the importer recognize a key wherever it appears in a
    /// file — any label, any layout, or none — without the app containing the key itself.
    var fingerprint: String {
        switch self {
        case .wiiUCommon: return "3b4011e584ae694f59f49df13aa5f471a4230ff7c2c7078361b7d624b8eeaa9b"
        case .wiiCommon: return "de38aeab4fe0c36d828a47e6fd315100e7ce234d3b00aa25e6ad6f5ff2824af8"
        case .wiiKorean: return "b9f42ca27a1e178f0f14ebf1a05d486fa8db8d08875336c4e6e8dfae29f2901c"
        case .vWiiCommon: return "d830ec964297fdd5a23862d8c8ac851b41ec071e0039abae10f51d5cc8e74308"
        }
    }

    /// Extra fingerprints registered by unit tests, which use fabricated values rather than real keys.
    nonisolated(unsafe) static var testFingerprints: [String: KeyName] = [:]

    static func digest(_ bytes: ArraySlice<UInt8>) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    static func matching(_ bytes: ArraySlice<UInt8>) -> KeyName? {
        let digest = digest(bytes)
        return testFingerprints[digest] ?? allCases.first { $0.fingerprint == digest }
    }
}

/// Storage for user-supplied decryption keys. Prefers the keychain; falls back to a
/// file-protected file in Application Support when the keychain is unusable, which happens on
/// sideloaded/re-signed builds that lack a keychain access group (errSecMissingEntitlement).
public final class KeyStore {
    public static let shared = KeyStore()
    public static let didChangeNotification = Notification.Name("WUDKeyStoreDidChange")

    private let service = "com.void.muffinemu.downloader.keys"

    public enum KeyStoreError: Error, LocalizedError {
        case notFound(KeyName)
        case unreadable(String)
        case keychain(OSStatus)
        case noRecognizedKeys
        case onlyOtherKeys(Int)

        public var errorDescription: String? {
            switch self {
            case .notFound(let name): return "The \(name.displayName) hasn't been imported yet. Import your keys.txt in Settings."
            case .unreadable(let reason): return "Couldn't read that file: \(reason)"
            case .keychain(let status): return "Couldn't save the key (error \(status))."
            case .noRecognizedKeys: return "No Wii U, Wii or vWii common key was found in that file. Use a keys.txt or otp.bin dumped from your console."
            case .onlyOtherKeys(let count): return "That file has \(count) key\(count == 1 ? "" : "s"), but none is a Wii U, Wii or vWii common key. Cemu's keys.txt only holds disc keys for WUD/WUX images, which this app doesn't use. Import a keys.txt or otp.bin that contains the common key from your console."
            }
        }
    }

    private init() {}

    private var fileStoreDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keys", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = dir
        try? mutable.setResourceValues(values)
        return dir
    }

    private func fileURL(for name: KeyName) -> URL {
        fileStoreDirectory.appendingPathComponent("\(name.rawValue).bin")
    }

    public func hasKey(_ name: KeyName) -> Bool {
        (try? load(name)) != nil
    }

    public func load(_ name: KeyName) throws -> [UInt8] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data, data.count == 16 {
            return [UInt8](data)
        }
        if let data = try? Data(contentsOf: fileURL(for: name)), data.count == 16 {
            return [UInt8](data)
        }
        throw KeyStoreError.notFound(name)
    }

    public func store(_ name: KeyName, bytes: [UInt8]) throws {
        let data = Data(bytes)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name.rawValue,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            do {
                try data.write(to: fileURL(for: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                throw KeyStoreError.keychain(status)
            }
        }
    }

    public func removeAll() {
        for name in KeyName.allCases {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: name.rawValue,
            ]
            SecItemDelete(query as CFDictionary)
            try? FileManager.default.removeItem(at: fileURL(for: name))
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Imports every known key found in the file. Accepts any text layout (`name = hex`,
    /// `hex # comment`, bare hex, `0xD7, 0xB0, …`) and binary dumps such as `otp.bin`.
    /// Returns the set of keys it found.
    @discardableResult
    public func importKeysFile(at url: URL) throws -> Set<KeyName> {
        let needsAccess = url.startAccessingSecurityScopedResource()
        defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw KeyStoreError.unreadable(error.localizedDescription)
        }
        return try importKeys(from: data)
    }

    @discardableResult
    public func importKeys(from data: Data) throws -> Set<KeyName> {
        let found = Self.findKeys(in: data)
        guard !found.isEmpty else {
            let others = Self.countHexKeys(in: data)
            throw others > 0 ? KeyStoreError.onlyOtherKeys(others) : KeyStoreError.noRecognizedKeys
        }
        for (name, bytes) in found {
            try store(name, bytes: bytes)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        return Set(found.keys)
    }

    static func findKeys(in data: Data) -> [KeyName: [UInt8]] {
        var found: [KeyName: [UInt8]] = [:]
        let raw = [UInt8](data.prefix(4 * 1024 * 1024))

        // Binary scan (otp.bin keeps keys at fixed, not always 16-aligned, offsets).
        if raw.count >= 16 {
            for offset in 0...(raw.count - 16) {
                if let name = KeyName.matching(raw[offset..<(offset + 16)]), found[name] == nil {
                    found[name] = Array(raw[offset..<(offset + 16)])
                }
            }
        }

        // Text scan: pull hex digits out of each line (dropping 0x prefixes and separators),
        // then test every 32-digit window so labels that happen to end in hex letters can't
        // shift the match.
        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            for line in text.split(whereSeparator: \.isNewline) {
                let cleaned = line.replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
                for run in hexRuns(in: cleaned) where run.count >= 32 {
                    for start in 0...(run.count - 32) {
                        guard let bytes = bytesFromHex(run[start..<(start + 32)]) else { continue }
                        if let name = KeyName.matching(bytes[...]), found[name] == nil {
                            found[name] = bytes
                        }
                    }
                }
            }
        }
        return found
    }

    /// 16-byte hex values in a text file that aren't a known common key (e.g. Cemu disc keys).
    static func countHexKeys(in data: Data) -> Int {
        guard let text = String(data: data, encoding: .utf8) else { return 0 }
        return text.split(whereSeparator: \.isNewline).reduce(0) { count, line in
            let uncommented = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            return count + (hexRuns(in: String(uncommented)).contains { $0.count == 32 } ? 1 : 0)
        }
    }

    /// Runs of hex digits, joining across spaces, commas, colons and dashes so
    /// "D7 B0 04 …" and "D7:B0:04…" read as one value.
    private static func hexRuns(in line: String) -> [[Character]] {
        var runs: [[Character]] = []
        var current: [Character] = []
        for ch in line {
            if ch.isHexDigit {
                current.append(ch)
            } else if ch == " " || ch == "," || ch == ":" || ch == "-" || ch == "\t" {
                continue
            } else {
                if !current.isEmpty { runs.append(current) }
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    private static func bytesFromHex(_ chars: ArraySlice<Character>) -> [UInt8]? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        var index = chars.startIndex
        while index < chars.endIndex {
            guard let byte = UInt8(String(chars[index...(index + 1)]), radix: 16) else { return nil }
            bytes.append(byte)
            index += 2
        }
        return bytes
    }
}
