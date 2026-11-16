import XCTest
@testable import WUDCore

final class TitleDataTests: XCTestCase {
    func testBundledDatabaseLoadsWithoutNetwork() throws {
        let entries = try TitleDatabaseLoader.loadBundled()
        XCTAssertGreaterThan(entries.count, 3000)
        XCTAssertTrue(entries.allSatisfy { $0.version == versionLatest })
        XCTAssertNotNil(entries.first { $0.titleIDHex == "00050000101C9500" })
    }

    func testMetadataResolvesGameAndItsUpdate() throws {
        let game = UInt64(0x0005_0000_101C_9500)
        let info = try XCTUnwrap(TitleMetadata.shared.info(for: game))
        XCTAssertTrue(info.title.contains("Zelda"))
        XCTAssertNotNil(info.synopsis)

        let update = UInt64(0x0005_000E_101C_9500)
        XCTAssertEqual(TitleMetadata.shared.info(for: update)?.gameTDBID, info.gameTDBID)
        XCTAssertFalse(TitleMetadata.shared.knownVersions(for: update).isEmpty)
    }

    func testCoverURLsPreferTheIDsRegion() {
        XCTAssertEqual(TitleMetadata.coverURLs(gameTDBID: "ALZP01", highQuality: false).first?.absoluteString,
                       "https://art.gametdb.com/wiiu/cover/EN/ALZP01.jpg")
        XCTAssertEqual(TitleMetadata.coverURLs(gameTDBID: "ALZE01", highQuality: true).first?.absoluteString,
                       "https://art.gametdb.com/wiiu/coverHQ/US/ALZE01.jpg")
    }
}
