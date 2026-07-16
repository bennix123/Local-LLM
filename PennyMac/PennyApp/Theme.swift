import SwiftUI

/// Design tokens + formatting, ported 1:1 from the FinQuery React frontend
/// (`finquery/frontend/src/pages/Dashboard.css` :root, and `src/format.js`).
/// Keeping the same palette + money/category logic means the SwiftUI app reads
/// as the same product as the web reference.
enum Theme {
    // --- palette (Dashboard.css :root) ---------------------------------------
    static let bg      = Color(hex: 0xfff8e8)  // warm cream page
    static let bg2     = Color(hex: 0xfbeec5)
    static let paper   = Color(hex: 0xfffaee)
    static let card    = Color(hex: 0xffffff)
    static let tint    = Color(hex: 0xfff4d6)
    static let line    = Color(hex: 0xecd9b0)
    static let ink     = Color(hex: 0x1a1a1a)
    static let ink2    = Color(hex: 0x2a2a2a)
    static let dim     = Color(hex: 0x7a7368)
    static let lime    = Color(hex: 0x84cc16)
    static let limeD   = Color(hex: 0x5e9b04)
    static let limeS   = Color(hex: 0xd4f08a)
    static let coral   = Color(hex: 0xff5e62)
    static let coralS  = Color(hex: 0xffd8d8)
    static let peach   = Color(hex: 0xff9f56)
    static let peachS  = Color(hex: 0xffd9b8)
    static let mint    = Color(hex: 0x34d399)
    static let plum    = Color(hex: 0xa855f7)
    static let sky     = Color(hex: 0x3b82f6)
    static let sun     = Color(hex: 0xfbbf24)

    // Poppins → SF Rounded is the closest system match for the playful brand feel.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue:  Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Currency-aware money formatting (port of format.js :: formatMoney)

enum Money {
    private static let symbol: [String: String] = [
        "INR": "₹", "GBP": "£", "USD": "$", "EUR": "€",
        "OMR": "OMR ", "KWD": "KWD ", "BHD": "BHD ", "JOD": "JOD ", "IQD": "IQD ", "": "",
    ]
    private static let threeDecimals: Set<String> = ["OMR", "KWD", "BHD", "JOD", "IQD"]

    static func currencySymbol(_ cur: String) -> String {
        let c = cur.uppercased()
        if let s = symbol[c] { return s }
        return c.isEmpty ? "" : c + " "
    }

    /// Indian lakh/crore grouping: 12,34,567 (mirrors _group_indian).
    private static func groupIndian(_ intPart: String) -> String {
        guard intPart.count > 3 else { return intPart }
        let tail = String(intPart.suffix(3))
        var head = Substring(intPart.prefix(intPart.count - 3))
        var groups: [String] = []
        while head.count > 2 {
            groups.insert(String(head.suffix(2)), at: 0)
            head = head.prefix(head.count - 2)
        }
        if !head.isEmpty { groups.insert(String(head), at: 0) }
        return groups.joined(separator: ",") + "," + tail
    }

    private static func groupUS(_ intPart: String) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.groupingSeparator = ","
        return fmt.string(from: NSNumber(value: Int(intPart) ?? 0)) ?? intPart
    }

    /// Format `n` in a specific currency. nil/NaN → em dash (never "£NaN").
    static func format(_ n: Double?, currency cur: String) -> String {
        guard let n, !n.isNaN else { return "—" }
        let currency = cur.uppercased()
        let neg = n < 0
        let dec = threeDecimals.contains(currency) ? 3 : 2
        let parts = String(format: "%.\(dec)f", abs(n)).split(separator: ".")
        let intPart = String(parts.first ?? "0")
        let decPart = parts.count > 1 ? String(parts[1]) : String(repeating: "0", count: dec)
        let grouped = currency == "INR" ? groupIndian(intPart) : groupUS(intPart)
        return (neg ? "-" : "") + currencySymbol(currency) + grouped + "." + decPart
    }
}

// MARK: - Category icon + bar colour (port of format.js :: categoryMeta)

struct CategoryStyle { let icon: String; let fill: Color }

enum CategoryMeta {
    private static let table: [(keys: [String], icon: String, fill: Color)] = [
        (["food", "dining", "restaurant"], "🍔", Theme.coral),
        (["grocer"],                       "🛒", Theme.lime),
        (["bill", "utilit"],               "⚡", Theme.sky),
        (["shop"],                         "🛍", Theme.peach),
        (["transport", "travel", "fuel"],  "🚇", Theme.plum),
        (["subscription", "entertain"],    "🎵", Theme.lime),
        (["health", "medical", "pharma"],  "💊", Theme.coral),
        (["invest", "insurance"],          "📈", Theme.sky),
        (["income", "salary"],             "💰", Theme.lime),
        (["transfer"],                     "🔄", Theme.plum),
        (["cash", "atm"],                  "💵", Theme.lime),
        (["rent", "housing"],              "🏠", Theme.peach),
    ]

    static func style(for name: String) -> CategoryStyle {
        let low = name.lowercased()
        for row in table where row.keys.contains(where: { low.contains($0) }) {
            return CategoryStyle(icon: row.icon, fill: row.fill)
        }
        return CategoryStyle(icon: "💳", fill: Theme.peach)  // fallback
    }
}
