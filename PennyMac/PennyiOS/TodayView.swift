// TodayView — the mockup's home tab on real data: hero card (balance + spend +
// stacked category bar), category pills with amounts, recent transactions.
// Mixed currencies never blend: the hero shows one line per currency.
import SwiftUI
import PennyTxnStore

struct TodayView: View {
    @EnvironmentObject var model: IOSModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                sectionHeader("Categories", right: "all time")
                categoryPills
                sectionHeader("Recent", right: "\(min(12, model.recentRows.count)) shown")
                recent
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
        }
        .background(T.bg)
    }

    // MARK: hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(model.perCurrency) { c in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(c.balance != nil ? "balance" : "income")
                            .font(T.mono(10)).kerning(1).foregroundStyle(T.dim)
                        Text(model.money(c.balance ?? c.income, c.currency))
                            .font(T.display(c.balance != nil ? 34 : 28, .semibold))
                            .foregroundStyle(T.ink)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("spent · \(c.currency)")
                            .font(T.mono(10)).kerning(1).foregroundStyle(T.dim)
                        Text(model.money(c.spent, c.currency))
                            .font(T.display(20, .semibold)).foregroundStyle(T.coral)
                    }
                }
            }
            spendBar
        }
        .padding(18)
        .pennyCard(tint: T.cardTint)
    }

    /// Stacked share-of-spend bar, top 5 categories.
    private var spendBar: some View {
        let cats = Array(model.spendByCategory.prefix(5))
        let total = max(1, cats.reduce(0) { $0 + $1.amount })
        let hues: [Color] = [T.coral, T.sky, T.plum, T.peach, T.lime]
        return GeometryReader { geo in
            HStack(spacing: 3) {
                ForEach(Array(cats.enumerated()), id: \.offset) { i, c in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(hues[i % hues.count])
                        .frame(width: max(6, geo.size.width * c.amount / total))
                }
            }
        }
        .frame(height: 9)
    }

    // MARK: categories

    private var categoryPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(model.spendByCategory.prefix(8), id: \.category) { c in
                    let look = T.categoryLook(c.category)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(look.emoji).font(.system(size: 20))
                        Text(model.money(c.amount)).font(T.display(17, .semibold)).foregroundStyle(T.ink)
                        Text(c.category).font(T.body(11, .medium)).foregroundStyle(T.dim)
                            .lineLimit(1)
                    }
                    .padding(12)
                    .frame(width: 116, alignment: .leading)
                    .pennyCard(tint: look.tint.opacity(0.45))
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: recent

    private var recent: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.recentRows.prefix(12).enumerated()), id: \.offset) { _, r in
                txnRow(r)
                Divider().overlay(T.lineSoft)
            }
        }
        .padding(.horizontal, 4)
        .pennyCard()
    }

    private func txnRow(_ r: TxnRow) -> some View {
        let look = T.categoryLook(r.category)
        let isCredit = r.credit > 0
        return HStack(spacing: 12) {
            Text(look.emoji)
                .font(.system(size: 16))
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
                .foregroundStyle(isCredit ? T.limeDeep : (r.debit >= 100 ? T.coral : T.ink))
        }
        .padding(.vertical, 9).padding(.horizontal, 10)
    }

    private func sectionHeader(_ title: String, right: String) -> some View {
        HStack {
            Text(title).font(T.display(17, .bold)).foregroundStyle(T.ink)
            Spacer()
            Text(right).font(T.mono(10)).foregroundStyle(T.dim2)
        }
        .padding(.top, 4)
    }
}
