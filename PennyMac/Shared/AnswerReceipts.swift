// AnswerReceipts — the scope + transactions behind a chat answer (Fixes 4 & 5).
//
// Shared by both apps. Codable so it rides along in persisted chat history, and
// deliberately a lightweight projection of TxnRow (which isn't Codable) — just
// what the receipts list needs to render.
import Foundation
import PennyTxnStore

struct ReceiptRow: Codable, Equatable {
    var date: String
    var name: String        // merchant, or description when no merchant
    var amount: Double      // the money that moved (always positive)
    var isCredit: Bool      // money in vs money out
    var currency: String
}

struct AnswerReceipts: Codable, Equatable {
    var scopeLabel: String  // Fix 5 — "on Groceries in June · money out"
    var rows: [ReceiptRow]  // Fix 4 — the transactions behind the figure
    var totalCount: Int     // true total in scope (may exceed rows.count when capped)

    /// Build from the router's scope context. Caps the list so a huge scope
    /// doesn't bloat a chat bubble (the count still reflects the true total).
    init?(from ctx: FinanceRouter.AnswerScope, limit: Int = 50) {
        guard !ctx.rows.isEmpty else { return nil }
        scopeLabel = ctx.label
        totalCount = ctx.rows.count
        rows = ctx.rows.prefix(limit).map {
            ReceiptRow(date: $0.txnDate,
                       name: $0.merchant.isEmpty ? $0.descr : $0.merchant,
                       amount: $0.credit > 0 ? $0.credit : $0.debit,
                       isCredit: $0.credit > 0,
                       currency: $0.currency)
        }
    }
}
