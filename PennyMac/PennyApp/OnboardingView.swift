import SwiftUI

/// The 7-step onboarding wizard — 1:1 port of the design template
/// (`Penny — Mac Final.html` / `clean_template.html`): a shared top bar with
/// progress dashes and the "running locally" pill, routing between the seven
/// screens. Steps 2–7 live in `OnboardingSteps.swift`.
struct OnboardingView: View {
    @EnvironmentObject var app: AppModel
    @State private var pulsing = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Group {
                switch app.onboardStep {
                case 1:  WelcomeStep()
                case 2:  NameStep()
                case 3:  HowItWorksStep()
                case 4:  AccountsStep()
                case 5:  UploadStep()
                case 6:  ProcessingStep()
                default: InsightsStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        .animation(.easeInOut(duration: 0.25), value: app.onboardStep)
        .onAppear { pulsing = true }
    }

    // MARK: - Top bar (.hdr)

    private var topBar: some View {
        HStack {
            HStack(spacing: 10) {
                PennyAvatar(size: 30)
                PennyWordmark(size: 21, design: .serif)
            }
            Spacer()
            localPill
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Theme.bg)
        .overlay(stepProgress)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    /// Six dashes: done = lime, current = wide ink, upcoming = line colour.
    /// The 7th screen (insights reveal) rides under step 6 — the header never counts it.
    private var stepProgress: some View {
        let shown = min(app.onboardStep, 6)
        return HStack(spacing: 7) {
            ForEach(1...6, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3)
                    .fill(i < shown ? Theme.limeD
                          : i == shown ? Theme.ink : Theme.line)
                    .frame(width: i == shown ? 30 : 18, height: 5)
            }
            Text("Step \(shown) of 6")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.dim)
                .padding(.leading, 6)
        }
        .animation(.easeInOut(duration: 0.3), value: app.onboardStep)
    }

    private var localPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.limeD)
                .frame(width: 5, height: 5)
                .opacity(pulsing ? 0.4 : 1)
                .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulsing)
            Text("running locally · \(DeviceInfo.chipLabel)")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.limeD)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.limeS, in: Capsule())
    }
}

// MARK: - S1 WELCOME (.s1)

struct WelcomeStep: View {
    @EnvironmentObject var app: AppModel
    @State private var floating = false
    @State private var waving = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bg, Color(hex: 0xfed7a8)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Blobs()
            HStack(spacing: 60) {
                mascot.frame(maxWidth: .infinity)
                copy.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 1080)
            .padding(.horizontal, 60)
            .padding(.vertical, 32)
        }
        .clipped()
        .onAppear {
            floating = true
            waving = true
        }
    }

    private var mascot: some View {
        ZStack(alignment: .bottomTrailing) {
            PennyAvatar(size: 180)
            Text("👋")
                .font(.system(size: 40))
                .rotationEffect(.degrees(waving ? 20 : -15), anchor: .bottomLeading)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: waving)
                .offset(x: 24, y: 4)
        }
        .offset(y: floating ? -8 : 0)
        .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: floating)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 0) {
            SpeechTag("hi 👋 i'm penny")
            headline
                .padding(.top, 18)
            Text("A tiny AI on your Mac. Drop in your statements and investment reports — I'll find where your money goes, banish zombie subs, and roast you when you deserve it.")
                .font(Theme.font(15))
                .foregroundStyle(Theme.ink2)
                .lineSpacing(5)
                .frame(maxWidth: 500, alignment: .leading)
                .padding(.top, 16)
            bullets
                .padding(.top, 14)
            ctas
                .padding(.top, 22)
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            headlineText("Your money,")
            HStack(spacing: 0) {
                headlineText("but make it ")
                headlineText("fun.")
                    .foregroundStyle(Theme.limeD)
                    .background(alignment: .bottom) {
                        // the lime highlighter swipe under "fun."
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.lime.opacity(0.45))
                            .frame(height: 14)
                            .offset(y: -8)
                    }
            }
        }
        .foregroundStyle(Theme.ink)
    }

    private func headlineText(_ s: String) -> Text {
        Text(s).font(Theme.serif(52)).kerning(-2)
    }

    private var bullets: some View {
        VStack(alignment: .leading, spacing: 9) {
            bullet("🔒", "Lives on your Mac.", " Files never leave. Ever.")
            bullet("📄", "You upload files.", " CSV, PDF, Excel — no passwords.")
            bullet("⚡", app.modelDisplayName, " on your Mac's chip. Proper reasoning.")
        }
    }

    private func bullet(_ emoji: String, _ lead: String, _ rest: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Text(emoji)
                .font(.system(size: 13))
                .frame(width: 26, height: 26)
                .hardCard(radius: 8)
            (Text(lead).fontWeight(.heavy).foregroundStyle(Theme.ink) + Text(rest))
                .font(Theme.font(13.5))
                .foregroundStyle(Theme.ink2)
                .padding(.top, 3)
        }
    }

    private var ctas: some View {
        HStack(spacing: 11) {
            Button {
                app.goToStep(2)
            } label: {
                Text("Let's set up →")
                    .font(Theme.font(15.5, .bold))
                    .foregroundStyle(Theme.ink)
            }
            .buttonStyle(LimeButtonStyle(large: true))

            // No accounts in the native app — a returning user just skips the
            // tour and lands on the model picker / dashboard.
            Button {
                app.finishOnboarding()
            } label: {
                Text("I have an account")
                    .font(Theme.font(14.5, .semibold))
                    .foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            SkipButton("skip → choose model") { app.skipToModelPicker() }
        }
    }
}

// MARK: - Shared onboarding pieces

/// The template's blurred `.blob` colour washes (S1 background).
struct Blobs: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.lime)
                .frame(width: 380, height: 380)
                .blur(radius: 80)
                .opacity(0.35)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .offset(x: 100, y: -100)
            Circle()
                .fill(Theme.coral)
                .frame(width: 360, height: 360)
                .blur(radius: 80)
                .opacity(0.3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .offset(x: -100, y: 120)
        }
        .allowsHitTesting(false)
    }
}

/// The tilted white handwriting tag standing on a hard shadow (`.tag`).
struct SpeechTag: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(Theme.caveat(19))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 17)
            .padding(.vertical, 7)
            .background(Capsule().fill(.white))
            .background(Capsule().fill(Theme.ink).offset(y: 4))
            .overlay(Capsule().stroke(Theme.ink, lineWidth: 2))
            .rotationEffect(.degrees(-2))
    }
}

/// `.btn.lime` — flat lime button on a hard offset shadow it presses into.
struct LimeButtonStyle: ButtonStyle {
    var large = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, large ? 28 : 24)
            .padding(.vertical, large ? 16 : 14)
            .background(RoundedRectangle(cornerRadius: 13).fill(Theme.lime))
            .background(
                RoundedRectangle(cornerRadius: 13)
                    .fill(Theme.limeD)
                    .offset(y: configuration.isPressed ? 2 : 4)
            )
            .offset(y: configuration.isPressed ? 2 : 0)
    }
}

/// `.skip` — the quiet "← back" text button.
struct SkipButton: View {
    let label: String
    let action: () -> Void
    init(_ label: String, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.font(12.5, .semibold))
                .foregroundStyle(Theme.dim)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Reads the CPU brand string so the header pill can say "running locally ·
/// M3 Mac" with this machine's real chip.
enum DeviceInfo {
    static let chipLabel: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple Silicon Mac" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let brand = String(cString: buf)   // e.g. "Apple M3 Pro"
        if let m = brand.range(of: #"M\d+"#, options: .regularExpression) {
            return "\(brand[m]) Mac"
        }
        if brand.localizedCaseInsensitiveContains("intel") { return "Intel Mac" }
        return "Apple Silicon Mac"
    }()
}

#Preview {
    OnboardingView().environmentObject(AppModel())
}
