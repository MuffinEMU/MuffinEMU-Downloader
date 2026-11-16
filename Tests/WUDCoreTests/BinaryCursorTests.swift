import XCTest
@testable import WUDCore

final class BinaryCursorTests: XCTestCase {
    func testReadsBigEndianIntegers() throws {
        let cursor = BinaryCursor([0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x03])
        XCTAssertEqual(try cursor.readU16BE(), 1)
        XCTAssertEqual(try cursor.readU16BE(), 2)
        XCTAssertEqual(try cursor.readU32BE(), 3)
    }

    func testSeekOutOfBoundsThrows() {
        let cursor = BinaryCursor([0x00, 0x01])
        XCTAssertThrowsError(try cursor.seek(10))
    }

    func testReadBytesOutOfBoundsThrows() {
        let cursor = BinaryCursor([0x00, 0x01])
        XCTAssertThrowsError(try cursor.readBytes(10))
    }

    func testU64RoundTrip() {
        let value: UInt64 = 0x0005_0000_1010_ECC0
        let bytes = bigEndianU64(value)
        let cursor = BinaryCursor(bytes)
        XCTAssertEqual(try! cursor.readU64BE(), value)
    }
}
