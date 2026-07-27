import XCTest
import Foundation
@testable import PennyTxnStore

/// Locks in Penny's deterministic behaviour against the "Penny AI Training Starter
/// Dataset" (10 merchant mappings, 200 sample transactions, 6 questions), stored in
/// `test-data/training-dataset/`.
///
/// Decision (2026-07-26): we KEEP Penny's own, richer category taxonomy — the
/// dataset's coarser labels (Food, Fuel, Entertainment) are NOT ground truth. So
/// this test pins the fixed dataset→Penny mapping: Penny is more granular
/// (Food & Dining, Transport for fuel, Subscriptions for streaming), and that is
/// the intended, asserted behaviour — not a mismatch to fix.
final class TrainingDatasetTests: XCTestCase {

    private var datasetDir: URL {
        TestPaths.testDataDir.appendingPathComponent("training-dataset", isDirectory: true)
    }

    // Penny's category for each dataset merchant (its taxonomy, deliberately richer).
    private let pennyCategory: [String: String] = [
        "Amazon": "Shopping",
        "Apollo Pharmacy": "Healthcare",
        "DMart": "Groceries",
        "Flipkart": "Shopping",
        "Indian Oil": "Transport",     // Penny folds Fuel into Transport
        "Netflix": "Subscriptions",    // dataset says Entertainment
        "Spotify": "Subscriptions",
        "Swiggy": "Food & Dining",     // dataset says Food
        "Uber": "Transport",
        "Zomato": "Food & Dining",
    ]

    func testCategorizerMatchesPennyTaxonomy() throws {
        let cats = try Categories(categoriesJSONPath: TestPaths.categoriesJSON.path)
        // The merchant list itself comes from the dataset file, so the fixture stays
        // the source of truth; the expected label is Penny's taxonomy.
        let mm = try JSONSerialization.jsonObject(
            with: Data(contentsOf: datasetDir.appendingPathComponent("merchant_mapping.json"))) as! [String: [String: String]]

        for merchant in mm.keys.sorted() {
            let (_, cat) = Classify.classify(merchant, isCredit: false, categories: cats)
            if let want = pennyCategory[merchant] {
                XCTAssertEqual(cat, want, "\(merchant): categorizer drifted from Penny's taxonomy")
            }
        }
    }

    private struct Tx: Decodable {
        let date: String; let description: String; let merchant: String
        let category: String; let amount: Double; let type: String
    }

    private func sampleRows() throws -> [TxnRow] {
        let txs = try JSONDecoder().decode(
            [Tx].self, from: Data(contentsOf: datasetDir.appendingPathComponent("sample_transactions.json")))
        return txs.enumerated().map { (i, t) in
            let p = t.date.split(separator: "-").map { Int($0)! }
            let credit = t.type == "credit"
            return TxnRow(txnDate: t.date, month: String(t.date.prefix(7)), year: p[0], monthNo: p[1], day: p[2],
                          descr: t.description, merchant: t.merchant, category: t.category,
                          debit: credit ? 0 : t.amount, credit: credit ? t.amount : 0,
                          balance: nil, currency: "INR", seq: i + 1)
        }
    }

    /// The deterministic router answers the training questions on the sample data.
    /// The dataset is all-debit, single-month, randomised amounts — so "salary" and
    /// "recurring" correctly return nothing, and a list-retrieval query defers to the
    /// LLM. These assertions document that intended behaviour.
    func testRouterAnswersTrainingQuestions() throws {
        let rows = try sampleRows()
        XCTAssertEqual(rows.count, 200)
        XCTAssertEqual(rows.filter { $0.credit > 0 }.count, 0, "dataset is all debits")

        let inr: (Double) -> String = { "₹" + String(format: "%.0f", $0) }
        func ask(_ q: String) -> String? { FinanceRouter.answer(q, rows: rows, currency: "INR", money: inr) }

        // Spend total covers all 200 rows.
        XCTAssertEqual(ask("How much did I spend this month?")?.contains("200 transactions"), true)

        // Category question resolves against the (dataset-labelled) rows.
        let food = ask("How much did I spend on food?")
        XCTAssertEqual(food?.contains("Food"), true, "food answer: \(food ?? "nil")")

        // No credits ⇒ salary is zero (correct, not a bug).
        XCTAssertEqual(ask("How much salary did I receive?")?.contains("₹0"), true)

        // Randomised amounts + single month ⇒ nothing qualifies as recurring.
        XCTAssertEqual(ask("Show recurring subscriptions.")?.lowercased().contains("no recurring"), true)

        // Largest expense is answerable.
        XCTAssertEqual(ask("Largest expense last month?")?.contains("largest expense"), true)

        // A list-retrieval intent is deliberately deferred to the LLM (router owns
        // aggregates, not row listings).
        XCTAssertNil(ask("Show Amazon purchases."), "list-retrieval should defer to the LLM")
    }
}
