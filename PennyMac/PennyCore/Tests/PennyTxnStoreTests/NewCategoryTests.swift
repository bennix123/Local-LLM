// NewCategoryTests — pins the 2026-07-25 taxonomy expansion: three new
// categories in contract/categories.json (Fees & Charges, Education,
// Subscriptions). Subscriptions is a NEW rule entry placed BEFORE both
// Entertainment entries (first-match-wins), so the pure-subscription terms
// (netflix, spotify, streaming, gym memberships, …) moved out of
// Entertainment while cinema / gaming / events stayed put; the netflix /
// spotify / hotstar / jiocinema / sonyliv / zee5 merchant_map entries moved
// with them. Positive cases pin every new category on BOTH classifier routes
// (classify = US/IN/EU docs, merchant_map first; barclaysMerchant = UK/GBP
// docs, keyword rules only). Adversarial cases pin the prefix hazards the
// term list was chosen against: "penal" is a safe leading-boundary prefix
// (PENALTY yes, ALPENALM no), there is deliberately NO bare "fee"/"fees"
// term (COFFEE/TOFFEE can never become a fee), "tuition" can't fire inside
// INTUITION, and "interest charged" (debit fee) never collides with the
// "interest earned" Income vocabulary. Every expected value was
// ground-truthed by executing the Python reference classifier semantics
// against the updated contract categories.json.
import XCTest
@testable import PennyTxnStore

final class NewCategoryTests: XCTestCase {
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

    // MARK: - Fees & Charges (both routes)

    func testFeesAndChargesOnBothRoutes() {
        for f in [cat, ukCat] {
            XCTAssertEqual(f("OVERDRAFT FEE", false), "Fees & Charges")
            XCTAssertEqual(f("ANNUAL FEE - PLATINUM CARD", false), "Fees & Charges")
            XCTAssertEqual(f("LATE PAYMENT FEE", false), "Fees & Charges")
            XCTAssertEqual(f("SERVICE CHARGE Q2", false), "Fees & Charges")
            XCTAssertEqual(f("MONTHLY MAINTENANCE CHARGE", false), "Fees & Charges")
            XCTAssertEqual(f("FINANCE CHARGE", false), "Fees & Charges")
            XCTAssertEqual(f("CARD FEE INTERNATIONAL MARKUP", false), "Fees & Charges")
            XCTAssertEqual(f("INTEREST CHARGED ON ARRANGED OD", false), "Fees & Charges")
            XCTAssertEqual(f("PENAL INTEREST", false), "Fees & Charges")
            XCTAssertEqual(f("PENALTY FOR LATE PAYMENT", false), "Fees & Charges",
                           "penal is a prefix: PENALTY matches")
        }
    }

    // MARK: - Education (both routes)

    func testEducationOnBothRoutes() {
        for f in [cat, ukCat] {
            XCTAssertEqual(f("SCHOOL FEES PAYMENT", false), "Education")
            XCTAssertEqual(f("TUITION - SPRING TERM", false), "Education")
            XCTAssertEqual(f("UNIVERSITY FEE INSTALMENT", false), "Education")
            XCTAssertEqual(f("EXAM FEE - BOARD", false), "Education")
            XCTAssertEqual(f("COURSERA.ORG", false), "Education")
            XCTAssertEqual(f("UDEMY ONLINE COURSE", false), "Education")
            XCTAssertEqual(f("KHAN ACADEMY DONATION", false), "Education")
        }
    }

    // MARK: - Subscriptions (both routes)

    func testSubscriptionsOnBothRoutes() {
        for f in [cat, ukCat] {
            XCTAssertEqual(f("NETFLIX.COM", false), "Subscriptions")
            XCTAssertEqual(f("SPOTIFY P2E4A6", false), "Subscriptions")
            XCTAssertEqual(f("DISNEY PLUS", false), "Subscriptions")
            XCTAssertEqual(f("AMAZON PRIME VIDEO", false), "Subscriptions")
            XCTAssertEqual(f("YOUTUBE PREMIUM", false), "Subscriptions")
            XCTAssertEqual(f("AUDIBLE UK", false), "Subscriptions")
            XCTAssertEqual(f("NOW TV MEMBERSHIP", false), "Subscriptions")
            // gym memberships are recurring charges, not entertainment
            XCTAssertEqual(f("PUREGYM LTD", false), "Subscriptions")
            XCTAssertEqual(f("ANYTIME FITNESS DD", false), "Subscriptions")
            XCTAssertEqual(f("CULT.FIT MEMBERSHIP", false), "Subscriptions")
            XCTAssertEqual(f("GYM MEMBERSHIP DD", false), "Subscriptions")
        }
        // merchant_map route: the moved streaming tokens carry the new category.
        XCTAssertEqual(cat("UPI-HOTSTAR-RENEWAL"), "Subscriptions")
        XCTAssertEqual(cat("SONYLIV ANNUAL PLAN"), "Subscriptions")
    }

    // MARK: - the Subscriptions/Entertainment split

    func testCinemaGamingEventsStayEntertainment() {
        for f in [cat, ukCat] {
            XCTAssertEqual(f("VUE CINEMA LUTON", false), "Entertainment")
            XCTAssertEqual(f("PVR INOX TICKETS", false), "Entertainment")
            XCTAssertEqual(f("CINEWORLD", false), "Entertainment")
            XCTAssertEqual(f("TICKETMASTER CONCERT", false), "Entertainment")
            XCTAssertEqual(f("PLAYSTATION NETWORK", false), "Entertainment")
            XCTAssertEqual(f("STEAM GAMES 42", false), "Entertainment")
            // youtube premium moved, youtube music/plain youtube did not
            XCTAssertEqual(f("YOUTUBE MUSIC", false), "Entertainment")
        }
        // merchant_map: BookMyShow (events) stays Entertainment.
        XCTAssertEqual(cat("BOOKMYSHOW ORDER"), "Entertainment")
        // "now tv" moved to Subscriptions but NOW BROADBAND is still a utility.
        XCTAssertEqual(ukCat("NOW BROADBAND MONTHLY"), "Utilities")
    }

    // MARK: - adversarial prefixes and vocabulary collisions

    func testAdversarialPrefixSafety() {
        // No bare "fee"/"fees" rule term exists, so coffee can never be a fee.
        XCTAssertEqual(cat("BLUE TOKAI COFFEE"), "Food & Dining")
        XCTAssertEqual(ukCat("COSTA COFFEE 1234"), "Food & Dining")
        XCTAssertNotEqual(ukCat("TOFFEE FACTORY GIFT SHOP"), "Fees & Charges")
        // "penal" needs a leading word boundary: mid-word PENAL (ALPENALM, the
        // German alpine hut) must not match.
        XCTAssertEqual(ukCat("ALPENALM"), "Other")
        // "tuition" can't fire inside INTUITION.
        XCTAssertNotEqual(ukCat("INTUITION CONSULTING LTD"), "Education")
    }

    func testInterestChargedVsInterestEarned() {
        // "interest charged" (a debit fee) and "interest earned" (a credit,
        // Income via merchant_map on classify and via the Income rule on the
        // UK route) must never collide, in either direction.
        XCTAssertEqual(cat("INTEREST CHARGED"), "Fees & Charges")
        XCTAssertEqual(cat("INTEREST EARNED", credit: true), "Income")
        XCTAssertEqual(ukCat("INTEREST CHARGED"), "Fees & Charges")
        XCTAssertEqual(ukCat("INTEREST EARNED 2.5%", credit: true), "Income")
    }

    // MARK: - hint normalization picks up the three new names

    func testNormalizeCategoryNewNames() {
        XCTAssertEqual(Describe.normalizeCategory("Subscriptions"), "Subscriptions")
        XCTAssertEqual(Describe.normalizeCategory("Education"), "Education")
        XCTAssertEqual(Describe.normalizeCategory("Tuition"), "Education")
        XCTAssertEqual(Describe.normalizeCategory("Fees"), "Fees & Charges")
        XCTAssertEqual(Describe.normalizeCategory("Bank Charges"), "Fees & Charges")
        XCTAssertEqual(Describe.normalizeCategory("Overdraft"), "Fees & Charges")
        // Entertainment hints stay Entertainment.
        XCTAssertEqual(Describe.normalizeCategory("Entertainment"), "Entertainment")
        XCTAssertEqual(Describe.normalizeCategory("Cinema"), "Entertainment")
    }
}
