import SwiftUI

/// The right-hand "Today" panel — SwiftUI port of `components/ContextPanel.jsx`.
/// Every figure is summed deterministically in Swift from the extracted
/// transactions (`AppModel.summary`); nothing here is guessed by the model.
struct ContextPanelView: View {
    @EnvironmentObject var app: AppModel

    private var s: Summary { app.summary }

    private func money(_ v: Double?) -> String {
        app.contextReady ? Money.format(v, currency: s.currency) : "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            statCard("total balance", money(s.balance), sub: "latest statement balance")
            statCard("total spent", money(app.contextReady ? s.spent : nil),
                     sub: "sum of debits", tone: .warn)
            statCard("net · income − spend", money(app.contextReady ? s.net : nil),
                     sub: "across loaded statements",
                     tone: (s.net < 0 && app.contextReady) ? .warn : .good)

            categoriesSection
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 260)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.paper)
        .overlay(Rectangle().fill(Theme.line).frame(width: 1), alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Today").font(Theme.font(15, .bold)).foregroundStyle(Theme.ink)
            HStack(spacing: 6) {
                if app.isAnalyzing { ProgressView().controlSize(.small) }
                Text(statusLine).font(Theme.font(11)).foregroundStyle(Theme.dim)
            }
        }
    }

    private var statusLine: String {
        if app.isAnalyzing { return "reading your transactions…" }
        if app.contextReady { return "\(s.count) transactions · on-device" }
        return "on-device · upload a statement to begin"
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
            Text(label).font(Theme.font(10, .semibold)).foregroundStyle(Theme.dim).textCase(.uppercase)
            Text(value).font(Theme.font(22, .heavy)).foregroundStyle(valueColor)
                .contentTransition(.numericText())
            Text(sub).font(Theme.font(10)).foregroundStyle(Theme.dim.opacity(0.85))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }

    private var categoryBars: some View {
        let total = s.categories.reduce(0) { $0 + abs($1.amount) }
        return VStack(alignment: .leading, spacing: 8) {
            Text("spending by category").font(Theme.font(11, .bold)).foregroundStyle(Theme.dim)
            ForEach(s.categories.prefix(6)) { cat in
                let meta = CategoryMeta.style(for: cat.name)
                let pct = total > 0 ? abs(cat.amount) / total : 0
                HStack(spacing: 8) {
                    Text(meta.icon).font(.system(size: 13))
                    Text(cat.name).font(Theme.font(11, .medium)).foregroundStyle(Theme.ink2)
                        .lineLimit(1).frame(width: 66, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.line.opacity(0.6))
                            Capsule().fill(meta.fill).frame(width: geo.size.width * pct)
                        }
                    }
                    .frame(height: 7)
                    Text(Money.format(abs(cat.amount), currency: s.currency))
                        .font(Theme.font(9.5, .semibold)).foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }

    private func infoCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.tint, in: RoundedRectangle(cornerRadius: 12))
    }
}
