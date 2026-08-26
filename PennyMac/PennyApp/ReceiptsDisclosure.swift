// ReceiptsDisclosure — scope chip (Fix 5) + tap-to-reveal receipts (Fix 4), macOS.
//
// Under a deterministic answer, show WHAT the figure was scoped to and let the
// user drill into the exact transactions behind it. Pure presentation of
// `AnswerReceipts`; the numbers were computed deterministically upstream.
import SwiftUI

struct ReceiptsDisclosure: View {
    let receipts: AnswerReceipts
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Fix 5 — the scope chip: "on Groceries in June · money out".
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 10))
                Text(receipts.scopeLabel)
                    .font(Theme.mono(9, .semibold))
            }
            .foregroundStyle(Theme.dim)

            // Fix 4 — the drill-down toggle.
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(expanded
                         ? "Hide transactions"
                         : "Show \(receipts.totalCount) transaction\(receipts.totalCount == 1 ? "" : "s")")
                        .font(Theme.font(11, .semibold))
                }
                .foregroundStyle(Theme.ink)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.receipts.toggle")

            if expanded {
                VStack(spacing: 0) {
                    ForEach(Array(receipts.rows.enumerated()), id: \.offset) { _, r in
                        rowView(r)
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

    private func rowView(_ r: ReceiptRow) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(r.name).font(Theme.font(12, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(r.date).font(Theme.mono(9, .semibold)).foregroundStyle(Theme.dim)
            }
            Spacer()
            Text((r.isCredit ? "+" : "−") + Money.format(r.amount, currency: r.currency))
                .font(Theme.font(12, .bold).monospacedDigit())
                .foregroundStyle(r.isCredit ? Theme.lime : Theme.ink)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }
}
