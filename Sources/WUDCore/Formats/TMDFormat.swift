import Foundation

/// Low-level parser for Nintendo's Title Metadata (TMD) binary layout.
/// Offsets follow the published Wii/Wii U TMD structure (fixed header, then a
/// content table, then trailing certificates); the same shape NUS serves for `tmd`/`tmd.<version>`.
public enum TMDFormat {
    public static let versionWii: UInt8 = 0x00
    public static let versionWiiU: UInt8 = 0x01

    static let versionOffset = 0x180
    static let titleIDOffset = 0x18C
    static let titleVersionOffset = 0x1DC

    static let wiiContentStart = 0x1E4
    static let wiiContentStride = 0x24
    static let wiiHashSize = 0x14

    static let wiiuContentStart = 0xB04
    static let wiiuContentStride = 0x30
    static let wiiuHashSize = 0x20

    public struct ContentEntry {
        public let id: UInt32
        public let index: [UInt8]
        public let type: UInt16
        public let size: UInt64
        public let hash: [UInt8]
    }

    public struct Metadata {
        public var titleID: UInt64 = 0
        public var version: UInt8 = 0
        public var titleVersion: UInt16 = 0
        public var contentCount: UInt16 = 0
        public var contents: [ContentEntry] = []
        public var certificate1: [UInt8] = []
        public var certificate2: [UInt8] = []
    }

    public enum ParseError: Error {
        case unknownVersion(UInt8)
    }

    public static func parse(_ data: [UInt8]) throws -> Metadata {
        let c = BinaryCursor(data)
        try c.seek(versionOffset)
        let version = try c.readU8()

        var m = Metadata()
        m.version = version

        switch version {
        case versionWii:
            try parseHeader(c, &m)
            try parseContents(c, &m, start: wiiContentStart, stride: wiiContentStride, hashSize: wiiHashSize)
            try parseCertificates(c, &m, start: wiiContentStart, stride: wiiContentStride, count: Int(m.contentCount), hashSize: wiiHashSize, required: true)
        case versionWiiU:
            try parseHeader(c, &m)
            try parseContents(c, &m, start: wiiuContentStart, stride: wiiuContentStride, hashSize: wiiuHashSize)
            try parseCertificates(c, &m, start: wiiuContentStart, stride: wiiuContentStride, count: Int(m.contentCount), hashSize: wiiuHashSize, required: false)
        default:
            throw ParseError.unknownVersion(version)
        }
        return m
    }

    private static func parseHeader(_ c: BinaryCursor, _ m: inout Metadata) throws {
        try c.seek(titleIDOffset)
        m.titleID = try c.readU64BE()

        try c.seek(titleVersionOffset)
        m.titleVersion = try c.readU16BE()
        m.contentCount = try c.readU16BE()
    }

    private static func parseContents(_ c: BinaryCursor, _ m: inout Metadata, start: Int, stride: Int, hashSize: Int) throws {
        var contents: [ContentEntry] = []
        contents.reserveCapacity(Int(m.contentCount))
        for i in 0..<Int(m.contentCount) {
            try c.seek(start + stride * i)
            let id = try c.readU32BE()
            let index = try c.readBytes(2)
            let type = try c.readU16BE()
            let size = try c.readU64BE()
            let hash = try c.readBytes(hashSize)
            contents.append(ContentEntry(id: id, index: index, type: type, size: size, hash: hash))
        }
        m.contents = contents
    }

    private static func parseCertificates(_ c: BinaryCursor, _ m: inout Metadata, start: Int, stride: Int, count: Int, hashSize: Int, required: Bool) throws {
        guard count > 0 else { return }
        let lastEnd = start + (count - 1) * stride + 16 + hashSize
        guard lastEnd >= 0 else { return }

        do {
            try c.seek(lastEnd)
        } catch {
            if required { throw error }
            return
        }

        if required || c.remaining >= 0x400 {
            m.certificate1 = try c.readBytes(0x400)
        }
        if required || c.remaining >= 0x300 {
            m.certificate2 = try c.readBytes(0x300)
        }
    }
}
