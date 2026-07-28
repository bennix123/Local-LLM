// CategoryMopupTests — the pure AI-fallback graph rewrite (Engine v2, Step 3).
// No network: `ClaudeCategorization` results are hand-built and fed to
// `CategoryMopup.apply`, so the accept threshold, spend-only scope, category
// registration, and no-op guarantees are pinned without an API key.
import XCTest
import PennyModel
@testable import PennyTxnStore

final class CategoryMopupTests: XCTestCase {

    /// Build a graph through the real assembler, so category IDs and debit/credit
    /// signs match production exactly.
    private func makeGraph(_ rows: [TxnRow]) -> FinancialGraph {
        let out = IngestOutput(rows: rows, bankName: "Test Bank", confidence: "test",
                               detectedCurrency: "GBP")
        return ModelAssembler.assemble(out, sourceName: "test.pdf").graph
    }

    private func row(_ seq: Int, _ descr: String, _ category: String,
                     debit: Double = 0, credit: Double = 0) -> TxnRow {
        TxnRow(txnDate: "2026-02-01", month: "2026-02", year: 2026, monthNo: 2, day: 1,
               descr: descr, merchant: "", category: category,
               debit: debit, credit: credit, balance: nil, currency: "GBP", seq: seq)
    }

    private func category(_ g: FinancialGraph, _ descr: String) -> String? {
        g.transactions.first { $0.rawDescription == descr }?.enrichment.categoryID?.raw
    }

    // Only "Other" DEBIT descriptors are handed to the categorizer, de-duplicated.
    func testUnresolvedDescriptorsAreOtherDebitsOnly() {
        let g = makeGraph([
            row(0, "DOJO*OBSCURE MERCHANT", "Other", debit: 10),
            row(1, "PRET A MANGER", "Food & Dining", debit: 5),
            row(2, "MYSTERY CREDIT", "Other", credit: 20),
            row(3, "DOJO*OBSCURE MERCHANT", "Other", debit: 8),   // duplicate descriptor
        ])
        XCTAssertEqual(CategoryMopup.unresolvedDescriptors(in: g), ["DOJO*OBSCURE MERCHANT"])
    }

    // High-confidence, non-"Other" verdicts rewrite the matching "Other" debits;
    // credits and already-placed rows are untouched; the new category is registered.
    func testApplyRewritesHighConfidenceOtherDebits() {
        let g = makeGraph([
            row(0, "DOJO*OBSCURE MERCHANT", "Other", debit: 10),
            row(1, "PRET A MANGER", "Food & Dining", debit: 5),
            row(2, "MYSTERY CREDIT", "Other", credit: 20),
        ])
        let results = [
            ClaudeCategorization(merchant: "DOJO*OBSCURE MERCHANT", category: "Food & Dining", confidence: 0.95),
            ClaudeCategorization(merchant: "MYSTERY CREDIT", category: "Income", confidence: 0.99),
        ]
        let out = CategoryMopup.apply(results, to: g)

        XCTAssertEqual(category(out, "DOJO*OBSCURE MERCHANT"), "Food & Dining", "Other debit re-categorized")
        XCTAssertEqual(category(out, "MYSTERY CREDIT"), "Other", "credits are spend-only exempt")
        XCTAssertEqual(category(out, "PRET A MANGER"), "Food & Dining", "already-placed row untouched")
        XCTAssertTrue(out.categories.contains { $0.name == "Food & Dining" }, "new category registered")

        let t = out.transactions.first { $0.rawDescription == "DOJO*OBSCURE MERCHANT" }
        XCTAssertEqual(t?.enrichment.confidence[.category], 0.95, "AI confidence signal recorded")
    }

    // Below-threshold scores and "Other" verdicts change nothing — same graph value.
    func testLowConfidenceAndOtherVerdictsAreIgnored() {
        let g = makeGraph([
            row(0, "AMBIGUOUS ONE", "Other", debit: 10),
            row(1, "AMBIGUOUS TWO", "Other", debit: 12),
        ])
        let results = [
            ClaudeCategorization(merchant: "AMBIGUOUS ONE", category: "Shopping", confidence: 0.5),
            ClaudeCategorization(merchant: "AMBIGUOUS TWO", category: "Other", confidence: 0.99),
        ]
        XCTAssertEqual(CategoryMopup.apply(results, to: g), g)
    }

    // The 0.70 accept boundary is inclusive.
    func testThresholdBoundaryIsInclusive() {
        let g = makeGraph([row(0, "EDGE MERCHANT", "Other", debit: 10)])
        let out = CategoryMopup.apply(
            [ClaudeCategorization(merchant: "EDGE MERCHANT", category: "Transport", confidence: 0.70)], to: g)
        XCTAssertEqual(category(out, "EDGE MERCHANT"), "Transport")
    }

    // Empty results (no key / nothing to mop up) return the graph unchanged.
    func testEmptyResultsReturnGraphUnchanged() {
        let g = makeGraph([row(0, "WHATEVER", "Other", debit: 10)])
        XCTAssertEqual(CategoryMopup.apply([], to: g), g)
    }
}
