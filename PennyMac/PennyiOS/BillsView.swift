// BillsView — the mockup's Bills tab on real data: the deterministic recurring
// detector's charges presented as a bill list with a monthly total. Statements
// are historical snapshots, so these are "charges that recur", not a live
// payment calendar — the copy says so honestly.
import SwiftUI
import PennyTxnStore

struct BillsView: View {
    @EnvironmentObject var model: IOSModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                let subs = model.recurring
                if subs.isEmpty {
                    VStack(spacing: 10) {
                        Text("🔔").font(.system(size: 40))
                        Text("No recurring charges yet")
                            .font(T.display(18, .bold)).foregroundStyle(T.ink)
                        Text("Recurring detection needs the same merchant across 3+ months at a steady amount. Add more statements to teach me your bills.")
                            .font(T.body(13)).foregroundStyle(T.dim)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 70).padding(.horizontal, 26)
                } else {
                    totalCard(subs)
                    VStack(spacing: 0) {
                        ForEach(subs, id: \.name) { s in
                            billRow(s)
                            Divider().overlay(T.lineSoft)
                        }
                    }
                    .padding(.horizontal, 4)
                    .pennyCard()
                    Text("Detected from your statements — merchants recurring monthly at a stable amount. Not a payment schedule.")
                        .font(T.body(11)).foregroundStyle(T.dim2)
                        .padding(.horizontal, 6)
                }
            }
            .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 24)
        }
        .background(T.bg)
    }

    private func totalCard(_ subs: [PennyTxnStore.FinanceRouter.RecurringCharge]) -> some View {
        let monthly = subs.reduce(0) { $0 + $1.amount }
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("recurring · per month").font(T.mono(10)).kerning(1).foregroundStyle(T.dim)
                Text(model.money(monthly)).font(T.display(30, .semibold)).foregroundStyle(T.ink)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("per year").font(T.mono(10)).kerning(1).foregroundStyle(T.dim)
                Text(model.money(monthly * 12)).font(T.display(18, .semibold)).foregroundStyle(T.coral)
            }
        }
        .padding(16)
        .pennyCard(tint: T.cardTint)
    }

    private func billRow(_ s: PennyTxnStore.FinanceRouter.RecurringCharge) -> some View {
        HStack(spacing: 12) {
            Text("🔁")
                .font(.system(size: 15))
                .frame(width: 34, height: 34)
                .background(T.limeSoft, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(T.body(14, .semibold)).foregroundStyle(T.ink).lineLimit(1)
                Text("seen \(s.count)× across \(s.months) months · \(Int(s.confidence * 100))% steady")
                    .font(T.body(11)).foregroundStyle(T.dim)
            }
            Spacer()
            Text(model.money(s.amount))
                .font(T.body(14, .bold).monospacedDigit()).foregroundStyle(T.ink)
        }
        .padding(.vertical, 9).padding(.horizontal, 10)
    }
}
