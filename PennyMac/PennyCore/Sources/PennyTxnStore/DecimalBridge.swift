import Foundation
import PennyModel

/// Bridges the legacy parser's `Double` money values to exact `Decimal` / `Money`
/// for the translation layer (Task 0.4). Shared by every source adapter.
///
/// `TxnRow` stores amounts as `Double`; the canonical model uses `Decimal`. A
/// direct `Decimal(someDouble)` is imprecise, so we bridge through the Double's
/// **shortest round-trippable decimal string** (`String(d)`), which recovers the
/// intended value for realistic money amounts (≤ a few decimals). A total
/// function — it never throws.
public enum DecimalBridge {

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// A legacy `Double` as an exact `Decimal`, via its shortest round-trippable
    /// string. Non-finite input maps to `0`.
    public static func decimal(_ d: Double) -> Decimal {
        guard d.isFinite else { return 0 }
        return Decimal(string: String(d), locale: posix) ?? Decimal(d)
    }

    /// Signed `Money` from a legacy debit/credit pair: `credit − debit`
    /// (negative = money out, per the model's D2 convention).
    public static func signedMoney(debit: Double, credit: Double) -> Money {
        Money(decimal: decimal(credit) - decimal(debit))
    }

    /// An optional legacy balance to `Money?`, preserving `nil`.
    public static func money(_ d: Double?) -> Money? {
        d.map { Money(decimal: decimal($0)) }
    }
}
