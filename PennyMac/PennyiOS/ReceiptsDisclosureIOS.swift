// ReceiptsDisclosureIOS — scope chip (Fix 5) + tap-to-reveal receipts (Fix 4).
//
// Under a deterministic chat answer, show what the figure was scoped to and let
// the user drill into the exact transactions behind it. Pure presentation of
// `AnswerReceipts`.
import SwiftUI

struct ReceiptsDisclosureIOS: View {
    let receipts: AnswerReceipts
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 10))
                Text(receipts.scopeLabel).font(T.mono(9, .semibold))
            }
            .foregroundStyle(T.dim)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(expanded
                         ? "Hide transactions"
                         : "Show \(receipts.totalCount) transaction\(receipts.totalCount == 1 ? "" : "s")")
                        .font(T.body(12, .semibold))
                }
                .foregroundStyle(T.ink)
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 0) {
                    ForEach(Array(receipts.rows.enumerated()), id: \.offset) { i, r in
                        rowView(r)
                        if i < receipts.rows.count - 1 { Divider().overlay(T.lineSoft) }
                    }
                    if receipts.totalCount > receipts.rows.count {
                        Text("+ \(receipts.totalCount - receipts.rows.count) more")
                            .font(T.mono(9, .semibold)).foregroundStyle(T.dim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                    }
                }
                .padding(.vertical, 2)
                .background(T.bg, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(T.line, lineWidth: 1))
            }
        }
    }

    private func rowView(_ r: ReceiptRow) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(r.name).font(T.body(13, .semibold)).foregroundStyle(T.ink).lineLimit(1)
                Text(r.date).font(T.mono(9, .semibold)).foregroundStyle(T.dim)
            }
            Spacer()
            Text((r.isCredit ? "+" : "−") + IOSModel.symbol(r.currency) + String(format: "%.2f", r.amount))
                .font(T.body(13, .bold).monospacedDigit())
                .foregroundStyle(r.isCredit ? T.limeDeep : T.ink)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }
}
