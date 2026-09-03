import XCTest
import PennyFinance
import PennyModel
@testable import PennyCore

/// The live half of the LLM-as-parser tier. `testLiveGuidedParses` needs the
/// Apple system model at runtime, so it is env-gated (PENNY_PARSE_LIVE=1) like
/// the LLM smoke tests; the JSON-decoding test always runs.
final class QueryParserLiveTests: XCTestCase {

    func testDecodeJSONFromNoisyModelText() {
        let raw = """
        Sure! Here is the JSON you asked for:
        {"aggregate": "sum", "direction": "debit", "category": "pharmacy"}
        Hope that helps.
        """
        let dto = QueryParser.decodeJSON(raw)
        XCTAssertEqual(dto?.aggregate, "sum")
        XCTAssertEqual(dto?.direction, "debit")
        XCTAssertEqual(dto?.category, "pharmacy")
        XCTAssertNil(QueryParser.decodeJSON("no json here"))
    }

    func testLiveGuidedParses() async throws {
        guard ProcessInfo.processInfo.environment["PENNY_PARSE_LIVE"] == "1" else {
            throw XCTSkip("set PENNY_PARSE_LIVE=1 to run live guided-generation parse tests")
        }
        let vocab = QueryVocabulary(
            categories: ["Pharmacy", "Fast Food", "Shopping", "Income"],
            merchants: ["Amazon", "KFC", "Medplus"],
            accounts: [.init(name: "Hdfc Savings", id: "a1")],
            currencies: ["INR"],
            months: ["2026-01", "2026-02"],
            dateRange: CalendarDateRange(start: CalendarDate(year: 2026, month: 1, day: 1),
                                         end: CalendarDate(year: 2026, month: 2, day: 28)))
        let today = CalendarDate(year: 2026, month: 9, day: 3)

        // Question → (expected aggregate, a filter that must be present).
        let cases: [(String, Aggregation, Filter?)] = [
            ("how much did i spend on pharmacy?", .sum, .category(CategoryID("Pharmacy"))),
            ("how many payments did i make?", .count, .direction(.debit)),
            ("what was my biggest expense?", .max, .direction(.debit)),
            ("total income?", .sum, .direction(.credit)),
            ("spending by month?", .sum, nil),
        ]
        for (question, aggregate, filter) in cases {
            let out = await QueryParser.parse(question: question, vocabulary: vocab, today: today)
            XCTAssertNotNil(out, "no parse for: \(question)")
            guard let out else { continue }
            XCTAssertEqual(out.query.aggregate, aggregate, question)
            if let filter {
                XCTAssertTrue(out.query.filters.contains(filter),
                              "\(question) → \(out.query.filters)")
            }
        }
    }
}
