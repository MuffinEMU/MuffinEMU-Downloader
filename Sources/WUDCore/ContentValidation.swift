import CryptoKit
import Foundation

public enum ContentValidation {
    static let hashedContentTypeFlag: UInt16 = 0x02
    static let tidHighWiiSystemApp: UInt32 = 0x0001_0002
    static let tidHighWiiSystem: UInt32 = 0x0001_0008

    static func titleIDsMatchTMD(expected: UInt64, actual: UInt64, tmdVersion: UInt8) -> Bool {
        if expected == 0 || actual == expected { return true }
        guard tmdVersion == TMDFormat.versionWii else { return false }

        let expectedHigh = TitleDatabaseHelpers.titleIDHigh(expected)
        let actualHigh = TitleDatabaseHelpers.titleIDHigh(actual)
        switch expectedHigh {
        case TitleIDHigh.vWiiSystemApp:
            guard actualHigh == tidHighWiiSystemApp else { return false }
        case TitleIDHigh.vWiiSystem:
            guard actualHigh == tidHighWiiSystem else { return false }
        default:
            return false
        }
        return TitleDatabaseHelpers.titleIDLow(expected) == TitleDatabaseHelpers.titleIDLow(actual)
    }

    static func alignToAESBlockSize(_ size: UInt64) -> UInt64 {
        let mask: UInt64 = 15
        return (size + mask) & ~mask
    }

    static func expectedContentDownloadSize(_ content: TMDFormat.ContentEntry) -> Int64 {
        if content.type & hashedContentTypeFlag == hashedContentTypeFlag {
            return Int64(content.size)
        }
        return Int64(alignToAESBlockSize(content.size))
    }

    static func expectedH3DownloadSize(_ content: TMDFormat.ContentEntry) -> Int64 {
        guard content.type & hashedContentTypeFlag == hashedContentTypeFlag else { return 0 }
        let chunkCount = (content.size + ContentDecryptor.blockSizeHashed - 1) / ContentDecryptor.blockSizeHashed
        let entriesPerLevel = UInt64(ContentDecryptor.hashEntriesPerLevel)
        let h3Entries = (chunkCount + entriesPerLevel * entriesPerLevel * entriesPerLevel - 1) / (entriesPerLevel * entriesPerLevel * entriesPerLevel)
        return Int64(h3Entries) * Int64(ContentDecryptor.hashEntrySize)
    }

    static func verifyH3File(at url: URL, content: TMDFormat.ContentEntry) throws -> Bool {
        let data = try Data(contentsOf: url)
        let sum = SHA1.hash(data)
        return content.hash.count >= 20 && Array(sum) == Array(content.hash.prefix(20))
    }

    static func validateTMDFile(at url: URL, expectedTitleID: UInt64) throws {
        let data = try Data(contentsOf: url)
        let tmd = try TMDFormat.parse([UInt8](data))
        guard titleIDsMatchTMD(expected: expectedTitleID, actual: tmd.titleID, tmdVersion: tmd.version) else {
            throw ValidationError.titleIDMismatch
        }
    }

    static func validateTicketFile(at url: URL, expectedTitleID: UInt64, expectedTitleVersion: UInt16) throws {
        let data = [UInt8](try Data(contentsOf: url))
        guard data.count >= TicketBuilder.titleVersionOffset + TicketBuilder.titleVersionSize else {
            throw ValidationError.ticketTooSmall
        }
        let idBytes = data[TicketBuilder.titleIDOffset..<(TicketBuilder.titleIDOffset + TicketBuilder.titleIDSize)]
        let gotTitleID = bigEndianU64FromBytes(Array(idBytes))
        if expectedTitleID != 0, gotTitleID != expectedTitleID { throw ValidationError.titleIDMismatch }

        let versionBytes = data[TicketBuilder.titleVersionOffset..<(TicketBuilder.titleVersionOffset + TicketBuilder.titleVersionSize)]
        let gotVersion = bigEndianU16(versionBytes)
        if expectedTitleVersion != 0, gotVersion != expectedTitleVersion { throw ValidationError.titleVersionMismatch }
    }

    enum ValidationError: Error {
        case titleIDMismatch
        case titleVersionMismatch
        case ticketTooSmall
    }
}

private func bigEndianU64FromBytes(_ bytes: [UInt8]) -> UInt64 {
    var v: UInt64 = 0
    for b in bytes { v = (v << 8) | UInt64(b) }
    return v
}

/// SHA-1 wrapper — CryptoKit's `Insecure.SHA1` (Nintendo's own hash-tree format mandates SHA-1;
/// this is purely for interop with an existing on-disk format, not used for anything security-sensitive).
enum SHA1 {
    static func hash(_ data: Data) -> [UInt8] {
        [UInt8](Insecure.SHA1.hash(data: data))
    }
}
