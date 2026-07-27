/// A financial account — the thing statements and transactions belong to
/// (architecture layer L1). Immutable value type. Replaces the scattered
/// `bank` / `detectedIssuer` / `displayName` / `isCard` fields on the old
/// `LoadedDoc`.
public struct Account: Identifiable, Equatable, Codable, Sendable {

    /// The kind of account. Replaces the old loose `isCard: Bool` and drives
    /// owed-vs-held balance semantics. Consumed by: Phase 1 balance queries,
    /// Phase 4 KPIs.
    public enum Kind: String, Equatable, Codable, Sendable, CaseIterable {
        case current, credit, savings, unknown
    }

    /// Stable identity; the target of `Transaction.accountID` / `Statement.accountID`.
    /// Derivation is the parser adapter's job (Task 0.4/0.5), keyed on account
    /// metadata, never a filename. Consumed by: 0.4, Phase 1 (`Filter.account`).
    public let id: AccountID

    /// The issuing institution's name, e.g. "Monzo". Consumed by: display,
    /// Phase 4 (per-institution grouping).
    public let institution: String

    /// Current / credit / savings / unknown. Consumed by: Phase 1 (owed-vs-held
    /// balance), Phase 2 (card-specific handling).
    public let kind: Kind

    /// Account number where the statement states it. Consumed by: 0.4/0.5 stable
    /// identity, display. Optional — many statements redact it.
    public let number: String?

    /// UK sort code where stated. Consumed by: 0.4/0.5 identity, Phase 2
    /// internal-transfer matching. Optional.
    public let sortCode: String?

    /// Account holder name where stated. Consumed by: Phase 2 internal-transfer
    /// detection (a transfer is between accounts of the same holder). Optional.
    public let holder: String?

    /// The account's currency; one per account, never mixed in a sum. Consumed
    /// by: Phase 1 per-currency grouping, Phase 4 KPIs.
    public let currency: Currency

    public init(id: AccountID, institution: String, kind: Kind,
                number: String? = nil, sortCode: String? = nil, holder: String? = nil,
                currency: Currency) {
        self.id = id
        self.institution = institution
        self.kind = kind
        self.number = number
        self.sortCode = sortCode
        self.holder = holder
        self.currency = currency
    }
}
