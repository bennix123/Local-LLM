import Foundation
import PennyModel

/// One auto-detected recurring charge / subscription (Wave A2). `amount` and
/// `confidence` are Doubles by design: recurrence is a *statistical* estimate over
/// a merchant's history, not an exact ledger figure — and this mirrors the legacy
/// `FinanceRouter.recurringCharges` math bit-for-bit so parity is provable.
public struct RecurringCharge: Equatable, Sendable {
    public let name: String
    public let months: Int          // distinct months it appeared in
    public let amount: Double        // typical (mean) magnitude
    public let count: Int            // number of occurrences
    public let confidence: Double    // 0…1 (1 − coefficient of variation)
    public let transactionIDs: [TransactionID]
}

/// The deterministic recurring-charge detector — the *dedicated analyzer* the
/// engine consumes (it never runs this itself). A merchant (or, absent one, the
/// raw description) that appears in ≥3 distinct months, ≥3 times, with a stable
/// amount (coefficient of variation ≤ 25%). A faithful port of
/// `FinanceRouter.recurringCharges` over the canonical model.
public enum RecurringAnalyzer {

    public static func analyze(_ graph: FinancialGraph) -> [RecurringCharge] {
        let merchantName = Dictionary(graph.merchants.map { ($0.id, $0.canonicalName) },
                                      uniquingKeysWith: { a, _ in a })

        var byKey: [String: [Transaction]] = [:]
        for t in graph.transactions where t.direction == .debit {
            let key = t.enrichment.merchantID.flatMap { merchantName[$0] } ?? t.rawDescription
            guard key.count >= 3 else { continue }
            byKey[key, default: []].append(t)
        }

        var found: [RecurringCharge] = []
        for (name, txns) in byKey {
            let months = Set(txns.map { monthKey($0.date) }).count
            guard txns.count >= 3, months >= 3 else { continue }
            let amts = txns.map { dbl($0.amount.magnitude) }
            let mean = amts.reduce(0, +) / Double(amts.count)
            guard mean > 0 else { continue }
            let variance = amts.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(amts.count)
            let cv = variance.squareRoot() / mean
            guard cv <= 0.25 else { continue }
            found.append(RecurringCharge(name: name, months: months, amount: mean,
                                         count: txns.count, confidence: 1 - cv,
                                         transactionIDs: txns.map(\.id)))
        }
        return found.sorted { $0.count > $1.count }
    }

    private static func monthKey(_ d: CalendarDate) -> String { String(format: "%04d-%02d", d.year, d.month) }
    private static func dbl(_ d: Decimal) -> Double { Double(d.description) ?? (d as NSDecimalNumber).doubleValue }
}
