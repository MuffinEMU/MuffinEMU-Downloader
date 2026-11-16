import Foundation

/// Parser for the Wii U File System Table (FST) that lives inside content #0 of most titles.
/// It's a flat array of fixed-size entries (files + directories) followed by a null-terminated
/// name string table, addressed by name offset.
public enum FSTFormat {
    static let maxEntries = 1_000_000

    public struct Entry {
        public let type: UInt8
        public let nameOffset: UInt32
        public let offset: UInt32
        public let length: UInt32
        public let flags: UInt16
        public let contentID: UInt16
    }

    public struct Table {
        public let factor: UInt32
        public let entryCount: UInt32
        public let namesOffset: UInt32
        public let entries: [Entry]
        let data: [UInt8]

        public func name(at nameOffset: UInt32) throws -> String {
            let start = Int(namesOffset + nameOffset)
            guard start >= 0, start < data.count else {
                throw ParseError.nameOutOfBounds(nameOffset)
            }
            var end = start
            while end < data.count, data[end] != 0 { end += 1 }
            guard end < data.count else { throw ParseError.unterminatedString(nameOffset) }
            return String(decoding: data[start..<end], as: UTF8.self)
        }
    }

    public enum ParseError: Error {
        case invalidRootOffset
        case invalidEntryCount(UInt32)
        case invalidNamesOffset
        case nameOutOfBounds(UInt32)
        case unterminatedString(UInt32)
    }

    public static func parse(_ data: [UInt8]) throws -> Table {
        let c = BinaryCursor(data)
        try c.seek(0x04)
        var factor = try c.readU32BE()
        let entryCount = try c.readU32BE()
        if factor == 0 { factor = 1 }

        let rootOffset = 0x20 + Int(entryCount) * 0x20
        guard rootOffset >= 0, rootOffset <= data.count - 16 else {
            throw ParseError.invalidRootOffset
        }

        try c.seek(rootOffset + 8)
        let totalEntries = try c.readU32BE()
        guard totalEntries > 0, totalEntries <= UInt32(maxEntries) else {
            throw ParseError.invalidEntryCount(totalEntries)
        }

        let namesOffset = UInt32(0x20 + Int(entryCount) * 0x20 + Int(totalEntries) * 0x10)
        guard Int(namesOffset) <= data.count else { throw ParseError.invalidNamesOffset }

        try c.seek(rootOffset)
        var entries: [Entry] = []
        entries.reserveCapacity(Int(totalEntries))
        for _ in 0..<totalEntries {
            let type = try c.readU8()
            let nameBytes = try c.readBytes(3)
            let nb0: UInt32 = UInt32(nameBytes[0])
            let nb1: UInt32 = UInt32(nameBytes[1])
            let nb2: UInt32 = UInt32(nameBytes[2])
            let nameOffset: UInt32 = (nb0 << 16) + (nb1 << 8) + nb2
            let offset = try c.readU32BE()
            let length = try c.readU32BE()
            let flags = try c.readU16BE()
            let contentID = try c.readU16BE()
            entries.append(Entry(type: type, nameOffset: nameOffset, offset: offset, length: length, flags: flags, contentID: contentID))
        }

        return Table(factor: factor, entryCount: entryCount, namesOffset: namesOffset, entries: entries, data: data)
    }
}
