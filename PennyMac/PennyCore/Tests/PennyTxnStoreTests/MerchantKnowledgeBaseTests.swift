import XCTest
@testable import PennyTxnStore

/// Locks the merchant knowledge base: normalized keying (so variants of one
/// merchant collapse — spec Step 8 consistency), the learn threshold (never cache
/// low-confidence guesses as fact — Step 7), higher-confidence override, and a
/// persistence round-trip.
final class MerchantKnowledgeBaseTests: XCTestCase {

    private func verdict(_ raw: String, primary: String, secondary: String?,
                         confidence: Double, clean: String? = nil, business: String? = nil)
    -> ClaudeCategorization {
        ClaudeCategorization(merchant: raw, category: primary, confidence: confidence,
                             cleanMerchant: clean, business: business,
                             primaryCategory: primary, secondaryCategory: secondary)
    }

    func testUnknownMerchantIsNil() {
        let kb = MerchantKnowledgeBase()
        XCTAssertNil(kb.lookup("SOME BRAND NEW MERCHANT 4471"))
        XCTAssertFalse(kb.contains("SOME BRAND NEW MERCHANT 4471"))
    }

    func testLearnThenLookupPrefersSpecificSecondary() {
        var kb = MerchantKnowledgeBase()
        XCTAssertTrue(kb.learn(verdict("DELIVEROO", primary: "Food & Drink",
                                       secondary: "Food Delivery", confidence: 0.99,
                                       clean: "Deliveroo", business: "Food delivery")))
        let p = kb.lookup("DELIVEROO")
        XCTAssertEqual(p?.merchant, "Deliveroo")
        XCTAssertEqual(p?.primaryCategory, "Food & Drink")
        XCTAssertEqual(p?.secondaryCategory, "Food Delivery")
        XCTAssertEqual(p?.displayCategory, "Food Delivery")   // specific, not broad
    }

    /// The core Step 8 guarantee: different raw variants of the SAME merchant
    /// resolve to one profile, so the merchant is always categorized the same way.
    func testConsistencyAcrossRawVariants() {
        var kb = MerchantKnowledgeBase()
        kb.learn(verdict("DOJO*THE CRAFT BEER CO LONDON", primary: "Food & Drink",
                         secondary: "Bar", confidence: 0.98, clean: "The Craft Beer Co"))
        // A different acquirer prefix + no city — must hit the same learned profile.
        let p = kb.lookup("TST-THE CRAFT BEER CO")
        XCTAssertEqual(p?.displayCategory, "Bar")
        XCTAssertEqual(p?.merchant, "The Craft Beer Co")

        kb.learn(verdict("LIME PASS", primary: "Transport",
                         secondary: "Scooter Rental", confidence: 0.97, clean: "Lime"))
        XCTAssertEqual(kb.lookup("LIME RIDE")?.displayCategory, "Scooter Rental")
        XCTAssertEqual(kb.lookup("LIME UK")?.displayCategory, "Scooter Rental")
    }

    func testLowConfidenceVerdictIsNotLearned() {
        var kb = MerchantKnowledgeBase()
        XCTAssertFalse(kb.learn(verdict("MYSTERY XYZ", primary: "Shopping",
                                        secondary: nil, confidence: 0.60)))
        XCTAssertNil(kb.lookup("MYSTERY XYZ"))
        XCTAssertEqual(kb.count, 0)
    }

    func testHigherConfidenceOverridesAndRecordsAlias() {
        var kb = MerchantKnowledgeBase()
        kb.learn(verdict("FOREST", primary: "Food & Drink", secondary: "Restaurant",
                         confidence: 0.86, clean: "Forest"))          // early weak-ish guess
        kb.learn(verdict("FOREST BIKE", primary: "Transport", secondary: "Bike Rental",
                         confidence: 0.99, clean: "Forest", business: "Electric bike rental"))
        let p = kb.lookup("FOREST")
        XCTAssertEqual(p?.displayCategory, "Bike Rental")             // stronger verdict wins
        XCTAssertEqual(p?.business, "Electric bike rental")
        XCTAssertTrue(p?.aliases.contains("FOREST") ?? false)
        XCTAssertTrue(p?.aliases.contains("FOREST BIKE") ?? false)
    }

    func testPersistenceRoundTrip() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kb-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var kb = MerchantKnowledgeBase()
        kb.learn(verdict("PRET A MANGER", primary: "Food & Drink", secondary: "Cafe",
                         confidence: 0.98, clean: "Pret A Manger"))
        kb.learn(verdict("TFL TRAVEL CHARGE", primary: "Transport", secondary: "Public Transport",
                         confidence: 0.99, clean: "TFL"))
        kb.save(to: url)

        let reloaded = MerchantKnowledgeBase.load(from: url)
        XCTAssertEqual(reloaded.count, 2)
        XCTAssertEqual(reloaded.lookup("PRET A MANGER")?.displayCategory, "Cafe")
        XCTAssertEqual(reloaded.lookup("TFL TRAVEL CHARGE")?.displayCategory, "Public Transport")
    }

    func testMissingFileLoadsEmpty() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kb-absent-\(UUID().uuidString).json")
        XCTAssertEqual(MerchantKnowledgeBase.load(from: url).count, 0)
    }
}
