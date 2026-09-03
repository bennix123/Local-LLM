// ReceiptsDisclosure — scope chip (Fix 5) + citation pill (2026-09-03), macOS.
//
// Under a deterministic answer: WHAT the figure was scoped to, plus a compact
// ChatGPT-style citation pill ("🧾 31"). Hovering the pill pops a miniaturized
// list of the cited transactions; clicking it expands them inline; clicking a
// row selects that transaction's source statement in the sidebar (the closest
// thing to "open the file" — original import paths aren't retained). Pure
// presentation of `AnswerReceipts`; the numbers were computed upstream.
import SwiftUI

struct ReceiptsDisclosure: View {
    let receipts: AnswerReceipts
    @EnvironmentObject private var app: AppModel
    @State private var expanded = false
    @State private var hoverPopover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Fix 5 — the scope chip: "on Groceries in June · money out".
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 10))
                    Text(receipts.scopeLabel)
                        .font(Theme.mono(9, .semibold))
                }
                .foregroundStyle(Theme.dim)

                // The citation pill. Hover → mini popover; click → inline list.
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 9, weight: .bold))
                        Text("\(receipts.totalCount)")
                            .font(Theme.mono(10, .bold))
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.bg2, in: Capsule())
                    .overlay(Capsule().stroke(Theme.line, lineWidth: 1.2))
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if !expanded { hoverPopover = inside }
                    else if !inside { hoverPopover = false }
                }
                .popover(isPresented: $hoverPopover, arrowEdge: .bottom) {
                    miniList
                        .frame(width: 300)
                        .padding(8)
                }
                .help("The \(receipts.totalCount) transactions behind this answer — click to pin them open")
                .accessibilityIdentifier("chat.receipts.toggle")
                .accessibilityLabel("Show \(receipts.totalCount) cited transactions")
            }

            if expanded {
                VStack(spacing: 0) {
                    ForEach(Array(receipts.rows.enumerated()), id: \.offset) { _, r in
                        rowView(r, compact: false)
                        Theme.line.frame(height: 1)
                    }
                    if receipts.totalCount > receipts.rows.count {
                        Text("+ \(receipts.totalCount - receipts.rows.count) more")
                            .font(Theme.mono(9, .semibold)).foregroundStyle(Theme.dim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                    }
                }
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
            }
        }
        .padding(.leading, 2)
    }

    /// The hover popover: the first few citations, miniaturized.
    private var miniList: some View {
        VStack(spacing: 0) {
            ForEach(Array(receipts.rows.prefix(8).enumerated()), id: \.offset) { _, r in
                rowView(r, compact: true)
            }
            if receipts.totalCount > 8 {
                Text("+ \(receipts.totalCount - 8) more — click the pill to see all")
                    .font(Theme.mono(9, .semibold)).foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 5)
            }
        }
    }

    private func rowView(_ r: ReceiptRow, compact: Bool) -> some View {
        let source = sourceDoc(for: r)
        return Button {
            // "Open the file": select the source statement in the sidebar so
            // its panel + transactions come up. (Original import paths aren't
            // retained, so in-app reveal is the honest click-through.)
            if let source { app.selectedDocNames = [source.name] }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.name)
                        .font(Theme.font(compact ? 10.5 : 12, .semibold))
                        .foregroundStyle(Theme.ink).lineLimit(1)
                    HStack(spacing: 5) {
                        Text(r.date).font(Theme.mono(9, .semibold)).foregroundStyle(Theme.dim)
                        if let source {
                            Text(source.displayName)
                                .font(Theme.mono(8, .semibold))
                                .foregroundStyle(Theme.dim)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Theme.bg2, in: Capsule())
                        }
                    }
                }
                Spacer(minLength: 8)
                Text((r.isCredit ? "+" : "−") + Money.format(r.amount, currency: r.currency))
                    .font(Theme.font(compact ? 10.5 : 12, .bold).monospacedDigit())
                    .foregroundStyle(r.isCredit ? Theme.lime : Theme.ink)
            }
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 4 : 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(source.map { "Open \($0.displayName)" } ?? "")
    }

    /// Resolve a receipt row's source statement lazily by identity matching —
    /// receipts don't carry doc attribution (and old chat history never will),
    /// so match the row back the same way the account-attribution gate does.
    private func sourceDoc(for r: ReceiptRow) -> LoadedDoc? {
        app.docs.first { d in
            d.rows.contains {
                $0.txnDate == r.date
                    && (r.isCredit ? $0.credit : $0.debit) == r.amount
                    && (r.isCredit ? $0.credit : $0.debit) > 0
            }
        }
    }
}
