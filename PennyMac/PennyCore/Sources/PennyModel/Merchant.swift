/// A normalized merchant (architecture layer L1). Immutable value type; produced
/// by the Phase 2 MerchantNormalizer, which folds raw variants ("AMZN",
/// "AMAZON.CO.UK") onto one canonical entity — the fix for unreliable
/// "most-frequent merchant".
///
/// The alias table (raw-variant → merchant) is data, held in the seed index
/// (`merchants.json`), **not** on this entity: the in-graph `Merchant` is a
/// read-only projection, so it can't drift per-import (resolves tech-debt D4).
public struct Merchant: Identifiable, Equatable, Codable, Sendable {

    /// Stable identity; the target of `Transaction.merchantID`. Consumed by:
    /// Phase 1 (`Filter.merchant`), Phase 4 merchant profiles.
    public let id: MerchantID

    /// The display + grouping name, e.g. "Amazon". Consumed by: Phase 1 grouping,
    /// Phase 4, display.
    public let canonicalName: String

    /// The merchant's usual category, a shortcut for the categorizer. Consumed by:
    /// Phase 2.3 (Categorizer). Optional.
    public let defaultCategoryID: CategoryID?

    public init(id: MerchantID, canonicalName: String, defaultCategoryID: CategoryID? = nil) {
        self.id = id
        self.canonicalName = canonicalName
        self.defaultCategoryID = defaultCategoryID
    }
}
