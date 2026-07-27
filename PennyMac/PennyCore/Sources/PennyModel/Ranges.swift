/// A comparable range with optional, individually-inclusive bounds (architecture
/// layer L1).
///
/// This is the value behind amount and date filters — "over £500" (lower bound
/// only), "under £20" (upper bound only), "between £20 and £100" (both). It is a
/// pure predicate type: it holds no domain knowledge and does no I/O. `contains`
/// is its fundamental operation, analogous to `Range.contains`.
///
/// Generic over `Bound: Comparable`, so it serves `Decimal` amounts, `Date`s, or
/// any comparable value. Conformances to `Codable` / `Equatable` / `Hashable` /
/// `Sendable` are conditional on `Bound`.
public struct ComparableRange<Bound: Comparable> {

    /// Lower bound; `nil` means unbounded below.
    public let lowerBound: Bound?
    /// Upper bound; `nil` means unbounded above.
    public let upperBound: Bound?
    /// Whether `lowerBound` itself is included.
    public let lowerInclusive: Bool
    /// Whether `upperBound` itself is included.
    public let upperInclusive: Bool

    public init(lowerBound: Bound? = nil,
                upperBound: Bound? = nil,
                lowerInclusive: Bool = true,
                upperInclusive: Bool = true) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.lowerInclusive = lowerInclusive
        self.upperInclusive = upperInclusive
    }

    /// Whether `value` falls within the range, honoring each bound's inclusivity.
    /// An unbounded side never excludes.
    public func contains(_ value: Bound) -> Bool {
        if let lower = lowerBound {
            if lowerInclusive { if value < lower { return false } }
            else { if value <= lower { return false } }
        }
        if let upper = upperBound {
            if upperInclusive { if value > upper { return false } }
            else { if value >= upper { return false } }
        }
        return true
    }
}

extension ComparableRange: Sendable where Bound: Sendable {}
extension ComparableRange: Equatable where Bound: Equatable {}
extension ComparableRange: Hashable where Bound: Hashable {}
extension ComparableRange: Codable where Bound: Codable {}
