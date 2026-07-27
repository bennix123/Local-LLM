/// A spending category (architecture layer L1). Immutable value type. Sourced
/// from `categories.json`, which is a **flat** taxonomy (15 names, no hierarchy),
/// so this entity deliberately has no `parentID` (decision D5 — the model reflects
/// the actual data, not anticipated features) and no `icon` (there is no icon data
/// and no concrete consumer yet).
public struct Category: Identifiable, Equatable, Codable, Sendable {

    /// Stable identity; the target of `Enrichment.categoryID` and
    /// `Merchant.defaultCategoryID`. Consumed by: Phase 1 (`Filter.category`).
    public let id: CategoryID

    /// The display + grouping name, e.g. "Groceries". Consumed by: Phase 1
    /// grouping, Phase 4, display.
    public let name: String

    public init(id: CategoryID, name: String) {
        self.id = id
        self.name = name
    }
}
