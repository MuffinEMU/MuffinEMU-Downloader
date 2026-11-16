import XCTest
@testable import WUDCore

final class WiiUBrewTitleSourceTests: XCTestCase {
    private let sample = """
    == 00050000: Game Application Titles ==
    {| class="wikitable sortable"
    ! Title ID
    ! Name
    ! Product Code
    ! Region
    |-
    | 00050000-101C9500
    | [[The Legend of Zelda: Breath of the Wild|The Legend of Zelda Breath of the Wild]]
    | WUP-P-ALZP
    | EUR
    |-
    | 00050000-10101D00
    | New SUPER MARIO BROS. U
    | WUP-P-ARPE
    | USA
    |}
    == 0005000E: Game Update Titles ==
    {| class="wikitable sortable"
    ! Title ID
    ! Description
    ! Notes
    ! Versions
    ! Region
    |-
    | 0005000E-101C9500
    | The Legend of Zelda Breath of the Wild
    |
    | v16, v32
    |
    |}
    """

    func testParsesTablesByHeaderName() {
        let entries = WiiUBrewTitleSource.parse(sample)
        XCTAssertEqual(entries.count, 3)
        let zelda = entries.first { $0.titleIDHex == "00050000101C9500" }
        XCTAssertEqual(zelda?.name, "The Legend of Zelda Breath of the Wild")
        XCTAssertEqual(zelda?.region, MCPRegion.europe)
        XCTAssertEqual(zelda?.category, .game)
        XCTAssertEqual(entries.first { $0.titleIDHex == "0005000E101C9500" }?.category, .update)
    }

    func testMergeKeepsBaseAndFillsBlankRegionFromSibling() {
        let base = [TitleEntry(name: "Mario", titleID: 0x0005_0000_1010_1D00, region: MCPRegion.usa, key: 3, category: .game)]
        let merged = WiiUBrewTitleSource.merge(WiiUBrewTitleSource.parse(sample), into: base)
        XCTAssertEqual(merged.first { $0.titleID == 0x0005_0000_1010_1D00 }?.key, 3)
        XCTAssertEqual(merged.first { $0.titleIDHex == "0005000E101C9500" }?.region, MCPRegion.europe)
        XCTAssertEqual(merged.count, 3)
    }
}
