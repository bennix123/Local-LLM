import SwiftUI

/// The right-hand "Today" panel — restyled to the template's `.cp`: serif
/// title, mono meta line, hard-shadow stat cards with handwriting labels, and
/// the category bar card. Every figure is summed deterministically in Swift
/// from the extracted transactions (`AppModel.summary`); nothing is guessed.
struct ContextPanelView: View {
    @EnvironmentObject var app: AppModel

    /// The count shown in the categorizing loader — eased toward the real
    /// `app.categorizeProgress.done` by `converterTick` so it rolls up merchant by
    /// merchant instead of jumping a whole batch of 40 at once.
    @State private var shownConverted = 0
    private let converterTick = Timer.publish(every: 0.03, on: .main, in: .common).autoconnect()

    private var s: Summary { app.summary }

    private func money(_ v: Double?) -> String {
        app.contextReady ? Money.format(v, currency: s.currency) : "—"
    }

    // MARK: per-currency card lines (single-currency docs keep today's exact
    // one-figure rendering; multi-currency docs get one line per currency —
    // never a mixed-currency sum). Ordering follows `currencyList`, so the
    // accessibility labels stay deterministic.

    private var balanceLines: [String] {
        guard app.contextReady, s.isMultiCurrency else { return [money(s.balance)] }
        let lines = s.currencyList.compactMap { cur in
            s.perCurrency[cur]?.balance.map { Money.format($0, currency: cur) }
        }
        return lines.isEmpty ? ["—"] : lines
    }

    private var spentLines: [String] {
        guard app.contextReady, s.isMultiCurrency else { return [money(app.contextReady ? s.spent : nil)] }
        return s.currencyList.compactMap { cur in
            s.perCurrency[cur].map { Money.format($0.spent, currency: cur) }
        }
    }

    private var netLines: [String] {
        guard app.contextReady, s.isMultiCurrency else { return [money(app.contextReady ? s.net : nil)] }
        return s.currencyList.compactMap { cur in
            s.perCurrency[cur].map { Money.format($0.net, currency: cur) }
        }
    }

    /// Warn tone when any currency's net is in the red.
    private var netTone: Tone {
        guard app.contextReady else { return .good }
        if s.isMultiCurrency { return s.perCurrency.values.contains { $0.net < 0 } ? .warn : .good }
        return s.net < 0 ? .warn : .good
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18).padding(.top, 13).padding(.bottom, 11)
                .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    statCard("total balance", balanceLines, sub: balanceSub)
                        .todayCardAccessibility(id: "today.balance",
                                                label: "total balance \(balanceLines.joined(separator: " · ")) \(balanceSub)")
                    statCard("spent · loaded statements", spentLines,
                             sub: "sum of debits", tone: .warn)
                        .todayCardAccessibility(id: "today.spent",
                                                label: "spent \(spentLines.joined(separator: " · ")) sum of debits")
                    statCard("net · income − spend", netLines,
                             sub: "excl. card repayments",
                             tone: netTone)
                        .todayCardAccessibility(id: "today.net",
                                                label: "net \(netLines.joined(separator: " · ")) excl. card repayments")
                    statCard("accounts", "\(app.docs.count)",
                             sub: app.docs.count == 1 ? "statement loaded" : "statements loaded")
                        .todayCardAccessibility(id: "today.accounts",
                                                label: "accounts \(app.docs.count) \(app.docs.count == 1 ? "statement loaded" : "statements loaded")")
                    categoriesSection
                    exportButton
                }
                .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 18)
            }
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bg)
        .overlay(Rectangle().fill(Theme.line).frame(width: 1), alignment: .leading)
        .fileExporter(isPresented: $app.isExportingCSV,
                      document: app.csvExportDocument(),
                      contentType: .commaSeparatedText,
                      defaultFilename: app.csvExportFilename()) { _ in }
    }

    /// Fix 7 — export the current (selected, or all) transactions to a
    /// spreadsheet/accountant-ready CSV. Disabled with nothing to export.
    @ViewBuilder private var exportButton: some View {
        Button { app.isExportingCSV = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                Text("Export CSV").font(Theme.font(11, .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(app.canExportCSV ? Theme.ink : Theme.dim)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
        .disabled(!app.canExportCSV)
        .padding(.top, 4)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Today").font(Theme.serif(17, .heavy)).foregroundStyle(Theme.ink)
            HStack(spacing: 6) {
                if app.isAnalyzing || app.isRecategorizing { ProgressView().controlSize(.small) }
                Text(statusLine).font(Theme.mono(9, .semibold)).foregroundStyle(Theme.dim)
            }
            // Fix 1 — the visible trust handshake: does the ledger's own math add
            // up? Shown once transactions are in and we're not mid-analysis.
            if !app.isAnalyzing, let line = app.reconciliationLine {
                Text(line)
                    .font(Theme.mono(9, .semibold))
                    .foregroundStyle(line.hasPrefix("⚠︎") ? Theme.coral : Theme.dim)
                    .accessibilityIdentifier("today.reconciliation")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusLine: String {
        if app.isAnalyzing { return "reading your transactions…" }
        if app.isRecategorizing { return "categorizing merchants…" }
        if app.contextReady { return "\(s.count) transactions · on-device" }
        return "on-device · upload a statement to begin"
    }

    /// "latest statement balance" for one account; when several are combined,
    /// say what the number actually is (cards subtract — they're money owed;
    /// mixed currencies are listed per currency, never summed).
    private var balanceSub: String {
        let chosen = app.docs.filter {
            app.selectedDocNames.isEmpty || app.selectedDocNames.contains($0.name)
        }
        let withBal = chosen.filter { $0.latestBalance != nil }
        if withBal.count <= 1 { return "latest statement balance" }
        if s.isMultiCurrency {
            return withBal.contains(where: \.isCard)
                ? "per currency · cards deducted"
                : "per currency · \(withBal.count) accounts"
        }
        return withBal.contains(where: \.isCard)
            ? "across accounts · cards deducted"
            : "across \(withBal.count) accounts"
    }

    @ViewBuilder private var categoriesSection: some View {
        // Show the bars the moment there ARE categories — the deterministic pass
        // labels every row at import, so we never make the user stare at a blank
        // skeleton for the whole (30–60s) Claude refinement. The bars update in
        // place as Claude improves them, with a small "refining" marker in the
        // header. The skeleton is only for the brief window where nothing exists
        // yet (statement still being read, or no categories at all yet).
        if !s.categories.isEmpty {
            categoryBars
        } else if app.isAnalyzing || app.isRecategorizing {
            categoriesLoadingCard
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
        statCard(label, [value], sub: sub, tone: tone)
    }

    /// Multi-value variant: one line per currency when statements span
    /// currencies (slightly smaller figures so several lines still fit).
    private func statCard(_ label: String, _ values: [String], sub: String, tone: Tone = .neutral) -> some View {
        let valueColor: Color = {
            switch tone {
            case .neutral: return Theme.ink
            case .warn:    return Theme.coral
            case .good:    return Theme.limeD
            }
        }()
        return VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Theme.caveat(12)).foregroundStyle(Theme.dim)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(values, id: \.self) { value in
                    Text(value)
                        .font(Theme.serif(values.count > 1 ? 16 : 22, .heavy))
                        .kerning(-0.4).foregroundStyle(valueColor)
                        .contentTransition(.numericText())
                }
            }
            Text(sub).font(Theme.mono(9, .semibold)).foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 13).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hardCard(radius: 12, border: 2, shadow: 3)
    }

    private var categoryBars: some View {
        let total = s.categories.reduce(0) { $0 + abs($1.amount) }
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("spend by category")
                    .font(Theme.serif(13.5, .heavy)).foregroundStyle(Theme.ink)
                // Bars are live from the deterministic pass; show a quiet marker
                // while Claude is still refining them so the changing numbers read.
                if app.isRecategorizing {
                    ProgressView().controlSize(.mini)
                    if let p = app.categorizeProgress, p.total > 0 {
                        Text("refining \(p.done)/\(p.total)")
                            .font(Theme.mono(9, .semibold)).foregroundStyle(Theme.dim)
                    } else {
                        Text("refining…").font(Theme.mono(9, .semibold)).foregroundStyle(Theme.dim)
                    }
                }
            }
            .padding(.bottom, 4)
            ForEach(s.categories.prefix(6)) { cat in
                let meta = CategoryMeta.style(for: cat.name)
                let pct = total > 0 ? abs(cat.amount) / total : 0
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(meta.icon).font(.system(size: 13)).frame(width: 18)
                        Text(cat.name).font(Theme.font(10.5, .semibold)).foregroundStyle(Theme.ink2)
                        Spacer(minLength: 8)
                        // Multi-currency categories show each currency's own
                        // total — ₹ + £ is never one number under one symbol.
                        Text(cat.amounts.count > 1
                             ? cat.amounts.sorted { $0.value > $1.value }
                                 .map { Money.format($0.value, currency: $0.key) }
                                 .joined(separator: " + ")
                             : Money.format(abs(cat.amount),
                                            currency: cat.amounts.keys.first ?? s.currency))
                            .font(Theme.mono(10)).foregroundStyle(Theme.ink)
                            .lineLimit(1).minimumScaleFactor(0.75)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Theme.bg2)
                            RoundedRectangle(cornerRadius: 3).fill(meta.fill)
                                .frame(width: geo.size.width * pct)
                        }
                    }
                    .frame(height: 8)
                    .padding(.leading, 25)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hardCard(radius: 12, border: 2, shadow: 3)
    }

    /// The loader's status line: a live, ticking "converted / total merchants"
    /// count while Claude works through a big statement, else the phase message.
    private var categorizingMessage: String {
        if let p = app.categorizeProgress, p.total > 0 {
            return "Identifying merchants… \(shownConverted) / \(p.total)"
        }
        return app.isRecategorizing ? "Categorizing your spending…"
                                    : "Reading your statement on-device…"
    }

    /// Loader shown in place of the category bars while the on-device pass runs,
    /// so the user never sees half-categorized figures (or a shrinking "Other").
    private var categoriesLoadingCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Text("spend by category")
                    .font(Theme.serif(13.5, .heavy)).foregroundStyle(Theme.ink)
                ProgressView().controlSize(.mini)
            }
            Text(categorizingMessage)
                .font(Theme.font(10.5, .semibold)).foregroundStyle(Theme.dim)
                .contentTransition(.numericText())        // digits roll as it counts
                .fixedSize(horizontal: false, vertical: true)
            // A moving count + determinate bar on big statements, so the loader
            // never looks frozen while Claude works through the merchants.
            if let p = app.categorizeProgress, p.total > 0 {
                ProgressView(value: Double(shownConverted), total: Double(p.total))
                    .tint(Theme.ink2)
                    .padding(.bottom, 2)
            }
            ForEach(0..<5, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 3).fill(Theme.bg2).frame(height: 12)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hardCard(radius: 12, border: 2, shadow: 3)
        // Ease the shown count toward the real batch total: reset at the start of a
        // pass, then step up ~one merchant per tick so it visibly counts on.
        .onReceive(converterTick) { _ in
            guard let p = app.categorizeProgress else { shownConverted = 0; return }
            if p.done == 0 { shownConverted = 0; return }
            if shownConverted < p.done {
                let step = max(1, (p.done - shownConverted) / 12)   // catch up if far behind
                withAnimation(.easeOut(duration: 0.03)) {
                    shownConverted = min(p.done, shownConverted + step)
                }
            }
        }
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

private extension View {
    /// One flat accessibility element with an explicit, deterministic label —
    /// `.combine` yields an empty label for these stat-card stacks, which broke
    /// UI-test reads of the Today figures.
    func todayCardAccessibility(id: String, label: String) -> some View {
        self.accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityIdentifier(id)
    }
}
