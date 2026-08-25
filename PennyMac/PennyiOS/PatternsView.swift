// PatternsView — the mockup's "spending leak" cards, computed for real: every
// figure here comes deterministically from the parsed rows (no model, no
// invented correlations — the mockup's Instagram-scroll chart had no data
// source, so it stays out until one exists).
import SwiftUI
import PennyTxnStore

struct PatternsView: View {
    @EnvironmentObject var model: IOSModel

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let subs = zombieSubs { subs }
                if let wk = weekendCard { wk }
                if let day = biggestDayCard { day }
                if let top = topMerchantCard { top }
                if !hasAnyPattern {
                    Text("Patterns need a little more history — add another month's statement and I'll start spotting things.")
                        .font(T.body(13)).foregroundStyle(T.dim)
                        .multilineTextAlignment(.center)
                        .padding(.top, 60).padding(.horizontal, 30)
                }
            }
            .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 24)
        }
        .background(T.bg)
    }

    private var hasAnyPattern: Bool {
        !model.recurring.isEmpty || weekendSplit != nil || biggestDay != nil || topMerchant != nil
    }

    // MARK: zombie subs

    private var zombieSubs: AnyView? {
        let subs = model.recurring
        guard !subs.isEmpty else { return nil }
        let monthly = subs.reduce(0) { $0 + $1.amount }
        return AnyView(card(tag: "recurring charges", tagColor: T.coral,
                            title: "\(subs.count) charge\(subs.count == 1 ? "" : "s") on repeat 🧟") {
            VStack(spacing: 6) {
                ForEach(subs.prefix(6), id: \.name) { s in
                    HStack {
                        Text(s.name).font(T.body(13, .medium)).foregroundStyle(T.ink).lineLimit(1)
                        Spacer()
                        Text("\(model.money(s.amount))/mo · \(s.months) months")
                            .font(T.mono(11)).foregroundStyle(T.dim)
                    }
                }
                Divider().overlay(T.lineSoft)
                HStack {
                    Text("Cancel the dead ones and keep").font(T.body(13)).foregroundStyle(T.dim)
                    Spacer()
                    Text("\(model.money(monthly * 12))/yr").font(T.body(13, .bold)).foregroundStyle(T.limeDeep)
                }
            }
        })
    }

    // MARK: weekend vs weekday

    private var weekendSplit: (weekend: Double, weekday: Double)? {
        var weekend = 0.0, weekday = 0.0
        let cal = Calendar(identifier: .gregorian)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        for r in model.mergedRows where r.debit > 0 {
            guard let d = fmt.date(from: r.txnDate) else { continue }
            if cal.isDateInWeekend(d) { weekend += r.debit } else { weekday += r.debit }
        }
        guard weekend + weekday > 0 else { return nil }
        return (weekend, weekday)
    }

    private var weekendCard: AnyView? {
        guard let split = weekendSplit else { return nil }
        let total = split.weekend + split.weekday
        let pct = Int((split.weekend / total * 100).rounded())
        return AnyView(card(tag: "habit", tagColor: T.plum,
                            title: pct >= 40 ? "Weekends eat your wallet 🎉" : "Weekday-heavy spender 💼") {
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { geo in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 3).fill(T.plum)
                            .frame(width: max(6, geo.size.width * split.weekend / total))
                        RoundedRectangle(cornerRadius: 3).fill(T.sky)
                    }
                }
                .frame(height: 9)
                HStack {
                    Label("weekend \(model.money(split.weekend))", systemImage: "circle.fill")
                        .font(T.body(12)).foregroundStyle(T.plum)
                    Spacer()
                    Label("weekday \(model.money(split.weekday))", systemImage: "circle.fill")
                        .font(T.body(12)).foregroundStyle(T.sky)
                }
                .labelStyle(.titleAndIcon).imageScale(.small)
                Text("\(pct)% of spending lands on weekends — 2 of 7 days.")
                    .font(T.body(13)).foregroundStyle(T.dim)
            }
        })
    }

    // MARK: biggest day

    private var biggestDay: (date: String, amount: Double)? {
        var byDay: [String: Double] = [:]
        for r in model.mergedRows where r.debit > 0 { byDay[r.txnDate, default: 0] += r.debit }
        guard let best = byDay.max(by: { $0.value < $1.value }) else { return nil }
        return (best.key, best.value)
    }

    private var biggestDayCard: AnyView? {
        guard let day = biggestDay else { return nil }
        return AnyView(card(tag: "spike", tagColor: T.peach, title: "Your most expensive day 📅") {
            HStack {
                Text(day.date).font(T.mono(13)).foregroundStyle(T.dim)
                Spacer()
                Text(model.money(day.amount)).font(T.display(20, .semibold)).foregroundStyle(T.coral)
            }
        })
    }

    // MARK: top merchant

    private var topMerchant: (name: String, amount: Double, count: Int)? {
        var byMerchant: [String: (Double, Int)] = [:]
        for r in model.mergedRows where r.debit > 0 {
            let key = r.merchant.isEmpty ? r.descr : r.merchant
            let cur = byMerchant[key] ?? (0, 0)
            byMerchant[key] = (cur.0 + r.debit, cur.1 + 1)
        }
        guard let best = byMerchant.max(by: { $0.value.0 < $1.value.0 }) else { return nil }
        return (best.key, best.value.0, best.value.1)
    }

    private var topMerchantCard: AnyView? {
        guard let top = topMerchant else { return nil }
        return AnyView(card(tag: "top merchant", tagColor: T.sky, title: top.name) {
            HStack {
                Text("\(top.count) transaction\(top.count == 1 ? "" : "s")")
                    .font(T.body(13)).foregroundStyle(T.dim)
                Spacer()
                Text(model.money(top.amount)).font(T.display(20, .semibold)).foregroundStyle(T.ink)
            }
        })
    }

    // MARK: card chrome

    private func card(tag: String, tagColor: Color, title: String,
                      @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tag.uppercased())
                .font(T.mono(9, .semibold)).kerning(1.2)
                .foregroundStyle(tagColor)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(tagColor.opacity(0.14), in: Capsule())
            Text(title).font(T.display(18, .bold)).foregroundStyle(T.ink)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pennyCard()
    }
}
