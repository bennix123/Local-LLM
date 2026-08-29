import XCTest
@testable import PennyTxnStore

/// Env-gated probe: run the FULL ingest chain over a real statement on this
/// machine without committing personal data. Skipped unless PENNY_PROBE_PDF
/// points at a file. `PENNY_PROBE_PDF=/path/to.pdf swift test --filter Probe`
final class UniversalIngestProbeTests: XCTestCase {
    func testProbeRealPDF() throws {
        guard let path = ProcessInfo.processInfo.environment["PENNY_PROBE_PDF"] else {
            throw XCTSkip("PENNY_PROBE_PDF not set")
        }
        let out = try TestPaths.makeIngester().ingestPDF(path: path)
        print("PROBE rows=\(out.rows.count) bank=\(out.bankName ?? "nil") cur=\(out.detectedCurrency) conf=\(out.confidence)")
        let debits = out.rows.filter { $0.debit > 0 }
        let credits = out.rows.filter { $0.credit > 0 }
        print("PROBE debits=\(debits.count) sum=\(debits.reduce(0) { $0 + $1.debit })")
        print("PROBE credits=\(credits.count) sum=\(credits.reduce(0) { $0 + $1.credit })")
        for r in out.rows.prefix(5) { print("PROBE row: \(r.txnDate) | \(r.descr.prefix(60)) | d\(r.debit) c\(r.credit)") }
        XCTAssertFalse(out.rows.isEmpty, "probe file produced no rows")
    }
}
