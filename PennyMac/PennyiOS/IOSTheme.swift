// IOSTheme — the iOS design language, translated from the penny_final_1 mockup:
// warm cream ground, white cards with soft gold hairlines, lime as the single
// brand accent, coral/peach/mint/plum/sky as category hues. Type mirrors the
// mockup's Fraunces/DM Sans/JetBrains Mono trio with native faces: serif
// display for headings and figures, SF for body, monospaced for data labels.
import SwiftUI

enum T {
    // ground + surfaces
    static let bg = Color(hex: 0xFDF6E9)
    static let bg2 = Color(hex: 0xF5ECD9)
    static let card = Color.white
    static let cardTint = Color(hex: 0xFFF4DD)
    static let line = Color(hex: 0xECD9B0)
    static let lineSoft = Color(hex: 0xF1E3C5)
    // ink
    static let ink = Color(hex: 0x1A1A1A)
    static let dim = Color(hex: 0x7A7368)
    static let dim2 = Color(hex: 0xAAA094)
    // brand + category hues
    static let lime = Color(hex: 0x84CC16)
    static let limeDeep = Color(hex: 0x5E9B04)
    static let limeSoft = Color(hex: 0xD4F08A)
    static let coral = Color(hex: 0xFF6B6B)
    static let coralSoft = Color(hex: 0xFFD8D8)
    static let peach = Color(hex: 0xFF9F56)
    static let peachSoft = Color(hex: 0xFFD9B8)
    static let mint = Color(hex: 0x34D399)
    static let mintSoft = Color(hex: 0xC6F0D8)
    static let plum = Color(hex: 0xA855F7)
    static let plumSoft = Color(hex: 0xE9D5FF)
    static let sky = Color(hex: 0x3B82F6)
    static let skySoft = Color(hex: 0xCFE0FF)

    /// Fraunces stand-in: the system serif at display weights.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// JetBrains Mono stand-in for tags/meta.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Category → emoji + tint, mirroring the mockup's category pills.
    static func categoryLook(_ category: String) -> (emoji: String, tint: Color) {
        switch category {
        case "Groceries": return ("🛒", limeSoft)
        case "Food & Dining", "Dining": return ("🍔", coralSoft)
        case "Transport": return ("🚇", plumSoft)
        case "Shopping": return ("🛍️", peachSoft)
        case "Subscriptions": return ("🎬", skySoft)
        case "Utilities", "Bills": return ("💡", skySoft)
        case "Entertainment": return ("🎟️", plumSoft)
        case "Health", "Healthcare": return ("💊", mintSoft)
        case "Income", "Salary": return ("💷", limeSoft)
        case "Transfers": return ("🔁", bg2)
        case "Payments": return ("💳", bg2)
        case "Fees & Charges": return ("🏦", peachSoft)
        case "Travel": return ("✈️", skySoft)
        case "Cash": return ("💵", limeSoft)
        default: return ("💸", bg2)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Shared card chrome: white surface, gold hairline, soft warm shadow.
struct CardStyle: ViewModifier {
    var tint: Color = T.card
    func body(content: Content) -> some View {
        content
            .background(tint, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(T.line, lineWidth: 1))
            .shadow(color: Color(hex: 0xA07828).opacity(0.07), radius: 8, y: 3)
    }
}

extension View {
    func pennyCard(tint: Color = T.card) -> some View { modifier(CardStyle(tint: tint)) }
}
