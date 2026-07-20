import SwiftUI

/// The little pea mascot — SwiftUI port of the design template's `.p` coin
/// (`finquery/frontend/clean_template.html`): a flat lime circle with glinted
/// eyes, blush cheeks and an open coral smile. No hard outline — just a soft
/// lime glow, like the template's inset/drop shadow pair.
struct PennyAvatar: View {
    enum Mood { case happy, thinking }
    var size: CGFloat = 28
    var mood: Mood = .happy

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Theme.lime, Color(hex: 0x74b312)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .shadow(color: Theme.limeD.opacity(0.35), radius: size * 0.12, y: size * 0.06)

            // eyes
            HStack(spacing: size * 0.18) {
                eye
                eye
            }
            .offset(y: -size * 0.06)

            // cheeks
            HStack(spacing: size * 0.42) {
                cheek
                cheek
            }
            .offset(y: size * 0.10)

            mouth
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var mouth: some View {
        if mood == .happy {
            // Open smile: rounded-bottom mouth filled coral, like the template's
            // border-radius 0 0 30px 30px `.m`.
            let shape = UnevenRoundedRectangle(
                topLeadingRadius: size * 0.03,
                bottomLeadingRadius: size * 0.12,
                bottomTrailingRadius: size * 0.12,
                topTrailingRadius: size * 0.03
            )
            shape
                .fill(Theme.coral)
                .frame(width: size * 0.24, height: size * 0.14)
                .overlay(shape.stroke(Theme.ink.opacity(0.9), lineWidth: max(1.2, size * 0.035)))
                .offset(y: size * 0.17)
        } else {
            Capsule()
                .fill(Theme.ink)
                .frame(width: size * 0.14, height: size * 0.07)
                .offset(y: size * 0.18)
        }
    }

    private var eye: some View {
        Circle()
            .fill(Theme.ink)
            .frame(width: size * 0.14, height: size * 0.14)
            .overlay(alignment: .topLeading) {
                // white glint
                Circle()
                    .fill(.white)
                    .frame(width: size * 0.05, height: size * 0.05)
                    .offset(x: size * 0.03, y: size * 0.02)
            }
    }

    private var cheek: some View {
        Ellipse()
            .fill(Theme.coral.opacity(0.55))
            .frame(width: size * 0.12, height: size * 0.08)
    }
}

/// The "penny." wordmark with the lime accent dot used across the app.
/// The onboarding header renders it in serif (the template's Fraunces brand
/// face); everywhere else keeps the rounded app face.
struct PennyWordmark: View {
    var size: CGFloat = 22
    var design: Font.Design = .rounded
    var body: some View {
        HStack(spacing: 0) {
            Text("penny").font(.system(size: size, weight: .heavy, design: design)).foregroundStyle(Theme.ink)
            Text(".").font(.system(size: size, weight: .heavy, design: design)).foregroundStyle(Theme.limeD)
        }
    }
}
