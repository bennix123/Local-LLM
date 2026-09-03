// ReceiptsDisclosureIOS — scope chip (Fix 5) + tap-to-reveal receipts (Fix 4).
//
// Under a deterministic chat answer, show what the figure was scoped to and let
// the user drill into the exact transactions behind it. Pure presentation of
// `AnswerReceipts`.
import SwiftUI

struct ReceiptsDisclosureIOS: View {
    let receipts: AnswerReceipts
    @EnvironmentObject private var model: IOSModel
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 10))
                    Text(receipts.scopeLabel).font(T.mono(9, .semibold))
                }
                .foregroundStyle(T.dim)

                // Citation pill — tap to expand the cited transactions
                // (parity with the macOS hover pill; iOS has no hover).
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text").font(.system(size: 9, weight: .bold))
                        Text("\(receipts.totalCount)").font(T.mono(10, .bold))
                    }
                    .foregroundStyle(T.ink)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(T.bg, in: Capsule())
                    .overlay(Capsule().stroke(T.line, lineWidth: 1.2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(receipts.totalCount) cited transactions")
            }

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
        let source = sourceStatement(for: r)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(r.name).font(T.body(13, .semibold)).foregroundStyle(T.ink).lineLimit(1)
                HStack(spacing: 5) {
                    Text(r.date).font(T.mono(9, .semibold)).foregroundStyle(T.dim)
                    if let source {
                        Text(source)
                            .font(T.mono(8, .semibold)).foregroundStyle(T.dim)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(T.bg, in: Capsule())
                    }
                }
            }
            Spacer()
            Text((r.isCredit ? "+" : "−") + IOSModel.symbol(r.currency) + String(format: "%.2f", r.amount))
                .font(T.body(13, .bold).monospacedDigit())
                .foregroundStyle(r.isCredit ? T.limeDeep : T.ink)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    /// Lazy source attribution — receipts don't carry doc identity, so match
    /// the row back to its statement (parity with the macOS pill).
    private func sourceStatement(for r: ReceiptRow) -> String? {
        model.statements.first { s in
            s.rows.contains {
                $0.txnDate == r.date
                    && (r.isCredit ? $0.credit : $0.debit) == r.amount
                    && (r.isCredit ? $0.credit : $0.debit) > 0
            }
        }?.displayName
    }
}
