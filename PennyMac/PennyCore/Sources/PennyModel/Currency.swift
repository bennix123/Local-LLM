/// An ISO-4217 currency code (architecture layer L1).
///
/// A typed wrapper — never a bare `String` — so a currency can't be confused with
/// any other string value and so it has a home for future symbol/formatting
/// metadata. `Money` intentionally carries no `Currency`; currency lives on the
/// entities (`Account` / `Statement` / `Transaction`) and drives per-currency
/// grouping in the query engine.
public struct Currency: Hashable, Codable, Sendable {

    /// The ISO-4217 alphabetic code, conventionally uppercase (e.g. `"GBP"`, `"USD"`).
    public let code: String

    public init(_ code: String) { self.code = code }

    // Convenience constants for the currencies Penny handles today. Pure data — no
    // logic; more can be added without touching call sites.
    public static let gbp = Currency("GBP")
    public static let usd = Currency("USD")
    public static let eur = Currency("EUR")
    public static let inr = Currency("INR")
}
