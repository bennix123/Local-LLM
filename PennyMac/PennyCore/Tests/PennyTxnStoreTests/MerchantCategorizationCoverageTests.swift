// MerchantCategorizationCoverageTests — locks the "500 expense types" training:
// a representative merchant from every category (UK/US/EU/IN) must resolve to the
// right Penny category through the deterministic `Categories.categorize` path.
// Guards against vocabulary regressions when categories.json is edited.
import XCTest
@testable import PennyTxnStore

final class MerchantCategorizationCoverageTests: XCTestCase {

    /// Uses the contract categories.json (same file the app bundles / the CLI
    /// reads), resolved via TestPaths so the suite passes on every machine —
    /// the previous hardcoded absolute path only existed on one dev's Mac.
    private func cats() throws -> Categories {
        try Categories(categoriesJSONPath: TestPaths.categoriesJSON.path)
    }

    /// (merchant, expected category) — a cross-section of the 500-entry training
    /// set, including the ones that were "Other" before this vocabulary pass.
    private let expected: [(String, String)] = [
        // Groceries
        ("Tesco", "Groceries"), ("Waitrose", "Groceries"), ("Whole Foods", "Groceries"),
        ("Publix", "Groceries"), ("Costcutter", "Groceries"), ("REWE", "Groceries"),
        // Food & Dining
        ("Nando's", "Food & Dining"), ("Pret A Manger", "Food & Dining"),
        ("Caffe Nero", "Food & Dining"), ("Shake Shack", "Food & Dining"),
        ("Dishoom", "Food & Dining"), ("The Craft Beer Co", "Food & Dining"),
        ("Wagamama", "Food & Dining"), ("Popeyes", "Food & Dining"),
        // Transport
        ("TFL", "Transport"), ("Trainline", "Transport"), ("Lime", "Transport"),
        ("Forest", "Transport"), ("Megabus", "Transport"), ("EasyJet", "Transport"),
        ("Cabify", "Transport"),
        // Shopping
        ("Amazon", "Shopping"), ("Argos", "Shopping"), ("Waterstones", "Shopping"),
        ("Etsy", "Shopping"), ("Shein", "Shopping"), ("Nordstrom", "Shopping"),
        // Subscriptions
        ("Netflix", "Subscriptions"), ("Spotify", "Subscriptions"),
        ("Adobe Creative Cloud", "Subscriptions"), ("Dropbox", "Subscriptions"),
        ("Peloton", "Subscriptions"), ("Strava", "Subscriptions"),
        // Entertainment
        ("Cineworld", "Entertainment"), ("Ticketmaster", "Entertainment"),
        ("Eventbrite", "Entertainment"), ("Legoland", "Entertainment"),
        // Healthcare
        ("Boots", "Healthcare"), ("Specsavers", "Healthcare"), ("Care Dental", "Healthcare"),
        ("Rite Aid", "Healthcare"),
        // Utilities
        ("British Gas", "Utilities"), ("Octopus Energy", "Utilities"),
        ("Vodafone", "Utilities"), ("Thames Water", "Utilities"),
        // Rent
        ("Foxtons", "Rent"), ("Rightmove", "Rent"), ("Zoopla", "Rent"),
        // Cash
        ("ATM Withdrawal", "Cash"), ("Cash Machine", "Cash"),
        // Fees & Charges
        ("Overdraft Fee", "Fees & Charges"), ("Foreign Transaction Fee", "Fees & Charges"),
        ("Currency Conversion Fee", "Fees & Charges"),
        // Education
        ("Coursera", "Education"), ("Udemy", "Education"), ("Skillshare", "Education"),
        ("Chegg", "Education"),
        // Income
        ("Salary", "Income"), ("Dividend", "Income"), ("Universal Credit", "Income"),
        ("HMRC", "Income"),
        // Transfers
        ("Standing Order", "Transfers"), ("Faster Payment", "Transfers"),
        // Investment & Insurance
        ("Vanguard", "Investment & Insurance"), ("Aviva", "Investment & Insurance"),
        ("Coinbase", "Investment & Insurance"), ("Nutmeg", "Investment & Insurance"),
    ]

    /// The merchants added in the vocabulary-expansion pass — realistic statement
    /// descriptors (with card noise), each of which was "Other" before.
    private let expandedSample: [(String, String)] = [
        ("LYFT RIDE SF", "Transport"), ("EUROSTAR LONDON", "Transport"),
        ("NAMMA YATRI BLR", "Transport"), ("FLIXBUS DE", "Transport"),
        ("WAYFAIR ORDER 8821", "Shopping"), ("TEMU ORDER", "Shopping"),
        ("LULULEMON REGENT ST", "Shopping"), ("CLARKS OXFORD ST", "Shopping"),
        ("NORDVPN.COM", "Subscriptions"), ("CHATGPT SUBSCRIPTION", "Subscriptions"),
        ("PEACOCK TV", "Subscriptions"), ("1PASSWORD", "Subscriptions"),
        ("BET365 STAKE", "Entertainment"), ("SEE TICKETS", "Entertainment"),
        ("PVR CINEMAS MUMBAI", "Entertainment"),
        ("CVS PHARMACY 04521", "Healthcare"), ("TATA 1MG ORDER", "Healthcare"),
        ("PANERA BREAD 22", "Food & Dining"), ("DOORDASH SF", "Food & Dining"),
        ("TOBY CARVERY", "Food & Dining"), ("JOLLIBEE", "Food & Dining"),
        ("MORRISONS PETROL", "Groceries"), ("MEIJER 118", "Groceries"),
        ("ADANI ELECTRICITY", "Utilities"), ("SPECTRUM INTERNET", "Utilities"),
        ("MINT MOBILE", "Utilities"),
        ("ROBINHOOD GOLD", "Investment & Insurance"),
        ("GEICO INSURANCE", "Investment & Insurance"),
        ("HARGREAVES LANSDOWN", "Investment & Insurance"),
        ("UDEMY COURSE", "Education"), ("PHYSICS WALLAH", "Education"),
        ("SIMPLILEARN", "Education"),
    ]

    func testRepresentativeMerchantsCategorize() throws {
        let c = try cats()
        var wrong: [String] = []
        for (m, want) in expected + expandedSample {
            let got = c.categorize(m)
            if got != want { wrong.append("\(m): got \(got), want \(want)") }
        }
        XCTAssertTrue(wrong.isEmpty,
                      "vocabulary regressed for:\n" + wrong.joined(separator: "\n"))
    }

    /// The whole sample must stay ≥ 95% correct (the training target).
    func testCoverageStaysAboveTarget() throws {
        let c = try cats()
        let ok = expected.filter { c.categorize($0.0) == $0.1 }.count
        let pct = Double(ok) / Double(expected.count)
        XCTAssertGreaterThanOrEqual(pct, 0.95,
            "categorization coverage \(Int(pct * 100))% fell below the 95% target")
    }
}
