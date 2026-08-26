// SearchSheet — find-a-transaction (Fix 3), iOS.
//
// A structured, deterministic search over the whole ledger via `TxnSearch` — no
// model in the path, so it's instant and never invents a row. Presented as a
// sheet from the brand bar's magnifier.
import SwiftUI
import PennyTxnStore

struct SearchSheet: View {
    @EnvironmentObject var model: IOSModel
    @Environment(\.dismiss) private var dismiss
    @State private var q = ""

    private var results: [TxnRow] { TxnSearch.search(q, in: model.mergedRows) }

    var body: some View {
        NavigationStack {
            Group {
                if results.isEmpty {
                    ContentUnavailableView(
                        q.isEmpty ? "Search your transactions" : "No matches",
                        systemImage: "magnifyingglass",
                        description: Text(q.isEmpty
                            ? "By merchant, category, amount, or date."
                            : "Nothing matches “\(q)”."))
                } else {
                    List(results) { row in txnRow(row) }
                        .listStyle(.plain)
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .searchable(text: $q, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "merchant, amount, category…")
        .presentationBackground(T.bg)
    }

    private func txnRow(_ r: TxnRow) -> some View {
        let look = T.categoryLook(r.category)
        let isCredit = r.credit > 0
        return HStack(spacing: 12) {
            Text(look.emoji).font(.system(size: 16))
                .frame(width: 36, height: 36)
                .background(look.tint, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(r.merchant.isEmpty ? r.descr : r.merchant)
                    .font(T.body(14, .semibold)).foregroundStyle(T.ink).lineLimit(1)
                Text("\(r.txnDate) · \(r.category.lowercased())")
                    .font(T.body(11)).foregroundStyle(T.dim)
            }
            Spacer()
            Text((isCredit ? "+" : "−") + model.money(isCredit ? r.credit : r.debit, r.currency))
                .font(T.body(14, .bold).monospacedDigit())
                .foregroundStyle(isCredit ? T.limeDeep : T.ink)
        }
        .listRowBackground(T.bg)
    }
}
