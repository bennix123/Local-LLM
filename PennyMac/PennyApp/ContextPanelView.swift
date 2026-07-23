import SwiftUI

/// The right-hand "Today" panel — restyled to the template's `.cp`: serif
/// title, mono meta line, hard-shadow stat cards with handwriting labels, and
/// the category bar card. Every figure is summed deterministically in Swift
/// from the extracted transactions (`AppModel.summary`); nothing is guessed.
struct ContextPanelView: View {
    @EnvironmentObject var app: AppModel

    private var s: Summary { app.summary }

    private func money(_ v: Double?) -> String {
        app.contextReady ? Money.format(v, currency: s.currency) : "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18).padding(.top, 13).padding(.bottom, 11)
                .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    statCard("total balance", money(s.balance), sub: balanceSub)
                    statCard("spent · loaded statements", money(app.contextReady ? s.spent : nil),
                             sub: "sum of debits", tone: .warn)
                    statCard("net · income − spend", money(app.contextReady ? s.net : nil),
                             sub: "excl. card repayments",
                             tone: (s.net < 0 && app.contextReady) ? .warn : .good)
                    statCard("accounts", "\(app.docs.count)",
                             sub: app.docs.count == 1 ? "statement loaded" : "statements loaded")
                    categoriesSection
                }
                .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 18)
            }
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bg)
        .overlay(Rectangle().fill(Theme.line).frame(width: 1), alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Today").font(Theme.serif(17, .heavy)).foregroundStyle(Theme.ink)
            HStack(spacing: 6) {
                if app.isAnalyzing { ProgressView().controlSize(.small) }
                Text(statusLine).font(Theme.mono(9, .semibold)).foregroundStyle(Theme.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusLine: String {
        if app.isAnalyzing { return "reading your transactions…" }
        if app.contextReady { return "\(s.count) transactions · on-device" }
        return "on-device · upload a statement to begin"
    }

    /// "latest statement balance" for one account; when several are combined,
    /// say what the number actually is (cards subtract — they're money owed).
    private var balanceSub: String {
        let chosen = app.docs.filter {
            app.selectedDocNames.isEmpty || app.selectedDocNames.contains($0.name)
        }
        let withBal = chosen.filter { $0.latestBalance != nil }
        if withBal.count <= 1 { return "latest statement balance" }
        return withBal.contains(where: \.isCard)
            ? "across accounts · cards deducted"
            : "across \(withBal.count) accounts"
    }

    @ViewBuilder private var categoriesSection: some View {
        if !s.categories.isEmpty {
            categoryBars
        } else if app.isAnalyzing {
            infoCard {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Extracting transactions on-device…")
                        .font(Theme.font(11)).foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if !app.docs.isEmpty {
            infoCard {
                Text("No transactions detected in this statement.")
                    .font(Theme.font(11)).foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            infoCard {
                Text("Upload a statement to see categories.")
                    .font(Theme.font(11)).foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private enum Tone { case neutral, warn, good }

    private func statCard(_ label: String, _ value: String, sub: String, tone: Tone = .neutral) -> some View {
        let valueColor: Color = {
            switch tone {
            case .neutral: return Theme.ink
            case .warn:    return Theme.coral
            case .good:    return Theme.limeD
            }
        }()
        return VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Theme.caveat(12)).foregroundStyle(Theme.dim)
            Text(value).font(Theme.serif(22, .heavy)).kerning(-0.4).foregroundStyle(valueColor)
                .contentTransition(.numericText())
            Text(sub).font(Theme.mono(9, .semibold)).foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 13).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hardCard(radius: 12, border: 2, shadow: 3)
    }

    private var categoryBars: some View {
        let total = s.categories.reduce(0) { $0 + abs($1.amount) }
        return VStack(alignment: .leading, spacing: 5) {
            Text("spend by category")
                .font(Theme.serif(13.5, .heavy)).foregroundStyle(Theme.ink)
                .padding(.bottom, 4)
            ForEach(s.categories.prefix(6)) { cat in
                let meta = CategoryMeta.style(for: cat.name)
                let pct = total > 0 ? abs(cat.amount) / total : 0
                HStack(spacing: 7) {
                    Text(meta.icon).font(.system(size: 13)).frame(width: 18)
                    Text(cat.name).font(Theme.font(10.5, .semibold)).foregroundStyle(Theme.ink2)
                        .lineLimit(1).frame(width: 56, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Theme.bg2)
                            RoundedRectangle(cornerRadius: 3).fill(meta.fill)
                                .frame(width: geo.size.width * pct)
                        }
                    }
                    .frame(height: 12)
                    Text(Money.format(abs(cat.amount), currency: s.currency))
                        .font(Theme.mono(10)).foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .frame(minWidth: 40, alignment: .trailing)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hardCard(radius: 12, border: 2, shadow: 3)
    }

    private func infoCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.tint, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            )
    }
}
