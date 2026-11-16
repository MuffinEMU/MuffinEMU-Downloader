import XCTest
@testable import WUDCore

final class SearchTests: XCTestCase {
    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(TitleSearch.matches(query: "", titleName: "Super Mario 3D World", titleIDHex: "00050000101C9400"))
    }

    func testMatchesByTitleIDSubstring() {
        XCTAssertTrue(TitleSearch.matches(query: "101c9400", titleName: "Anything", titleIDHex: "00050000101C9400"))
    }

    func testMatchesByFuzzyNameToken() {
        XCTAssertTrue(TitleSearch.matches(query: "mario", titleName: "Super Mario 3D World", titleIDHex: "0"))
        XCTAssertTrue(TitleSearch.matches(query: "mro", titleName: "Super Mario 3D World", titleIDHex: "0"))
    }

    func testAllTokensMustMatch() {
        XCTAssertFalse(TitleSearch.matches(query: "mario zelda", titleName: "Super Mario 3D World", titleIDHex: "0"))
    }

    func testNormalizeCollapsesPunctuationAndCase() {
        XCTAssertEqual(TitleSearch.normalize("Zelda: Breath of the Wild!!"), "zelda breath of the wild")
    }
}
