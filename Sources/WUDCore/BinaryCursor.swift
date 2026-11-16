import Foundation

/// Bounds-checked big-endian reader over a fixed byte buffer.
/// Mirrors the offset/seek model Nintendo's TMD/ticket/FST/U8 binary formats are laid out with.
public struct BinaryCursorError: Error, CustomStringConvertible {
    public let op: String
    public let offset: Int
    public let need: Int
    public let have: Int

    public var description: String {
        "\(op): need \(need) byte(s) at offset \(offset), have \(have)"
    }
}

public final class BinaryCursor {
    private let data: [UInt8]
    private(set) public var position: Int = 0

    public init(_ data: [UInt8]) {
        self.data = data
    }

    public init(_ data: Data) {
        self.data = [UInt8](data)
    }

    public var remaining: Int { data.count - position }
    public var count: Int { data.count }

    public func seek(_ offset: Int) throws {
        guard offset >= 0, offset <= data.count else {
            throw BinaryCursorError(op: "seek", offset: offset, need: 0, have: data.count)
        }
        position = offset
    }

    public func slice(_ offset: Int, _ n: Int) throws -> ArraySlice<UInt8> {
        guard offset >= 0, n >= 0, offset <= data.count - n else {
            throw BinaryCursorError(op: "slice", offset: offset, need: n, have: max(0, data.count - offset))
        }
        return data[offset..<(offset + n)]
    }

    @discardableResult
    public func readBytes(_ n: Int) throws -> [UInt8] {
        let start = position
        guard start >= 0, n >= 0, start <= data.count - n else {
            throw BinaryCursorError(op: "read-bytes", offset: start, need: n, have: max(0, data.count - start))
        }
        position += n
        return Array(data[start..<(start + n)])
    }

    public func readU8() throws -> UInt8 {
        try readBytes(1)[0]
    }

    public func readU16BE() throws -> UInt16 {
        let b = try readBytes(2)
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }

    public func readU32BE() throws -> UInt32 {
        let b = try readBytes(4)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    public func readU64BE() throws -> UInt64 {
        let b = try readBytes(8)
        var v: UInt64 = 0
        for byte in b { v = (v << 8) | UInt64(byte) }
        return v
    }
}

extension Data {
    var bytes: [UInt8] { [UInt8](self) }
}

public func bigEndianU16(_ b: ArraySlice<UInt8>) -> UInt16 {
    let a = Array(b)
    return UInt16(a[0]) << 8 | UInt16(a[1])
}

public func bigEndianU32(_ b: ArraySlice<UInt8>) -> UInt32 {
    let a = Array(b)
    return UInt32(a[0]) << 24 | UInt32(a[1]) << 16 | UInt32(a[2]) << 8 | UInt32(a[3])
}

public func bigEndianU64(_ tid: UInt64) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 8)
    var v = tid
    for i in stride(from: 7, through: 0, by: -1) {
        out[i] = UInt8(v & 0xFF)
        v >>= 8
    }
    return out
}
