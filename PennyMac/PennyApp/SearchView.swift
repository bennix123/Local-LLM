// SearchView — find-a-transaction (Fix 3), macOS.
//
// A structured, deterministic search over the ledger via `TxnSearch`: no model,
// so results are instant and exact. Lives as a center view, toggled from the
// sidebar's "Search" row.
import SwiftUI
import PennyTxnStore

struct SearchView: View {
    @EnvironmentObject var app: AppModel
    @State private var q = ""
    @FocusState private var focused: Bool

    private var results: [TxnRow] { app.searchTransactions(q) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
                .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
                .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }

            if !app.hasRowsToSearch {
                empty("Upload a statement to search your transactions.")
            } else if results.isEmpty {
                empty(q.isEmpty ? "Search by merchant, category, amount, or date."
                                : "Nothing matches “\(q)”.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.offset) { _, r in
                            row(r)
                            Theme.line.frame(height: 1)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                }
                resultCount
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.bg)
        .onAppear { focused = true }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
            TextField("Search transactions", text: $q)
                .textFieldStyle(.plain)
                .font(Theme.font(14, .medium))
                .foregroundStyle(Theme.ink)
                .focused($focused)
            if !q.isEmpty {
                Button { q = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(Theme.dim)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1))
    }

    private func row(_ r: TxnRow) -> some View {
        let isCredit = r.credit > 0
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.merchant.isEmpty ? r.descr : r.merchant)
                    .font(Theme.font(13, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text("\(r.txnDate) · \(r.category.isEmpty ? "uncategorized" : r.category.lowercased())")
                    .font(Theme.mono(9, .semibold)).foregroundStyle(Theme.dim)
            }
            Spacer()
            Text((isCredit ? "+" : "−") + Money.format(isCredit ? r.credit : r.debit, currency: r.currency))
                .font(Theme.font(13, .bold).monospacedDigit())
                .foregroundStyle(isCredit ? Theme.lime : Theme.ink)
        }
        .padding(.vertical, 9).padding(.horizontal, 10)
    }

    private var resultCount: some View {
        Text("\(results.count) match\(results.count == 1 ? "" : "es")")
            .font(Theme.mono(9, .semibold)).foregroundStyle(Theme.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18).padding(.vertical, 8)
            .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(13, .medium)).foregroundStyle(Theme.dim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .multilineTextAlignment(.center).padding(40)
    }
}
