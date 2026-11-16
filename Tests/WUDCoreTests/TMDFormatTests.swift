import XCTest
@testable import WUDCore

final class TMDFormatTests: XCTestCase {
    /// Builds a minimal, structurally-valid Wii U TMD with one content entry so the parser
    /// can be exercised without any real Nintendo-signed data.
    private func makeWiiUTMD(titleID: UInt64, titleVersion: UInt16, contentCount: UInt16 = 1) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 0xB04 + Int(contentCount) * 0x30)
        data[TMDFormat.versionOffset] = TMDFormat.versionWiiU

        let idBytes = bigEndianU64(titleID)
        data.replaceSubrange(TMDFormat.titleIDOffset..<(TMDFormat.titleIDOffset + 8), with: idBytes)

        data[TMDFormat.titleVersionOffset] = UInt8(titleVersion >> 8)
        data[TMDFormat.titleVersionOffset + 1] = UInt8(titleVersion & 0xFF)
        data[TMDFormat.titleVersionOffset + 2] = UInt8(contentCount >> 8)
        data[TMDFormat.titleVersionOffset + 3] = UInt8(contentCount & 0xFF)

        // One content entry: id=0x00000000, index=0, type=hashed(0x02), size=0x1000, hash=zeros.
        let contentStart = TMDFormat.wiiuContentStart
        data[contentStart + 6] = 0x00
        data[contentStart + 7] = 0x02 // type = hashed
        data[contentStart + 8 + 7] = 0x10 // size low byte -> 0x10 << ... size = 0x1000
        data[contentStart + 8 + 6] = 0x00
        return data
    }

    func testParsesWiiUHeaderFields() throws {
        let data = makeWiiUTMD(titleID: 0x0005_0000_1010_ECC0, titleVersion: 42)
        let tmd = try TMDFormat.parse(data)
        XCTAssertEqual(tmd.version, TMDFormat.versionWiiU)
        XCTAssertEqual(tmd.titleID, 0x0005_0000_1010_ECC0)
        XCTAssertEqual(tmd.titleVersion, 42)
        XCTAssertEqual(tmd.contentCount, 1)
        XCTAssertEqual(tmd.contents.count, 1)
        XCTAssertEqual(tmd.contents[0].type, 0x02)
    }

    func testUnknownVersionThrows() {
        var data = [UInt8](repeating: 0, count: 0x200)
        data[TMDFormat.versionOffset] = 0x42
        XCTAssertThrowsError(try TMDFormat.parse(data))
    }

    func testTruncatedDataThrows() {
        let data = [UInt8](repeating: 0, count: 4)
        XCTAssertThrowsError(try TMDFormat.parse(data))
    }
}
