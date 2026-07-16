import SwiftUI

/// The little coin mascot — SwiftUI port of `components/PennyAvatar.jsx`.
/// A lime coin with two eyes, blush cheeks and a smile.
struct PennyAvatar: View {
    enum Mood { case happy, thinking }
    var size: CGFloat = 28
    var mood: Mood = .happy

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Theme.lime, Theme.limeD],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .overlay(Circle().stroke(Theme.ink.opacity(0.85), lineWidth: max(1.5, size * 0.06)))
                .shadow(color: Theme.limeD.opacity(0.35), radius: size * 0.12, y: size * 0.06)

            // eyes
            HStack(spacing: size * 0.22) {
                eye
                eye
            }
            .offset(y: -size * 0.06)

            // cheeks
            HStack(spacing: size * 0.5) {
                cheek
                cheek
            }
            .offset(y: size * 0.12)

            // mouth
            Capsule()
                .fill(Theme.ink)
                .frame(width: size * (mood == .happy ? 0.3 : 0.14),
                       height: size * 0.09)
                .offset(y: size * 0.2)
        }
        .frame(width: size, height: size)
    }

    private var eye: some View {
        Circle().fill(Theme.ink).frame(width: size * 0.12, height: size * 0.12)
    }
    private var cheek: some View {
        Circle().fill(Theme.coral.opacity(0.55)).frame(width: size * 0.14, height: size * 0.14)
    }
}

/// The "penny." wordmark with the lime accent dot used across the app.
struct PennyWordmark: View {
    var size: CGFloat = 22
    var body: some View {
        HStack(spacing: 0) {
            Text("penny").font(Theme.font(size, .heavy)).foregroundStyle(Theme.ink)
            Text(".").font(Theme.font(size, .heavy)).foregroundStyle(Theme.limeD)
        }
    }
}
