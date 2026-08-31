import PennyModel

/// Task 0.4 — the parser → canonical-model **translation layer**.
///
/// Maps the legacy parser's `IngestOutput` into `PennyModel` value types: one
/// `Account` + one `Statement` + its `[Transaction]` per ingested file. It is a
/// pure, total function — no I/O, no detection, no analytics. The parser
/// (`TxnIngester`) is untouched and its behaviour is preserved exactly.
///
/// **Legacy parser projection (Decision A):** the parser already assigns a
/// `merchant` and `category` string per row. Those are carried verbatim into
/// `Enrichment` and surfaced as `merchants` / `categories`, purely to preserve
/// current behaviour through Task 0.7. They are **not** canonical enrichment — no
/// alias folding, no normalization — and Phase 2 replaces them via the real
/// enrichment pipeline.
public enum ModelAssembler {

    /// The per-file assembly: the account, its statement, its transactions, and
    /// the legacy merchant/category projections.
    public struct AssemblyResult: Sendable {
        public let account: Account
        public let statement: Statement
        public let transactions: [Transaction]
        public let merchants: [Merchant]     // legacy projection (Decision A)
        public let categories: [Category]    // legacy projection (Decision A)

        /// This file's slice as a `FinancialGraph`.
        public var graph: FinancialGraph {
            FinancialGraph(accounts: [account], statements: [statement],
                           transactions: transactions, merchants: merchants, categories: categories)
        }
    }

    public static func assemble(_ out: IngestOutput, sourceName: String,
                                metadata: StatementMetadata = .empty) -> AssemblyResult {
        // --- Account (Task 0.5: identity keys on account number / sort code when present) ---
        let institution = out.bankName ?? "Unknown"
        let currency = Currency(out.detectedCurrency.isEmpty ? "INR" : out.detectedCurrency)
        let account = Account(
            id: ModelIdentity.accountID(institution: institution, currency: currency,
                                        accountNumber: metadata.accountNumber, sortCode: metadata.sortCode),
            institution: institution,
            kind: out.isCard ? .credit : .current,
            number: metadata.accountNumber,
            sortCode: metadata.sortCode,
            holder: metadata.holder,
            currency: currency)

        // --- Statement (Task 0.5: header metadata). Closing balance comes from the
        //     parser's own figure only — matching the app's existing behaviour
        //     exactly (the metadata closing read is parsed but not mapped here, to
        //     avoid changing what statements without a parser closing display). ---
        let closingBalance = DecimalBridge.money(out.closingBalance)
        let statement = Statement(
            id: ModelIdentity.statementID(
                accountID: account.id,
                firstDate: out.rows.first?.txnDate ?? "",
                lastDate: out.rows.last?.txnDate ?? "",
                rowCount: out.rows.count,
                closingBalance: closingBalance?.amount.description ?? ""),
            accountID: account.id,
            sourceName: sourceName,
            period: metadata.period,
            statementDate: metadata.statementDate,
            openingBalance: metadata.openingBalance,
            closingBalance: closingBalance,
            availableBalance: metadata.availableBalance,
            creditLimit: metadata.creditLimit)

        // --- Transactions + legacy projections ---
        var merchantsByID: [MerchantID: Merchant] = [:]
        var categoriesByID: [CategoryID: Category] = [:]
        let transactions = out.rows.map { row -> Transaction in
            assembleRow(row, account: account, statement: statement,
                        merchants: &merchantsByID, categories: &categoriesByID)
        }

        return AssemblyResult(
            account: account, statement: statement, transactions: transactions,
            merchants: merchantsByID.values.sorted { $0.id.raw < $1.id.raw },
            categories: categoriesByID.values.sorted { $0.id.raw < $1.id.raw })
    }

    private static func assembleRow(_ row: TxnRow, account: Account, statement: Statement,
                                    merchants: inout [MerchantID: Merchant],
                                    categories: inout [CategoryID: Category]) -> Transaction {
        let amount = DecimalBridge.signedMoney(debit: row.debit, credit: row.credit)

        // Legacy projection (Decision A) — carried verbatim, not normalized.
        var merchantID: MerchantID?
        if !row.merchant.isEmpty {
            let id = ModelIdentity.merchantID(row.merchant)
            merchants[id] = Merchant(id: id, canonicalName: row.merchant)
            merchantID = id
        }
        var categoryID: CategoryID?
        if !row.category.isEmpty {
            let id = CategoryID(row.category)
            categories[id] = Category(id: id, name: row.category)
            categoryID = id
        }
        let enrichment = Enrichment(
            merchantID: merchantID,
            cleanDescription: nil,       // legacy has none; Phase 2.2 produces it
            categoryID: categoryID,      // recurring / transfer-pair / confidence ← Phase 2
            // Statement-stated self-transfers ARE the internal-transfer fact —
            // carried as the canonical tag so it survives persistence.
            tags: row.isSelfTransfer ? [.internalTransfer] : [])

        return Transaction(
            id: ModelIdentity.transactionID(statementID: statement.id, seq: row.seq,
                                            date: row.txnDate, descr: row.descr,
                                            amount: amount.amount.description),
            accountID: account.id, statementID: statement.id,
            date: CalendarDate(year: row.year, month: row.monthNo, day: row.day),
            rawDescription: row.descr,
            amount: amount,
            balance: DecimalBridge.money(row.balance),
            currency: Currency(row.currency.isEmpty ? account.currency.code : row.currency),
            fx: parsedFX(row, accountCurrency: account.currency),
            subAccount: row.account,
            enrichment: enrichment)
    }

    /// Parsed FX for a row. Prefers the structured foreign-spend detail a parser
    /// captured off the statement's own FX column/line (e.g. Amex "Foreign Spend"
    /// + "Exchange Rate … Transaction Fee"); falls back to a best-effort scrape of
    /// the description text (Task 0.5). Either way it is kept only when the original
    /// currency actually differs from the account's — a same-currency amount isn't
    /// "foreign".
    private static func parsedFX(_ row: TxnRow, accountCurrency: Currency) -> FXInfo? {
        if let amt = row.fxForeignAmount, let code = row.fxForeignCurrency {
            let currency = Currency(code)
            if currency != accountCurrency {
                return FXInfo(
                    originalAmount: Money(decimal: DecimalBridge.decimal(amt)),
                    originalCurrency: currency,
                    rate: row.fxRate.map { DecimalBridge.decimal($0) },
                    fee: row.fxFee.map { Money(decimal: DecimalBridge.decimal($0)) },
                    country: nil)
            }
        }
        guard let fx = TransactionFXParser.fx(from: row.descr),
              fx.originalCurrency != accountCurrency else { return nil }
        return fx
    }
}
