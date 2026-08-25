import XCTest
@testable import PennyTxnStore

/// A4 — category coherence: model-coined labels must snap to the accumulated
/// taxonomy across every spelling variant, so one concept can never fragment
/// into "Ride Hailing" / "ride-hailing" / "Ride Hailings" / "Hailing Ride".
final class CategoryCoherenceTests: XCTestCase {

    private let seeds = ["Food & Dining", "Transport", "Subscriptions", "Fees & Charges", "Ride Hailing"]

    func testExactAndCaseInsensitiveSnap() {
        XCTAssertEqual(CategoryNormalizer.normalize("transport", seeds: seeds), "Transport")
        XCTAssertEqual(CategoryNormalizer.normalize("food & dining", seeds: seeds), "Food & Dining")
    }

    func testHyphenAndSpacingVariantsSnap() {
        XCTAssertEqual(CategoryNormalizer.normalize("ride-hailing", seeds: seeds), "Ride Hailing")
        XCTAssertEqual(CategoryNormalizer.normalize("Ride  Hailing", seeds: seeds), "Ride Hailing")
    }

    func testPluralVariantsSnap() {
        XCTAssertEqual(CategoryNormalizer.normalize("Ride Hailings", seeds: seeds), "Ride Hailing")
        XCTAssertEqual(CategoryNormalizer.normalize("Subscription", seeds: seeds), "Subscriptions")
        XCTAssertEqual(CategoryNormalizer.normalize("Fee & Charge", seeds: seeds), "Fees & Charges")
    }

    func testWordOrderVariantsSnap() {
        XCTAssertEqual(CategoryNormalizer.normalize("Hailing Ride", seeds: seeds), "Ride Hailing")
        XCTAssertEqual(CategoryNormalizer.normalize("Dining & Food", seeds: seeds), "Food & Dining")
    }

    func testGenuinelyNewNameSurvivesTitleCased() {
        XCTAssertEqual(CategoryNormalizer.normalize("pet care", seeds: seeds), "Pet Care")
    }

    func testShortWordsDoNotOverStripPlurals() {
        // "Gas" must not become "Ga"-keyed nonsense that collides elsewhere.
        XCTAssertEqual(CategoryNormalizer.normalize("Gas", seeds: seeds), "Gas")
    }

    func testRamblingFallsBackToOther() {
        XCTAssertEqual(CategoryNormalizer.normalize(
            "This looks like a subscription service for streaming", seeds: seeds), "Other")
    }
}
