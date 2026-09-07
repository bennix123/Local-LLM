import XCTest
import PennyFinance
import PennyModel
import PennyTxnStore
@testable import PennyCore

/// THE JUDGE (wave 2, Rahul's eval-honesty directive 2026-09-03): replay a
/// DeepSeek-generated corpus — truths computed by hand from the fixture,
/// phrasings from a generator NEITHER system has seen — through BOTH brains:
///
///   ladder = AccountQuery ?? FinanceRouter    (regex routing)
///   engine = QueryParser → QueryEngine → ResultRenderer (LLM-first dispatch)
///
/// Scored per outcome class, because the aggregate count lies:
///   correct  — the expected value(s) present
///   WRONG    — answered, but missing the expected value or carrying a
///              forbidden one (the sin: confidently answering something else)
///   declined — no answer (honest; the dispatcher falls back in production)
///
/// REPORT-ONLY by design: this is a measurement instrument, not a regression
/// gate — it prints the scorecard and every wrong answer verbatim for mining.
/// Env-gated (PENNY_JUDGE=1): needs the live Apple model; ~5–8 minutes.
final class EngineJudgeTests: XCTestCase {

    // MARK: fixture — same rows as ParaphraseSweepTests, truths hand-verified:
    // spent 3,670 · received 10,300 · debits 7 · months Nov25=1,200 Dec25=750
    // Jan26=950 Feb26=770 · cats Shopping 2,000 > F&D 820 > Pharmacy 700 >
    // Transport 150 · merchants AMAZON 2,000 top · largest 1,200 · smallest 150
    // · average debit 524.29

    private func row(_ seq: Int, _ date: String, _ descr: String, cat: String,
                     debit: Double = 0, credit: Double = 0) -> TxnRow {
        let p = date.split(separator: "-")
        return TxnRow(txnDate: date, month: "\(p[0])-\(p[1])", year: Int(p[0])!,
                      monthNo: Int(p[1])!, day: Int(p[2])!, descr: descr,
                      merchant: descr, category: cat, debit: debit, credit: credit,
                      balance: nil, currency: "INR", seq: seq)
    }

    private var rows: [TxnRow] {
        [
            row(1, "2025-11-05", "SALARY", cat: "Income", credit: 5000),
            row(2, "2025-11-10", "AMAZON", cat: "Shopping", debit: 1200),
            row(3, "2025-12-02", "SWIGGY", cat: "Food & Dining", debit: 300),
            row(4, "2025-12-15", "MEDPLUS", cat: "Pharmacy", debit: 450),
            row(5, "2026-01-04", "SALARY", cat: "Income", credit: 5200),
            row(6, "2026-01-09", "AMAZON", cat: "Shopping", debit: 800),
            row(7, "2026-01-20", "UBER", cat: "Transport", debit: 150),
            row(8, "2026-02-11", "MEDPLUS", cat: "Pharmacy", debit: 250),
            row(9, "2026-02-14", "REFUND", cat: "Income", credit: 100),
            row(10, "2026-02-20", "SWIGGY", cat: "Food & Dining", debit: 520),
        ]
    }

    /// expectAny: every inner group must be satisfied by AT LEAST ONE of its
    /// alternatives (month naming differs across brains: "November 2025" vs
    /// the engine's "2025-11" group key — both are the right answer).
    private struct Truth {
        let expectAny: [[String]]
        let forbid: [String]
    }

    private let truths: [String: Truth] = [
        "total_spend": Truth(expectAny: [["3,670.00"]], forbid: ["10,300.00"]),
        "total_income": Truth(expectAny: [["10,300.00"]], forbid: ["3,670.00"]),
        "count_debits": Truth(expectAny: [["7"]], forbid: ["10 ", "₹"]),
        "month_most_spend": Truth(expectAny: [["November 2025", "2025-11"], ["1,200.00"]],
                                  forbid: ["3,670.00"]),
        "month_least_spend": Truth(expectAny: [["December 2025", "2025-12"], ["750.00"]],
                                   forbid: ["3,670.00"]),
        "category_most": Truth(expectAny: [["2,000.00"]], forbid: ["3,670.00"]),
        "category_spend_pharmacy": Truth(expectAny: [["700.00"]], forbid: ["3,670.00"]),
        "merchant_most": Truth(expectAny: [["2,000.00"]], forbid: ["3,670.00"]),
        "largest_expense": Truth(expectAny: [["1,200.00"]], forbid: ["3,670.00"]),
        "smallest_expense": Truth(expectAny: [["150.00"]], forbid: ["3,670.00"]),
        "average_debit": Truth(expectAny: [["524.29"]], forbid: ["3,670.00"]),
        "spend_dec25": Truth(expectAny: [["750.00"]], forbid: ["3,670.00"]),
    ]

    private enum Outcome: String { case correct, wrong, declined }

    private func score(_ answer: String?, _ truth: Truth) -> Outcome {
        guard let a = answer else { return .declined }
        for f in truth.forbid where a.contains(f) { return .wrong }
        for group in truth.expectAny where !group.contains(where: { a.contains($0) }) {
            return .wrong
        }
        return .correct
    }

    func testJudgeLadderVsEngine() async throws {
        guard ProcessInfo.processInfo.environment["PENNY_JUDGE"] == "1" else {
            throw XCTSkip("set PENNY_JUDGE=1 to run the judge (live Apple model, ~5–8 min)")
        }
        let money = FinanceRouter.defaultMoney("INR")
        let graph = ModelAssembler.assemble(
            IngestOutput(rows: rows, bankName: "Test Bank", confidence: "judge",
                         detectedCurrency: "INR"),
            sourceName: "judge.pdf").graph
        let vocabulary = QueryVocabulary.from(graph)
        let today = CalendarDate(year: 2026, month: 9, day: 4)

        func ladder(_ q: String) -> String? {
            AccountQuery.answer(q, rows: rows, money: money)
                ?? FinanceRouter.answer(q, rows: rows, currency: "INR", money: money)
        }
        // PENNY_JUDGE_MODE=mlx measures the MLX fallback parser ALONE (Apple
        // bypassed) — needs the model's weights already installed; never
        // downloads.
        let mlxMode = ProcessInfo.processInfo.environment["PENNY_JUDGE_MODE"] == "mlx"
        var mlxGen: (@Sendable (String, String) async throws -> String)?
        if mlxMode {
            let llm = PennyLLM()
            guard await ModelStore.shared.directoryIfInstalled(for: PennyLLM.sliceModelID) != nil else {
                throw XCTSkip("MLX judge mode needs installed weights for \(PennyLLM.sliceModelID)")
            }
            mlxGen = { sys, p in try await llm.generateRaw(system: sys, prompt: p) }
            print("JUDGE MODE: mlx (\(PennyLLM.sliceModelID))")
        }
        func engine(_ q: String) async -> String? {
            guard let parsed = await QueryParser.parse(question: q, vocabulary: vocabulary,
                                                       today: today, mlxGenerate: mlxGen,
                                                       allowApple: !mlxMode) else { return nil }
            let result = QueryEngine.execute(parsed.query, in: graph)
            return ResultRenderer.render(result, query: parsed.query, vocabulary: vocabulary,
                                         money: { amt, code in
                FinanceRouter.defaultMoney(code ?? "INR")(NSDecimalNumber(decimal: amt).doubleValue)
            })
        }

        var tallies: [String: (ladder: [Outcome], engine: [Outcome])] = [:]
        var wrongs: [String] = []
        for (intent, phrasings) in EvalPhrasingsCorpus.phrasings.sorted(by: { $0.key < $1.key }) {
            guard let truth = truths[intent] else { continue }
            var l: [Outcome] = [], e: [Outcome] = []
            for q in phrasings {
                let la = ladder(q)
                let lo = score(la, truth)
                l.append(lo)
                if lo == .wrong { wrongs.append("LADDER [\(intent)] \(q)\n   → \(la ?? "")") }
                let ea = await engine(q)
                let eo = score(ea, truth)
                e.append(eo)
                if eo == .wrong { wrongs.append("ENGINE [\(intent)] \(q)\n   → \(ea ?? "")") }
            }
            tallies[intent] = (l, e)
        }

        func fmt(_ o: [Outcome]) -> String {
            let c = o.filter { $0 == .correct }.count
            let w = o.filter { $0 == .wrong }.count
            let d = o.filter { $0 == .declined }.count
            return "C\(c) W\(w) D\(d)"
        }
        print("\n════════ JUDGE SCORECARD (C correct · W wrong · D declined) ════════")
        print(String(format: "%-26s %-12s %-12s", ("intent" as NSString).utf8String!,
                     ("LADDER" as NSString).utf8String!, ("ENGINE" as NSString).utf8String!))
        var lAll: [Outcome] = [], eAll: [Outcome] = []
        for (intent, t) in tallies.sorted(by: { $0.key < $1.key }) {
            print(String(format: "%-26s %-12s %-12s", (intent as NSString).utf8String!,
                         (fmt(t.ladder) as NSString).utf8String!,
                         (fmt(t.engine) as NSString).utf8String!))
            lAll += t.ladder; eAll += t.engine
        }
        print("──────────────────────────────────────────────")
        print("TOTAL                      \(fmt(lAll))      \(fmt(eAll))   (n=\(lAll.count) each)")
        if !wrongs.isEmpty {
            print("\n──── WRONG ANSWERS (verbatim, for mining) ────")
            for w in wrongs { print(w) }
        }
        print("══════════════════════════════════════════════\n")
        XCTAssertFalse(tallies.isEmpty, "corpus must not be empty")
    }
}
