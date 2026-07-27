import Foundation

/// A signed monetary amount backed by `Decimal` (architecture layer L1).
///
/// `Money` is a **mathematical value object only**. By deliberate design it:
///
/// - performs **no currency conversion** — it carries no currency at all; currency
///   lives on `Account` / `Statement` / `Transaction`, and the query engine groups
///   per currency so amounts in different currencies are never blended;
/// - performs **no formatting** — no symbols, no thousands separators, no fixed
///   decimal places (presentation is a UI concern);
/// - performs **no localization** — its `Codable` form is a fixed, POSIX-locale
///   string, independent of the user's region;
/// - applies **no rounding policy** — it preserves the underlying `Decimal`
///   exactly, so `0.1 + 0.2 == 0.3` holds and no precision is silently dropped.
///
/// Sign convention (architecture decision D2): a single signed amount replaces the
/// former debit/credit pair. **Negative = money out (debit); positive = money in.**
public struct Money: Hashable, Comparable, Codable, Sendable, AdditiveArithmetic {

    /// The signed amount. Negative = money out; positive = money in. Always an
    /// exact `Decimal` — never routed through `Double`.
    public let amount: Decimal

    /// Primary initializer.
    public init(decimal: Decimal) { self.amount = decimal }

    /// Convenience, unlabeled initializer (equivalent to `init(decimal:)`).
    public init(_ amount: Decimal) { self.amount = amount }

    /// The additive identity — a zero amount. Enables `reduce(.zero, +)`.
    public static let zero = Money(decimal: 0)

    /// True when the amount is negative (money out).
    public var isDebit: Bool { amount < 0 }

    /// The absolute value of the amount (unsigned magnitude). Use this for
    /// "largest expense" comparisons, since `Comparable` orders by *signed* value.
    public var magnitude: Decimal { amount.magnitude }

    // MARK: - Comparable
    // Orders by SIGNED value: a large debit (−1000) sorts BELOW a small credit (+5).
    // Magnitude comparisons must use `magnitude`.
    public static func < (lhs: Money, rhs: Money) -> Bool { lhs.amount < rhs.amount }

    // MARK: - AdditiveArithmetic
    public static func + (lhs: Money, rhs: Money) -> Money { Money(decimal: lhs.amount + rhs.amount) }
    public static func - (lhs: Money, rhs: Money) -> Money { Money(decimal: lhs.amount - rhs.amount) }

    /// Unary negation — flips money-in to money-out and vice versa.
    public static prefix func - (operand: Money) -> Money { Money(decimal: -operand.amount) }

    // MARK: - Codable
    // Encoded as a locale-independent String (`Decimal.description`) and parsed with
    // a fixed POSIX locale. This guarantees a lossless round-trip across ANY encoder;
    // encoding `Decimal` as a JSON number can otherwise route through `Double` and
    // lose precision.
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let decimal = Decimal(string: string, locale: Money.posixLocale) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Money: could not parse a Decimal from \"\(string)\"")
        }
        self.amount = decimal
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        // `Decimal.description` is locale-independent (always uses "." as the separator).
        try container.encode(amount.description)
    }
}

/// The flow direction of a transaction.
///
/// Derived from `Money.isDebit` on a `Transaction`, but also a first-class value in
/// the query engine (a `Filter.direction`), so it belongs in the shared model.
public enum Direction: String, Codable, Sendable, CaseIterable {
    case debit
    case credit
}
