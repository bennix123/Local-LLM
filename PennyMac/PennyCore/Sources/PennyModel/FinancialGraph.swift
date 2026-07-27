/// The aggregate root of the canonical model (architecture layer L1) — the whole
/// financial picture across every imported account. Immutable value type; the
/// object the query engine reads and the enrichment pipeline reconstructs.
///
/// Flat ID-linked collections (rather than nested trees) keep it Codable-simple
/// and let each higher layer build whatever index it needs. Referential
/// integrity — every child's `accountID` / `statementID` / `merchantID` /
/// `categoryID` resolves to an element here — is guaranteed by construction in the
/// parser adapter (0.4), not by the type system.
///
/// A freshly-parsed graph has empty `merchants` / `categories`; the Phase 2
/// pipeline populates them. (`recurring: [RecurringPayment]` is added in Task 2.6.)
public struct FinancialGraph: Equatable, Codable, Sendable {

    /// Every account. Consumed by: Phase 1 account queries, Phase 2 internal-transfer.
    public let accounts: [Account]

    /// Every statement. Consumed by: Phase 1 statement/period queries, Phase 4.
    public let statements: [Statement]

    /// Every ledger line — the working set for the query engine. Consumed by:
    /// everything above L1.
    public let transactions: [Transaction]

    /// The normalized merchant projection. Empty until Phase 2.2. Consumed by:
    /// Phase 1 merchant resolution, Phase 4 profiles.
    public let merchants: [Merchant]

    /// The category taxonomy. Empty until Phase 2.3. Consumed by: Phase 1 category
    /// resolution.
    public let categories: [Category]

    /// The empty graph — the starting point before any import. Consumed by: 0.6, tests.
    public static let empty = FinancialGraph(accounts: [], statements: [],
                                             transactions: [], merchants: [], categories: [])

    public init(accounts: [Account], statements: [Statement], transactions: [Transaction],
                merchants: [Merchant] = [], categories: [Category] = []) {
        self.accounts = accounts
        self.statements = statements
        self.transactions = transactions
        self.merchants = merchants
        self.categories = categories
    }
}
