// VocabularyEdgeCaseTests — guards the 2026-07-25 US/EU categorization
// vocabulary expansion (the "everything falls into Other" client fix) and,
// more importantly, its EDGE CASES: the classifier matches every term as a
// case-insensitive PREFIX (leading \b, no trailing boundary) in first-match-
// wins order, so every new term is one substring away from repainting an
// unrelated transaction. Positive cases pin the intended mappings on BOTH
// classifier routes (classify = US/IN/EU docs, barclaysMerchant = UK/GBP docs,
// which never consults merchant_map); adversarial cases pin the collisions we
// tightened the rules against (LOWESTOFT, TARGETED, MIETWAGEN) and document
// accepted limitations.
import XCTest
@testable import PennyTxnStore

final class VocabularyEdgeCaseTests: XCTestCase {
    private var cats: Categories!

    override func setUpWithError() throws {
        cats = try Categories(categoriesJSONPath: TestPaths.categoriesJSON.path)
    }

    private func cat(_ descr: String, credit: Bool = false) -> String {
        Classify.classify(descr, isCredit: credit, categories: cats).1
    }
    private func ukCat(_ descr: String, credit: Bool = false) -> String {
        Classify.barclaysMerchant(descr, isCredit: credit, categories: cats).1
    }

    // MARK: - US merchants (classify route — what a USD statement uses)

    func testUSMerchantsCategorize() {
        XCTAssertEqual(cat("WALMART SUPERCENTER 1234"), "Groceries")
        XCTAssertEqual(cat("TARGET T-0821"), "Shopping")
        XCTAssertEqual(cat("COSTCO WHSE #482"), "Groceries")
        XCTAssertEqual(cat("TRADER JOES #553"), "Groceries")
        XCTAssertEqual(cat("CHEWY.COM"), "Shopping")
        XCTAssertEqual(cat("HOME DEPOT #1301"), "Shopping")
        XCTAssertEqual(cat("AT&T WIRELESS PAYMENT"), "Utilities")
        XCTAssertEqual(cat("CON EDISON UTILITY"), "Utilities")
        XCTAssertEqual(cat("VERIZON WIRELESS"), "Utilities")
        XCTAssertEqual(cat("T-MOBILE AUTOPAY"), "Utilities")
        XCTAssertEqual(cat("COMCAST CABLE"), "Utilities")
        XCTAssertEqual(cat("XFINITY MOBILE"), "Utilities")
        XCTAssertEqual(cat("WALGREENS #0405"), "Healthcare")
        XCTAssertEqual(cat("CVS PHARMACY 7211"), "Healthcare")
        XCTAssertEqual(cat("KROGER FUEL CTR"), "Groceries",
                       "merchant_map kroger must beat the later fuel keyword")
        XCTAssertEqual(cat("SAFEWAY STORE 992"), "Groceries")
        XCTAssertEqual(cat("WHOLE FOODS MKT"), "Groceries")
        XCTAssertEqual(cat("BEST BUY #556"), "Shopping")
        XCTAssertEqual(cat("LOWES #02214"), "Shopping")
    }

    // MARK: - EU merchants (both routes: EUR docs use classify; the French/
    // Swiss specimens are GBP-sniffed and use barclaysMerchant)

    func testEUMerchantsCategorizeOnBothRoutes() {
        for f in [cat, ukCat] {
            XCTAssertEqual(f("REWE MARKT GMBH", false), "Groceries")
            XCTAssertEqual(f("EDEKA CENTER 55", false), "Groceries")
            XCTAssertEqual(f("APOTHEKE HAUPTBAHNHOF", false), "Healthcare")
            XCTAssertEqual(f("DEUTSCHE BAHN TICKET", false), "Transport")
            XCTAssertEqual(f("MIETE DAUERAUFTRAG", false), "Rent")
            XCTAssertEqual(f("SAMPLE LOYER SARL", false), "Rent")
            XCTAssertEqual(f("FAKE STATION ESSENCE", false), "Transport")
            XCTAssertEqual(f("SPECIMEN BANKOMAT BEZUG", false), "Cash")
            XCTAssertEqual(f("FAKE KINO AG", false), "Entertainment")
            XCTAssertEqual(f("TEST HAUSRATVERSICHERUNG", false), "Investment & Insurance")
            XCTAssertEqual(f("DEMO MOBILFUNK AG", false), "Utilities")
            XCTAssertEqual(f("SAMPLE WASSERWERK", false), "Utilities")
            XCTAssertEqual(f("SPECIMEN GEMEINDESTEUER", false), "Utilities")
        }
    }

    // MARK: - generic English terms that rescue the UK route

    func testGenericTermsOnUKRoute() {
        XCTAssertEqual(ukCat("DEMO MOBILE NETWORK"), "Utilities")
        XCTAssertEqual(ukCat("SAMPLE WATER COMPANY"), "Utilities")
        XCTAssertEqual(ukCat("SPECIMEN ENERGY CO"), "Utilities")
        XCTAssertEqual(ukCat("DEMO HARDWARE STORE"), "Shopping")
        XCTAssertEqual(ukCat("TEST STREAMING SERVICE"), "Entertainment")
        XCTAssertEqual(ukCat("FAKE TAXI SERVICE"), "Transport")
        XCTAssertEqual(ukCat("DEMO BOOKSHOP"), "Shopping")
        XCTAssertEqual(ukCat("TEST ONLINE SHOP"), "Shopping")
        XCTAssertEqual(ukCat("SAMPLE FITNESSCENTER"), "Entertainment")
    }

    // MARK: - adversarial: the collisions the rules were tightened against

    func testTightenedRulesAvoidPrefixCollisions() {
        // LOWESTOFT (UK town) must NOT hit the "lowes " store rule; the
        // earlier council/parking/cafe terms or nothing at all may claim it,
        // but never Shopping-via-Lowe's.
        XCTAssertEqual(ukCat("LOWESTOFT TOWN COUNCIL"), "Utilities", "council term wins")
        XCTAssertNotEqual(ukCat("LOWESTOFT MARKET STALL"), "Shopping",
                          "bare LOWESTOFT must not match the Lowe's rule")
        // TARGETED …: benefits/support wording must not become Shopping.
        XCTAssertNotEqual(ukCat("TARGETED SUPPORT PAYMENT", credit: true), "Shopping")
        XCTAssertEqual(cat("TARGET.COM ORDER"), "Shopping", "target.com still matches")
        // MIETWAGEN (rental car) is Transport, not Rent, despite the miete prefix.
        XCTAssertEqual(ukCat("MIETWAGEN EUROPCAR"), "Transport")
        XCTAssertEqual(cat("MIETWAGEN SIXT"), "Transport")
        // Plain MIETE stays Rent.
        XCTAssertEqual(ukCat("KALTMIETE JULI"), "Other",
                       "mid-word miete (KALTMIETE) does not match — documented prefix-only limitation")
    }

    // MARK: - adversarial: credits, case, and boundary behaviour

    func testCreditsAndCaseBehaviour() {
        // Unmatched credits fall to Income, never Other.
        XCTAssertEqual(cat("SEPA GUTSCHRIFT RANDOM GMBH", credit: true), "Income")
        // Matched credits keep the matched category (refund rule precedes).
        XCTAssertEqual(cat("REFUND - TARGET.COM", credit: true), "Income",
                       "refund merchant rule outranks the shopping term")
        // Case-insensitivity.
        XCTAssertEqual(cat("walmart neighborhood mkt"), "Groceries")
        XCTAssertEqual(ukCat("apotheke am dom"), "Healthcare")
        // Hyphen is a word boundary: KFZ-VERSICHERUNG matches versicherung.
        XCTAssertEqual(ukCat("KFZ-VERSICHERUNG ALLIANZ"), "Investment & Insurance")
        // Single-word CONEDISON does NOT match the two-word rule — documented
        // limitation, stays Other on the UK route.
        XCTAssertEqual(ukCat("CONEDISON PAYMENT"), "Other")
        // AT&T requires the ampersand form; bare ATT stays unmatched.
        XCTAssertEqual(ukCat("ATT PAYMENT"), "Other")
    }

    // MARK: - first-match-wins ordering still intact after the appends

    func testPriorityOrderingUnchanged() {
        XCTAssertEqual(cat("SWIGGYINSTAMART ORDER"), "Groceries",
                       "longer swiggyinstamart key must still precede swiggy")
        XCTAssertEqual(cat("UBER EATS ORDER 42"), "Food & Dining",
                       "uber eats must still beat the plain uber transport rule")
        XCTAssertEqual(cat("UBER TRIP HOME"), "Transport")
        XCTAssertEqual(ukCat("TESCO PETROL FILLING STATION"), "Transport",
                       "tesco petrol must still beat plain tesco groceries")
        XCTAssertEqual(ukCat("TESCO STORES 2231"), "Groceries")
    }
}
