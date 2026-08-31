import XCTest
@testable import PennyTxnStore

/// TEMPORARY diagnostic — replay the 2026-08-31 manual-test failures against
/// the real statement. Env-gated like the probe test; not meant for commit.
final class DiagnosticReplayTests: XCTestCase {
    func testDumpRawStructure() throws {
        guard let path = ProcessInfo.processInfo.environment["PENNY_PROBE_PDF"] else {
            throw XCTSkip("PENNY_PROBE_PDF not set")
        }
        let doc = try PDFTextExtractor(path: path)
        var all: [String] = []
        for i in 0..<doc.pageCount {
            all.append(contentsOf: (doc.page(i)?.text ?? "").split(separator: "\n").map(String.init))
        }
        // Context around a glued merchant, a bank mention, and any Tag lines
        for (i, l) in all.enumerated() where l.contains("Balaji") {
            print("RAW balaji ctx:"); for j in max(0, i-2)...min(all.count-1, i+6) { print("RAW   | \(all[j])") }
            break
        }
        for (i, l) in all.enumerated() where l.contains("Canara") {
            print("RAW canara ctx (line \(i)):"); for j in max(0, i-4)...min(all.count-1, i+4) { print("RAW   | \(all[j])") }
        }
        var shown = 0
        for (i, l) in all.enumerated() where l.contains("Of India") && shown < 3 {
            shown += 1
            print("RAW ofindia ctx (line \(i)):")
            for j in max(0, i-6)...min(all.count-1, i+2) { print("RAW   |\(all[j])|") }
        }
        print("RAW union-line variants:")
        for v in Set(all.filter { $0.contains("Union") }).prefix(6) { print("RAW   u|\(v)|") }
        let tagLines = all.filter { $0.lowercased().contains("tag") }
        print("RAW tag-ish lines: \(tagLines.count)"); for t in tagLines.prefix(8) { print("RAW   tag| \(t)") }
        let bankLines = all.filter { $0.lowercased().contains("bank") }
        print("RAW bank-ish lines: \(bankLines.count)"); for t in bankLines.prefix(12) { print("RAW   bank| \(t)") }
        print("RAW first 40 lines:"); for l in all.prefix(40) { print("RAW   | \(l)") }
    }

    func testReplayFailedQuestions() throws {
        guard let path = ProcessInfo.processInfo.environment["PENNY_PROBE_PDF"] else {
            throw XCTSkip("PENNY_PROBE_PDF not set")
        }
        let out = try TestPaths.makeIngester().ingestPDF(path: path)
        let rows = out.rows
        print("DIAG rows=\(rows.count) conf=\(out.confidence) accounts=\(out.underlyingAccounts)")

        // Do rows carry per-transaction bank info at all?
        let union = rows.filter { $0.descr.lowercased().contains("union") }
        let canara = rows.filter { $0.descr.lowercased().contains("canara") }
        print("DIAG rows mentioning union=\(union.count) canara=\(canara.count)")
        for r in rows.prefix(3) { print("DIAG fulldescr: [\(r.descr)] merchant=[\(r.merchant)] cat=\(r.category) tags=\(r.rawCategory ?? "-")") }
        if let sb = rows.first(where: { $0.descr.lowercased().contains("balaji") }) {
            print("DIAG balaji descr: [\(sb.descr)] merchant=[\(sb.merchant)]")
        }
        let selfT = rows.filter { $0.isSelfTransfer }
        print("DIAG self-transfer rows=\(selfT.count)")
        for r in selfT.prefix(4) { print("DIAG self: \(r.txnDate) d\(r.debit) c\(r.credit) [\(r.descr.prefix(50))] acct=\(r.account ?? "-")") }
        let byAcct = Dictionary(grouping: rows, by: { $0.account ?? "nil" }).mapValues(\.count)
        print("DIAG accounts: \(byAcct)")
        let tagged = rows.filter { $0.rawCategory != nil }
        print("DIAG tagged rows=\(tagged.count) sampleTags=\(Set(tagged.prefix(60).compactMap(\.rawCategory)).sorted())")
        print("DIAG date range: \(rows.map(\.txnDate).min() ?? "-") .. \(rows.map(\.txnDate).max() ?? "-")")
        let cats = Dictionary(grouping: rows.filter { $0.debit > 0 }, by: { $0.category })
            .mapValues { $0.reduce(0) { $0 + $1.debit } }.sorted { $0.value > $1.value }
        print("DIAG top categories: \(cats.prefix(5).map { "\($0.key)=\(Int($0.value))" }.joined(separator: ", "))")

        let money: (Double) -> String = { "₹" + String(format: "%.2f", $0) }
        let questions = [
            "Which month did I spend the most?",
            "What was my highest-spending month?",
            "What was my lowest-spending month?",
            "How much did I pay from Union Bank?",
            "How many payments did I make from Union Bank?",
            "How much did I receive into Union Bank?",
            "How much did I receive into Canara Bank?",
            "How much did I spend in May and August combined?",
            "Who sent me money?",
            "Did I spend more than I received?",
            "What's the latest transaction?",
            "When did Subbireddy K send me money?",
            "How much did I receive from Subbireddy K?",
            "Where did most of my money go?",
            "Did I transfer money to UPI Lite?",
            "Did I transfer money between my own bank accounts?",
        ]
        for q in questions {
            let a = FinanceRouter.answer(q, rows: rows, currency: "INR", money: money)
            print("DIAG Q: \(q)")
            print("DIAG A: \(a?.replacingOccurrences(of: "\n", with: " ⏎ ") ?? "<nil → app keyword/scope fallback or model>")")
        }
    }
}
