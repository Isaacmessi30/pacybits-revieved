import XCTest
@testable import RevivalTradingClient

final class LegacyCollectionTests: XCTestCase {
    func testRetainsOwnedCardWithoutOfferingTheLastCopy() throws {
        let snapshot = try LegacyCollectionSnapshot.read(preferences: [
            "bXlJZHM=": ["first": 0, "duplicate": 2]
        ])
        XCTAssertEqual(snapshot.ownedCardIDs, Set(["first", "duplicate"]))
        XCTAssertEqual(snapshot.tradeableCards, ["duplicate": 2])
    }
    func testMissingOrMalformedCollectionNeverBecomesAnEmptyImport() {
        XCTAssertThrowsError(try LegacyCollectionSnapshot.read(preferences: [:]))
        XCTAssertThrowsError(try LegacyCollectionSnapshot.read(preferences: ["bXlJZHM=": "invalid"]))
        for value: Any in [true, -1, 1.5, "3", Double.infinity, 1_000_001] {
            XCTAssertThrowsError(try LegacyCollectionSnapshot.read(preferences: ["bXlJZHM=": ["card": value]]))
        }
    }
    func testExplicitEmptyCollectionIsDistinctFromMissingData() throws {
        let snapshot = try LegacyCollectionSnapshot.read(preferences: ["bXlJZHM=": [String: Int]()])
        XCTAssertTrue(snapshot.tradeableCards.isEmpty)
    }
}
