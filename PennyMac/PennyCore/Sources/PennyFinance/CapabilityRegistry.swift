import Foundation

/// The migration lifecycle of a deterministic capability.
///   • implemented — the engine/bridge can produce it
///   • verified    — it reconciles with FinanceRouter (or the parsed source of truth)
///   • activated   — it is wired into the live chat path and may replace the router
/// Only `.activated` capabilities are allowed to supersede FinanceRouter (Decision 1).
public enum CapabilityState: String, Codable, CaseIterable, Comparable, Sendable {
    case implemented, verified, activated
    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: CapabilityState, b: CapabilityState) -> Bool { a.rank < b.rank }
}

/// A named unit of deterministic functionality. A capability — not an individual
/// intent — owns the lifecycle state; several intents (natural-language shapes) may
/// belong to one capability (e.g. the four balance intents share `balances`).
public struct Capability: Equatable, Sendable {
    public let id: String
    public let title: String
    public let state: CapabilityState
    /// The corpus intent keys this capability owns.
    public let intents: [String]

    public init(id: String, title: String, state: CapabilityState, intents: [String]) {
        self.id = id; self.title = title; self.state = state; self.intents = intents
    }
}

/// The single source of truth for what the deterministic layer can do and how far
/// each capability has progressed. The golden corpus and the activation invariants
/// read state from here — intents no longer carry their own state.
public enum CapabilityRegistry {

    public static let all: [Capability] = [
        // Wave A1 — transaction aggregates
        Capability(id: "count",              title: "Transaction count",     state: .activated,   intents: ["count", "count_debits", "count_credits"]),
        Capability(id: "total_spend",        title: "Total spending",        state: .activated,   intents: ["total_spend"]),
        Capability(id: "total_income",       title: "Total income",          state: .activated,   intents: ["total_income"]),
        Capability(id: "net_cashflow",       title: "Net cash flow",         state: .verified,    intents: ["net_cashflow"]),
        Capability(id: "average",            title: "Average transaction",   state: .verified,    intents: ["average_transaction"]),
        Capability(id: "extreme_expense",    title: "Extreme expense",       state: .verified,    intents: ["largest_expense", "smallest_expense"]),
        Capability(id: "top_n",              title: "Top-N expenses",        state: .verified,    intents: ["topN_expenses"]),
        Capability(id: "category_breakdown", title: "Spending by category",  state: .verified,    intents: ["spend_by_category"]),
        Capability(id: "monthly_summary",    title: "Monthly summary",       state: .implemented, intents: ["monthly_summary"]),
        // Wave A2 — balances & recurring
        Capability(id: "balances",           title: "Balances",              state: .verified,
                   intents: ["balance_opening", "balance_closing", "balance_running", "balance_at_date"]),
        Capability(id: "recurring",          title: "Recurring charges",     state: .verified,    intents: ["recurring"]),
        // Wave B1 — structured deterministic scope resolution
        Capability(id: "scope",              title: "Structured scope",      state: .verified,
                   intents: ["scope_category", "scope_merchant", "scope_date", "scope_month",
                             "scope_account", "scope_currency"]),
        // Wave B2 — natural-language scope enhancements
        Capability(id: "scope_nl",           title: "NL scope enhancements", state: .verified,
                   intents: ["scope_synonym", "scope_alias", "scope_relative_month",
                             "scope_longest_match", "scope_ambiguity"]),
    ]

    /// The capability that owns a corpus intent key, if any.
    public static func capability(forIntent intent: String) -> Capability? {
        all.first { $0.intents.contains(intent) }
    }
}
