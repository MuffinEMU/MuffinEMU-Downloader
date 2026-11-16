import XCTest
@testable import WUDCore

final class TicketBuilderTests: XCTestCase {
    func testPatchesTitleIDVersionAndKeyAtFixedOffsets() throws {
        let titleID: UInt64 = 0x0005_0000_1010_ECC0
        let titleKey: [UInt8] = Array(0..<16).map { UInt8($0) }
        let version: UInt16 = 7

        let ticket = try TicketBuilder.makeTicket(titleID: titleID, titleKey: titleKey, titleVersion: version)

        let gotKey = Array(ticket[TicketBuilder.encryptedKeyOffset..<(TicketBuilder.encryptedKeyOffset + 16)])
        XCTAssertEqual(gotKey, titleKey)

        let gotID = ticket[TicketBuilder.titleIDOffset..<(TicketBuilder.titleIDOffset + 8)]
        XCTAssertEqual(Array(gotID), bigEndianU64(titleID))

        XCTAssertEqual(ticket[TicketBuilder.titleVersionOffset], UInt8(version >> 8))
        XCTAssertEqual(ticket[TicketBuilder.titleVersionOffset + 1], UInt8(version & 0xFF))
    }

    func testRejectsShortTitleKey() {
        XCTAssertThrowsError(try TicketBuilder.makeTicket(titleID: 1, titleKey: [0x00, 0x01], titleVersion: 0))
    }
}
