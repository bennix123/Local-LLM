// Typed identifiers for the canonical model (architecture layer L1).
//
// Each is a wrapper over `String` rather than a bare string so identifiers of
// different kinds cannot be interchanged at compile time — you cannot pass a
// `MerchantID` where an `AccountID` is expected. Relationships and citations are
// therefore referential, not positional. `Hashable` because IDs are used as
// dictionary keys and in citation sets (e.g. `[TransactionID]`).
//
// Five explicit structs (rather than a generic phantom type) are used for maximal
// clarity and to match the migration contract exactly.

/// Stable identity for an `Account`.
public struct AccountID: Hashable, Codable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// Stable identity for a `Statement`.
public struct StatementID: Hashable, Codable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// Stable identity for a `Transaction`. Also the citation target and dedupe key.
public struct TransactionID: Hashable, Codable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// Stable identity for a normalized `Merchant`.
public struct MerchantID: Hashable, Codable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// Stable identity for a `Category`.
public struct CategoryID: Hashable, Codable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// Stable identity for a detected `RecurringPayment` series (the series entity
/// itself lands in Task 2.6). Referenced by `Enrichment.recurringID`.
public struct RecurringID: Hashable, Codable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}
