/// One imported statement document (architecture layer L1). Immutable value type.
/// Carries the header figures the old pipeline discarded and re-scraped from raw
/// text at query time — those figures are now parsed once, here.
///
/// Deliberately holds **no** `totalIn` / `totalOut`: those are derived sums, not
/// source-of-truth facts, and belong in the Phase 4 knowledge cache (decision D1).
///
/// Balance fields are stored **exactly as the statement prints them** (Amendment
/// 01, Decision 5); `Money` is neutral, and the owning `Account.Kind` decides
/// whether a balance is an asset (`.current`/`.savings`) or a liability owed
/// (`.credit`). No negation happens here.
public struct Statement: Identifiable, Equatable, Codable, Sendable {

    /// Stable identity; the target of `Transaction.statementID` and the grouping
    /// key for citations. Derivation deferred to Task 0.4/0.5.
    public let id: StatementID

    /// The account this statement belongs to. Consumed by: 0.4, Phase 1
    /// (statement-scoped and per-account queries).
    public let accountID: AccountID

    /// The original file name — provenance, and the fallback for re-parsing from
    /// source if a persistence migration fails. Consumed by: 0.6, display.
    public let sourceName: String

    /// The period the statement covers, timezone-free (Amendment 01). Consumed by:
    /// Phase 1 ("statement period for Barclays" answered from the model). Optional.
    public let period: CalendarDateRange?

    /// The statement's issue date, timezone-free. Consumed by: Phase 1 "as of"
    /// anchoring. Optional.
    public let statementDate: CalendarDate?

    /// Declared opening balance, as printed. Consumed by: Phase 1 (replaces the
    /// query-time `moneyAfterLabel` re-scrape). Optional — Barclays states none.
    public let openingBalance: Money?

    /// Declared closing balance, as printed (asset or liability per `Account.Kind`).
    /// Consumed by: Phase 1, Phase 4 balance KPIs. Optional.
    public let closingBalance: Money?

    /// Available balance from a credit-card summary block. Consumed by: Phase 1
    /// card queries. Optional (cards only).
    public let availableBalance: Money?

    /// Credit limit from a credit-card summary block. Consumed by: Phase 1 card
    /// queries. Optional (cards only).
    public let creditLimit: Money?

    public init(id: StatementID, accountID: AccountID, sourceName: String,
                period: CalendarDateRange? = nil, statementDate: CalendarDate? = nil,
                openingBalance: Money? = nil, closingBalance: Money? = nil,
                availableBalance: Money? = nil, creditLimit: Money? = nil) {
        self.id = id
        self.accountID = accountID
        self.sourceName = sourceName
        self.period = period
        self.statementDate = statementDate
        self.openingBalance = openingBalance
        self.closingBalance = closingBalance
        self.availableBalance = availableBalance
        self.creditLimit = creditLimit
    }
}
