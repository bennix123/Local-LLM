import SwiftUI

/// Compact welcome screen — a distilled version of the React `Landing` page.
/// (The web Landing is a long marketing site; the native app just needs a warm
/// hero that leads into the mandatory model-picker step.)
struct OnboardingView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 26) {
                Spacer()

                PennyAvatar(size: 96)

                VStack(spacing: 10) {
                    HStack(spacing: 0) {
                        Text("meet ").font(Theme.font(40, .black)).foregroundStyle(Theme.ink)
                        PennyWordmark(size: 40)
                    }
                    Text("Your offline money confidant. Ask about your bank\nstatements in plain English — every answer runs on\nthis Mac, nothing ever leaves your device.")
                        .multilineTextAlignment(.center)
                        .font(Theme.font(15))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 14) {
                    feature("🔒", "100% offline")
                    feature("⚡", "MLX on Metal")
                    feature("🧾", "Grounded in your statement")
                }
                .padding(.top, 4)

                Button {
                    app.stage = .modelPicker
                } label: {
                    Text("Let's set up  →")
                        .font(Theme.font(16, .bold))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 30).padding(.vertical, 14)
                        .background(Theme.lime, in: Capsule())
                        .overlay(Capsule().stroke(Theme.ink, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .padding(.top, 6)

                Text("Sandboxed · no llama.cpp · no server · no cloud")
                    .font(Theme.font(11))
                    .foregroundStyle(Theme.dim.opacity(0.8))

                Spacer()
            }
            .padding(40)
        }
    }

    private func feature(_ emoji: String, _ label: String) -> some View {
        HStack(spacing: 7) {
            Text(emoji)
            Text(label).font(Theme.font(12, .semibold)).foregroundStyle(Theme.ink2)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
    }
}
