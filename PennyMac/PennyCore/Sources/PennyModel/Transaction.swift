/// One ledger line (architecture layer L1). Immutable value type. The defining
/// improvement over the old `TxnRow`: it **carries its account and statement**,
/// so "which statement…" is answerable from the model rather than a side channel.
///
/// Amendment 01 sets a strict boundary: this type holds only **parsed facts**
/// (identity, dates, amount, currency, description, and the FX block the statement
/// prints). All **derived** information — merchant, clean description, category,
/// tags, links, confidence — lives in `enrichment`, filled by the Phase 2 pipeline.
public struct Transaction: Identifiable, Equatable, Codable, Sendable {

    // MARK: Identity & provenance (parsed)

    /// Stable identity; the citation target and dedupe key. Derivation deferred to 0.4.
    public let id: TransactionID

    /// The owning account — the gap that forced the old per-document handlers.
    /// Consumed by: Phase 1 (`Filter.account`), Phase 2 internal-transfer.
    public let accountID: AccountID

    /// The owning statement. Consumed by: Phase 1 statement-scoped queries, citations.
    public let statementID: StatementID

    // MARK: Parsed facts

    /// Value date, timezone-free (Amendment 01). Consumed by: Phase 1
    /// (`Filter.dateRange`), Phase 4 time series.
    public let date: CalendarDate

    /// Posting date where distinct from the value date (cards). Consumed by: Phase 1.
    /// Optional.
    public let processDate: CalendarDate?

    /// The verbatim statement text — never lost; the provenance for every
    /// enrichment. Consumed by: Phase 2 detectors, `Filter.text`.
    public let rawDescription: String

    /// The signed amount (negative = money out). Consumed by: every aggregation.
    public let amount: Money

    /// The running balance where the statement prints one. Stored exactly as
    /// printed; `Account.Kind` determines asset-vs-liability meaning (Amendment 01,
    /// Decision 5). Consumed by: Phase 1 balance-as-of queries. Optional — Barclays
    /// omits per-row balances.
    public let balance: Money?

    /// The booked currency. Consumed by: Phase 1 per-currency grouping.
    public let currency: Currency

    /// Foreign-exchange detail as **parsed** from the statement's FX block
    /// (Amendment 01, Decision 3). Phase 2 only *flags* `.foreign`; it never
    /// reconstructs this. Consumed by: Phase 4 foreign KPIs. Optional.
    public let fx: FXInfo?

    /// The user's own account this row moved through, when the statement
    /// PRINTS it per record — aggregator exports (Paytm/GPay) span several
    /// underlying bank accounts inside one statement ("Union Bank Of India
    /// -49"). A parsed fact, not enrichment. nil when unstated. (A future
    /// phase may model these as first-class `Account` entities; this keeps
    /// the printed fact until then.) Optional-decodes for pre-existing stores.
    public let subAccount: String?

    // MARK: Enriched (empty at parse time; filled in Phase 2)

    /// The detector output — merchant, clean description, category, tags, links,
    /// confidence. Consumed by: Phase 1 (`Filter.merchant`/`.category`/`.tag`),
    /// Phase 4. Defaults to `.empty`.
    public let enrichment: Enrichment

    // MARK: Derived (per approved architecture §2 — not stored)

    /// The flow direction, derived from the sign of `amount`. Consumed by: Phase 1
    /// (`Filter.direction`). The model expressing a fundamental fact, not stored
    /// state — the single computed member on the entity.
    public var direction: Direction { amount.isDebit ? .debit : .credit }

    public init(id: TransactionID, accountID: AccountID, statementID: StatementID,
                date: CalendarDate, processDate: CalendarDate? = nil,
                rawDescription: String, amount: Money, balance: Money? = nil, currency: Currency,
                fx: FXInfo? = nil, subAccount: String? = nil, enrichment: Enrichment = .empty) {
        self.id = id
        self.accountID = accountID
        self.statementID = statementID
        self.date = date
        self.processDate = processDate
        self.rawDescription = rawDescription
        self.amount = amount
        self.balance = balance
        self.currency = currency
        self.fx = fx
        self.subAccount = subAccount
        self.enrichment = enrichment
    }
}
