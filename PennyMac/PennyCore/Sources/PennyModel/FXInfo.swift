import Foundation

/// Foreign-exchange detail attached to a transaction (architecture layer L1).
/// Immutable value type. **Parsed at ingestion** from the statement's FX block
/// (Amendment 01, Decision 3) — Phase 2's ForeignDetector only *flags* `.foreign`
/// and reads this; it never reconstructs it. Present only on foreign transactions
/// (`Transaction.fx`).
public struct FXInfo: Equatable, Codable, Sendable {

    /// The amount in the original (foreign) currency. Consumed by: Phase 4 foreign
    /// spend, display "£X (originally $Y)".
    public let originalAmount: Money

    /// The original (foreign) currency — differs from the account currency, which
    /// is what makes the transaction foreign. Consumed by: Phase 2.4, Phase 4.
    public let originalCurrency: Currency

    /// The FX rate as printed on the statement, when stated. Informational and
    /// treated as a parsed fact, not a second source of truth for the amount
    /// (tech-debt D6). Consumed by: display. Optional.
    public let rate: Decimal?

    /// An itemized FX fee, when the statement breaks it out. Consumed by: Phase 4
    /// foreign-fee KPI. Optional.
    public let fee: Money?

    /// The country token read from the description, when present. Consumed by:
    /// Phase 1/4 foreign-by-country listing. Optional.
    public let country: String?

    public init(originalAmount: Money, originalCurrency: Currency,
                rate: Decimal? = nil, fee: Money? = nil, country: String? = nil) {
        self.originalAmount = originalAmount
        self.originalCurrency = originalCurrency
        self.rate = rate
        self.fee = fee
        self.country = country
    }
}
