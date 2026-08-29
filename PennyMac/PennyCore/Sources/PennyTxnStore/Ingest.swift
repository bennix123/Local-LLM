// Ingest — ingest_pdf() from parsers.py: profile match, parser selection,
// dedicated-parser fallback to the generic cascade, category hints, reverse
// detection, seq assignment. The LLM "Other" mop-up is intentionally absent:
// the deterministic contract (and the expected fixtures) are defined without it.
import Foundation

public struct IngestOutput {
    public let rows: [TxnRow]
    public let bankName: String?
    public let confidence: String
    public let detectedCurrency: String
    /// The statement's own closing-balance figure, when its summary box states
    /// one (UK layout parsers). nil for the contract-locked parsers.
    public var closingBalance: Double? = nil
    /// Credit-card semantics: the balance is money OWED, charges are debits and
    /// "payment received" credits are transfers, not income.
    public var isCard: Bool = false
    /// Underlying bank accounts an aggregator export names in its summary
    /// (see StatementName.underlyingAccounts) — [] for plain statements.
    public var underlyingAccounts: [String] = []

    /// Public initializer (matches the memberwise shape) so out-of-module callers —
    /// e.g. the v1→v2 persistence migration rebuilding `IngestOutput` from stored
    /// rows — can construct one. Behaviour-neutral for the parser itself.
    public init(rows: [TxnRow], bankName: String?, confidence: String,
                detectedCurrency: String, closingBalance: Double? = nil, isCard: Bool = false) {
        self.rows = rows; self.bankName = bankName; self.confidence = confidence
        self.detectedCurrency = detectedCurrency; self.closingBalance = closingBalance; self.isCard = isCard
    }
}

public final class TxnIngester {
    let categories: Categories
    let registry: BankProfileRegistry

    public init(categoriesJSONPath: String, bankProfilesDir: String) throws {
        categories = try Categories(categoriesJSONPath: categoriesJSONPath)
        registry = BankProfileRegistry(dir: bankProfilesDir)
    }

    /// Parse a statement PDF into canonical rows (auto-detecting the bank).
    public func ingestPDF(path: String) throws -> IngestOutput {
        let doc = try PDFTextExtractor(path: path)
        let startPage = PageClassifier.findTableStart(doc)
        let head = GenericParsers.headText(doc, from: startPage)

        // Stage 4 HLD: profile registry first
        let matchedProfile = registry.match(head)
        let profileCurrency = matchedProfile?.currency ?? ""

        var detectedCur = profileCurrency.isEmpty ? "INR" : profileCurrency
        if profileCurrency.isEmpty {
            detectedCur = GenericParsers.sniffCurrency(head)   // "" when nothing matches, like the Python
        }

        // parser selection
        let profileBank = (matchedProfile?.bankName ?? "").pyLower()
        enum Route { case barclays, pnb, wrenfield, paytm, columnar, rowRE, ukLayout, generic }
        // UK-layout detectors read the first pages directly (their brand headers
        // can sit before the table start that `head` is anchored to).
        var early = ""
        for i in 0..<min(2, doc.pageCount) { early += doc.page(i)?.text ?? "" }
        let earlyLow = early.pyLower()
        let isUKLayout = UKParsers.isAmexCard(earlyLow) || UKParsers.isRevolutTable(earlyLow)
            || UKParsers.isMonzoTable(earlyLow) || UKParsers.isNatWestTable(earlyLow)
            || UKParsers.isNationwideTable(earlyLow)
        let route: Route
        if profileBank == "barclays" || BankParsers.isBarclays(head) {
            route = .barclays
        } else if profileBank == "pnb" || BankParsers.isPNB(head) {
            route = .pnb
        } else if profileBank == "wrenfield" || BankParsers.isWrenfield(head) {
            route = .wrenfield
        } else if profileBank == "paytm" || BankParsers.isPaytmStatement(early) {
            // Before the HDFC-style detector: the Paytm app export's summary box
            // trips `isTransactionStatement`, which then scrapes one junk row
            // out of the header instead of the 400+ real transactions.
            route = .paytm
        } else if profileBank == "hdfc" || BankParsers.isTransactionStatement(head) {
            route = .rowRE
        } else if isUKLayout {
            route = .ukLayout
        } else if BankParsers.isColumnarDebitCredit(head) || BankParsers.isColumnarDebitCredit(early) {
            // Bank-agnostic Date|Narration|Debit|Credit|Balance layout (Indian banks
            // and lookalikes). Placed after the specific detectors so it only claims
            // what would otherwise fall to the generic cascade; an empty result still
            // falls back to generic below.
            route = .columnar
        } else {
            route = .generic
        }

        let bankName = AccountProfile.bankName(doc: doc, pdfPath: path) ?? matchedProfile?.bankName

        var confidence = "high"
        var txns: [TxnRow]
        var cardSummary: CardStatementSummary? = nil
        switch route {
        case .barclays:
            txns = BankParsers.parseBarclays(doc, pdfPath: path, categories: categories)
        case .pnb:
            txns = BankParsers.parsePNB(doc, categories: categories)
        case .wrenfield:
            txns = BankParsers.parseWrenfield(doc, categories: categories)
        case .paytm:
            if detectedCur.isEmpty { detectedCur = "INR" }
            txns = BankParsers.parsePaytm(doc, categories: categories)
        case .columnar:
            if detectedCur.isEmpty { detectedCur = "INR" }
            txns = BankParsers.parseColumnarDebitCredit(doc, categories: categories, currency: detectedCur)
        case .rowRE:
            txns = BankParsers.parsePDF(doc, categories: categories)
        case .ukLayout:
            let (rows, summary) = UKParsers.isAmexCard(earlyLow)
                ? UKParsers.parseAmexCard(doc, categories: categories)
                : UKParsers.parseColumnTable(doc, categories: categories)
            txns = rows
            cardSummary = summary
            if detectedCur.isEmpty || detectedCur == "INR" { detectedCur = "GBP" }
        case .generic:
            let res = GenericParsers.parseGenericStatement(doc, categories: categories)
            txns = res.rows
            confidence = res.confidence
        }

        // dedicated parser produced nothing -> fallback cascade.
        // (Not for UK layouts: the generic cascade is known to misread them —
        // fake balances, wrong dates — so empty is more honest than garbage.)
        if txns.isEmpty, route != .generic, route != .ukLayout {
            // Generic first — it correctly handles the statements a dedicated (or the
            // columnar) parser abstains on today, so its output must not change. This
            // includes columnar-routed statements whose GBP/EUR body the columnar
            // parser can't read: they must still recover via generic.
            let res = GenericParsers.parseGenericStatement(doc, categories: categories)
            txns = res.rows
            confidence = res.confidence
            // Only when generic ALSO yields nothing and the layout is the columnar
            // Debit/Credit/Balance format do we recover via the universal columnar
            // parser — e.g. a bank profile forced .pnb for an issuer whose statement
            // uses the modern layout that neither the PNB parser nor generic reads.
            if txns.isEmpty, route != .columnar,
               BankParsers.isColumnarDebitCredit(head) || BankParsers.isColumnarDebitCredit(early) {
                if detectedCur.isEmpty { detectedCur = "INR" }
                txns = BankParsers.parseColumnarDebitCredit(doc, categories: categories, currency: detectedCur)
            }
            // Universal last-ditch: a labeled "Date … Balance" column table that
            // neither the dedicated route nor generic nor the Debit/Credit engine
            // read — e.g. a real Monzo app export whose layout differs from the
            // synthetic specimen, or any UK-style money-in/out table we don't have a
            // brand detector for. `parseColumnTable` self-gates on locating that
            // header, so it's a no-op when the doc has none; it runs only after every
            // other parser abstained, so it can't regress a statement that parses.
            if txns.isEmpty {
                let (rows, summary) = UKParsers.parseColumnTable(doc, categories: categories)
                if !rows.isEmpty {
                    txns = rows
                    cardSummary = summary
                    if detectedCur.isEmpty || detectedCur == "INR" { detectedCur = "GBP" }
                }
            }
        }

        // Universal record-block reader — bank-agnostic, runs only when every
        // parser above abstained, and only keeps output the document itself
        // verifies (balance chain or printed totals), so it can never regress
        // a parsed statement nor ship unverified rows.
        if txns.isEmpty {
            var pages = (0..<doc.pageCount).compactMap { doc.page($0)?.text }
            // No text layer (scan/photo PDF) → on-device OCR, same line shape.
            if ScannedPDFText.looksScanned(pages, pageCount: doc.pageCount) {
                pages = ScannedPDFText.ocrPages(path: path)
            }
            if let uni = UniversalRecordIngest.parse(pages: pages, categories: categories) {
                txns = uni.rows
                confidence = "universal-\(uni.verification)"
                if detectedCur.isEmpty || uni.currency != "INR" || detectedCur == "INR" {
                    detectedCur = uni.currency
                }
            }
        }

        // category hints folded into the description tail
        for i in 0..<txns.count {
            let (cleanDesc, hint) = Describe.extractCategoryHint(txns[i].descr)
            if let hint {
                txns[i].descr = cleanDesc
                txns[i].rawCategory = hint
                if let norm = Describe.normalizeCategory(hint) {
                    txns[i].category = norm
                }
            }
        }

        if txns.isEmpty {
            return IngestOutput(rows: [], bankName: bankName, confidence: confidence,
                                detectedCurrency: detectedCur,
                                closingBalance: cardSummary?.closingBalance,
                                isCard: cardSummary?.isCard ?? false)
        }

        // (LLM categorizer mop-up for "Other" rows lives in the app layer, not here.)

        // reverse-chronological detection
        var isRev = false
        if txns.count >= 2 {
            let firstDate = txns[0].txnDate
            let lastDate = txns[txns.count - 1].txnDate
            if firstDate > lastDate {
                isRev = true
            } else if firstDate == lastDate {
                let balCurr = txns[0].balance
                let balNext = txns[1].balance
                let amtCurr = txns[0].credit - txns[0].debit
                if let bc = balCurr, let bn = balNext {
                    if abs((bn + amtCurr) - bc) < 0.01 {
                        isRev = true
                    }
                }
            }
        }
        if isRev { txns.reverse() }

        // Generic credit-card statements (issuers without a dedicated card
        // parser): conservative header detection, then card semantics — the
        // owed-balance polarity flip and repayment→"Payments" recategorization.
        // Runs AFTER order normalization: the balance-delta signs only mean
        // "charge vs payment" on chronologically ordered rows.
        if cardSummary == nil, route == .generic, CardStatement.detect(early) {
            txns = CardStatement.applyCardSemantics(txns)
            cardSummary = CardStatementSummary(
                closingBalance: CardStatement.statedClosingBalance(early)
                    ?? txns.last(where: { $0.balance != nil })?.balance,
                isCard: true)
        }

        for i in 0..<txns.count {
            txns[i].seq = i + 1
            // currency override: default INR rows follow the detected currency
            if txns[i].currency == "INR", detectedCur != "INR" {
                txns[i].currency = detectedCur
            }
        }

        var output = IngestOutput(rows: txns, bankName: bankName, confidence: confidence,
                                  detectedCurrency: detectedCur,
                                  closingBalance: cardSummary?.closingBalance,
                                  isCard: cardSummary?.isCard ?? false)
        output.underlyingAccounts = StatementName.underlyingAccounts(in: early)
        return output
    }

    /// Parse a CSV statement/export into canonical rows — ingest_csv() from
    /// parsers.py, flowing through the same TxnRow shape, classification,
    /// order normalization and card semantics as the PDF path.
    public func ingestCSV(path: String) throws -> IngestOutput {
        try CSVIngest.ingest(path: path, categories: categories)
    }

    /// Parse an Excel (.xlsx) export: the workbook's first transaction-bearing
    /// sheet flows through the same header-discovery pipeline as CSV.
    public func ingestXLSX(path: String) throws -> IngestOutput {
        try XLSXIngest.ingest(path: path, categories: categories)
    }
}
