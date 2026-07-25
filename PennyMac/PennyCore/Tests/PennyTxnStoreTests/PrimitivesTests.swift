// PrimitivesTests — guards the deterministic building blocks the whole parser
// stack rests on: DateParse (every statement date format plus its documented
// no-range-validation quirks), the money() string→Double parser and the generic
// money token recognizer, categorization (Categories order-sensitive rule
// loading from contract/categories.json, Classify merchant/category assignment,
// Barclays narrative parsing, hint extraction/normalization), and the PyKit
// Python-semantics shims (banker's rounding, str.title/rsplit/splitlines, and
// the `re`-alike PyRegex). Every expected value below was ground-truthed by
// executing the Python reference (finquery/backend/.../parsers.py,
// formatters.py) against the real contract categories.json — including the
// quirks (e.g. "32/13/2024" parses, "(100.00)" is positive, "netflix"
// normalizes to Transport via its embedded "tfl") — so a failure here means a
// genuine divergence from the contract, not a stale guess.
import XCTest
@testable import PennyTxnStore

// MARK: - DateParse.parseDate

final class DateParseTests: XCTestCase {

    /// Compares an optional (y, m, d) tuple with a readable failure message.
    private func assertDate(_ input: String, _ expected: (Int, Int, Int)?,
                            file: StaticString = #filePath, line: UInt = #line) {
        let got = DateParse.parseDate(input)
        switch (got, expected) {
        case (nil, nil):
            break
        case let (g?, e?):
            XCTAssertTrue(g == e,
                          "parseDate(\(input.debugDescription)) == \(g), expected \(e)",
                          file: file, line: line)
        case let (g, _):
            XCTFail("parseDate(\(input.debugDescription)) == \(String(describing: g)), " +
                    "expected \(String(describing: expected))",
                    file: file, line: line)
        }
    }

    func testUKSpacedFormat() {
        assertDate("01 Apr 2024", (2024, 4, 1))
        assertDate("01 SEP 24", (2024, 9, 1))     // uppercase month + 2-digit year
        assertDate("28 feb 2023", (2023, 2, 28))  // lowercase month
        assertDate("  01 Apr 2024  ", (2024, 4, 1)) // input is stripped first
    }

    func testISOFormats() {
        assertDate("2024-04-01", (2024, 4, 1))
        assertDate("2024/04/01", (2024, 4, 1))
        assertDate("2024.04.01", (2024, 4, 1))
    }

    func testSlashedDayFirst() {
        // Day-first (UK/India): 13/04 must be 13 April, never April 13th-month.
        assertDate("13/04/2024", (2024, 4, 13))
        assertDate("01/04/2024", (2024, 4, 1))
        assertDate("01.04.2024", (2024, 4, 1))
        assertDate("01-04-2024", (2024, 4, 1))
    }

    func testTwoDigitYearsGet2000Added() {
        assertDate("01/04/24", (2024, 4, 1))
        assertDate("05/07/99", (2099, 7, 5))  // naive +2000, mirrors Python
        assertDate("01-Apr-24", (2024, 4, 1))
    }

    func testDashedMonthNames() {
        assertDate("01-Apr-2024", (2024, 4, 1))
        assertDate("01-April-2024", (2024, 4, 1)) // full name, first 3 chars decide
        // Unknown month word falls back to January — documented Python quirk.
        assertDate("01-Xyz-2024", (2024, 1, 1))
    }

    func testInvalidInputsReturnNil() {
        assertDate("1 Apr 2024", nil)       // day must be exactly 2 digits
        assertDate("2024-4-1", nil)         // ISO needs zero-padded month/day
        assertDate("01 Apr 2024 extra", nil) // anchored: trailing junk rejected
        assertDate("hello", nil)
        assertDate("", nil)
    }

    func testNoRangeValidationQuirk() {
        // parse_date deliberately does NOT range-check month/day (the callers
        // do). Ground-truthed: Python returns (2024, 13, 32) here too.
        assertDate("32/13/2024", (2024, 13, 32))
    }
}

// MARK: - DateParse generic-row helpers (_gen_row_date / _gen_money)

final class GenRowDateTests: XCTestCase {

    private func assertGen(_ toks: [String], _ expDate: (Int?, Int, Int)?, _ expUsed: Set<Int>,
                           file: StaticString = #filePath, line: UInt = #line) {
        let (date, used) = DateParse.genRowDate(toks)
        switch (date, expDate) {
        case (nil, nil):
            break
        case let (g?, e?):
            XCTAssertTrue(g == e,
                          "genRowDate(\(toks)) date == \(g), expected \(e)",
                          file: file, line: line)
        case let (g, _):
            XCTFail("genRowDate(\(toks)) date == \(String(describing: g)), " +
                    "expected \(String(describing: expDate))",
                    file: file, line: line)
        }
        XCTAssertEqual(used, expUsed, "genRowDate(\(toks)) consumed indices",
                       file: file, line: line)
    }

    func testFullDateTokens() {
        assertGen(["01/04/2024", "Tesco"], (2024, 4, 1), [0])
        assertGen(["2024-04-01", "x"], (2024, 4, 1), [0])
        // First token has month 31 (invalid) — must be skipped in favour of
        // the day-first token that validates.
        assertGen(["12-31-2024", "31-12-2024"], (2024, 12, 31), [1])
        assertGen(["01/04/24", "y"], (2024, 4, 1), [0]) // 2-digit year
    }

    func testSplitDayMonthTokens() {
        assertGen(["01", "Apr"], (nil, 4, 1), [0, 1])
        assertGen(["Apr", "01"], (nil, 4, 1), [0, 1])           // month-first order
        assertGen(["01", "Apr", "2024"], (2024, 4, 1), [0, 1, 2]) // trailing year consumed
        assertGen(["x", "01", "Apr", "2024"], (2024, 4, 1), [1, 2, 3])
        assertGen(["1.", "Apr"], (nil, 4, 1), [0, 1])           // ".," stripped from day
        // Year regex is 20\d\d: a 1999 year token is NOT consumed, and the "05"
        // pair-scan wins ("05 May" → day 5). Ground-truthed against Python.
        assertGen(["05", "May", "1999"], (nil, 5, 5), [0, 1])
        // Day range check is only 1...31 — "31 Feb" passes (no month-length check).
        assertGen(["31", "Feb"], (nil, 2, 31), [0, 1])
    }

    func testNoDateFound() {
        assertGen(["Tesco"], nil, [])
        assertGen([], nil, [])
        assertGen(["99/99/2024"], nil, []) // fails genValid, nothing else to try
    }

    func testGenValidBounds() {
        XCTAssertTrue(DateParse.genValid(1, 1))
        XCTAssertTrue(DateParse.genValid(12, 31))
        XCTAssertFalse(DateParse.genValid(0, 1), "month 0 must be invalid")
        XCTAssertFalse(DateParse.genValid(13, 1), "month 13 must be invalid")
        XCTAssertFalse(DateParse.genValid(1, 0), "day 0 must be invalid")
        XCTAssertFalse(DateParse.genValid(1, 32), "day 32 must be invalid")
    }

    func testGenMoneyStripsSymbolsGroupingAndSuffixes() {
        XCTAssertEqual(DateParse.genMoney("£1,234.56"), 1234.56, accuracy: 1e-9)
        XCTAssertEqual(DateParse.genMoney("-£10.00"), -10.0, accuracy: 1e-9)
        XCTAssertEqual(DateParse.genMoney("1,234.56 CR"), 1234.56, accuracy: 1e-9)
        XCTAssertEqual(DateParse.genMoney("1,234.56cr"), 1234.56, accuracy: 1e-9)
        XCTAssertEqual(DateParse.genMoney("₹1,00,000.00"), 100000.0, accuracy: 1e-9,
                       "INR lakh-grouped amount must parse")
        XCTAssertEqual(DateParse.genMoney("$0.00"), 0.0, accuracy: 1e-9)
        // Swift-side safety net: unparseable → 0.0 (Python would raise, but the
        // recognizer regex gates every call; the Swift `?? 0.0` is deliberate).
        XCTAssertEqual(DateParse.genMoney("abc"), 0.0, accuracy: 1e-9)
    }

    func testGenMoneyRecognizerAcceptsMoneyTokensOnly() {
        let accepted = ["£1,234.56", "-£10.00", "123.45", "1,234.56 CR",
                        "1,234.56cr", "₹1,00,000.00", "$0.00", "0.99 dr"]
        for s in accepted {
            XCTAssertNotNil(DateParse.genMoneyRe.fullmatch(s),
                            "genMoneyRe must accept money token \(s.debugDescription)")
        }
        let rejected = ["1234",        // no decimals
                        "£1,234.5",    // one decimal place
                        "12.345",      // three decimal places
                        "1.234,56",    // European separators
                        "CR", ""]
        for s in rejected {
            XCTAssertNil(DateParse.genMoneyRe.fullmatch(s),
                         "genMoneyRe must reject non-money token \(s.debugDescription)")
        }
    }
}

// MARK: - money() string→Double parser (Txn.swift, _money from formatters.py)

final class MoneyParseTests: XCTestCase {

    private func assertMoney(_ input: String?, _ expected: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(money(input), expected, accuracy: 1e-9,
                       "money(\(String(describing: input)))", file: file, line: line)
    }

    func testEmptyAndNil() {
        assertMoney(nil, 0.0)
        assertMoney("", 0.0)
        assertMoney("   ", 0.0)
    }

    func testCurrencySymbolsStripped() {
        assertMoney("£1,234.56", 1234.56)
        assertMoney("$99", 99.0)
        assertMoney("€0.00", 0.0)
        assertMoney("₹1,23,456.78", 123456.78) // INR lakh grouping
    }

    func testIndianCroreGrouping() {
        assertMoney("₹12,34,56,789.00", 123456789.0)
        assertMoney("1,00,00,000.00", 10000000.0) // 1 crore, no symbol
    }

    func testCRDRSuffixes() {
        assertMoney("1,234.56 CR", 1234.56)
        assertMoney("500 Dr.", 500.0)
        assertMoney("12 CR", 12.0)
        assertMoney("cr", 0.0) // suffix only → nothing left → 0
    }

    func testNegatives() {
        assertMoney("-42.10", -42.10)
        assertMoney("£-5.00", -5.0)
        // Parenthesised negatives are NOT honoured — parens are stripped and
        // the value stays positive (documented Python behaviour).
        assertMoney("(100.00)", 100.0)
    }

    func testGarbageAndMalformed() {
        assertMoney("abc", 0.0)
        assertMoney("1.2.3", 0.0) // two decimal points survive stripping → unparseable
    }

    func testSpaceGrouping() {
        assertMoney("1 234.56", 1234.56) // spaces are non-numeric chars, stripped
    }
}

// MARK: - Categorization (Categories + Classify against real categories.json)

final class CategorizationTests: XCTestCase {
    private var cats: Categories!

    override func setUpWithError() throws {
        cats = try Categories(categoriesJSONPath: TestPaths.categoriesJSON.path)
    }

    private func assertClassify(_ descr: String, credit: Bool,
                                _ expected: (String, String),
                                file: StaticString = #filePath, line: UInt = #line) {
        let got = Classify.classify(descr, isCredit: credit, categories: cats)
        XCTAssertTrue(got == expected,
                      "classify(\(descr.debugDescription), credit: \(credit)) == \(got), " +
                      "expected \(expected)", file: file, line: line)
    }

    private func assertBarclays(_ descr: String, credit: Bool,
                                _ expected: (String, String),
                                file: StaticString = #filePath, line: UInt = #line) {
        let got = Classify.barclaysMerchant(descr, isCredit: credit, categories: cats)
        XCTAssertTrue(got == expected,
                      "barclaysMerchant(\(descr.debugDescription), credit: \(credit)) == \(got), " +
                      "expected \(expected)", file: file, line: line)
    }

    // ---- rule loading -----------------------------------------------------

    func testRuleCountsMatchContractFile() {
        // 51 → 75 on 2026-07-25: US/EU merchant vocabulary added (Walmart,
        // Target, Costco, AT&T, REWE, Apotheke, Deutsche Bahn, …) to fix the
        // "everything falls into Other" complaint on US/EU statements.
        XCTAssertEqual(cats.merchantRules.count, 75,
                       "merchant_map in contract/categories.json has 75 keys")
        // 16 → 19 on 2026-07-25: Subscriptions (before both Entertainment
        // entries), Fees & Charges and Education added.
        XCTAssertEqual(cats.categoryRules.count, 19,
                       "category_rules in contract/categories.json has 19 entries")
    }

    func testMerchantRulesPreserveFileOrder() {
        // Python dict insertion order: "swiggyinstamart" precedes "swiggy" so
        // the longer token wins. A JSON-dictionary loader would scramble this.
        XCTAssertEqual(cats.merchantRules[0].name, "Swiggy Instamart")
        XCTAssertEqual(cats.merchantRules[1].name, "Swiggy")
        assertClassify("SWIGGYINSTAMART ORDER", credit: false, ("Swiggy Instamart", "Groceries"))
        assertClassify("UPI-swiggy@ybl-payment", credit: false, ("Swiggy", "Food & Dining"))
    }

    // ---- keywordCategory --------------------------------------------------

    func testKeywordCategoryOrderSensitivity() {
        // "uber eats" (rule 1, Food & Dining) must beat "uber" (Transport).
        XCTAssertEqual(cats.keywordCategory("UBER EATS X"), "Food & Dining")
        XCTAssertEqual(cats.keywordCategory("UBER X"), "Transport")
        // "amazon prime" (Subscriptions since 2026-07-25) precedes plain
        // "amazon" (Shopping).
        XCTAssertEqual(cats.keywordCategory("AMAZON PRIME VIDEO"), "Subscriptions")
        XCTAssertEqual(cats.keywordCategory("AMAZON PAY BALANCE"), "Shopping")
        XCTAssertEqual(cats.keywordCategory("AMAZON MARKETPLACE"), "Shopping")
    }

    func testKeywordCategoryUnderscoreAndPrefixSemantics() {
        // Underscores are treated as spaces so "tata_power" hits "tata power".
        XCTAssertEqual(cats.keywordCategory("tata_power"), "Utilities")
        // Terms are leading-boundary PREFIX matches: \btesco matches "TESCOS".
        XCTAssertEqual(cats.keywordCategory("TESCOS EXPRESS"), "Groceries")
        // "reimburs" is deliberately a stem.
        XCTAssertEqual(cats.keywordCategory("REIMBURSEMENT Q2"), "Income")
    }

    func testKeywordCategoryRepresentativeBuckets() {
        XCTAssertEqual(cats.keywordCategory("ATM WDL"), "Cash")
        XCTAssertEqual(cats.keywordCategory("faster payment to x"), "Transfers")
        XCTAssertEqual(cats.keywordCategory("refund of fees"), "Income")
    }

    func testKeywordCategoryFallbacks() {
        XCTAssertEqual(cats.keywordCategory("zzz qqq", isCredit: false), "Other",
                       "unknown debit text must fall back to Other")
        XCTAssertEqual(cats.keywordCategory("zzz qqq", isCredit: true), "Income",
                       "unknown credit text must fall back to Income")
    }

    // ---- classify ---------------------------------------------------------

    func testClassifyMerchantMapHits() {
        assertClassify("POS ZOMATO LTD", credit: false, ("Zomato", "Food & Dining"))
        assertClassify("NEFT-AXIS BANK CAR LOAN-123456", credit: false,
                       ("Axis Bank Car Loan", "Investment & Insurance"))
        assertClassify("TATA_POWER BILL", credit: false, ("Tata Power", "Utilities"))
    }

    func testClassifyStripsLeadingSerialAndDate() {
        // "1 04/05/2024 " (row serial + date) is removed before rule matching.
        assertClassify("1 04/05/2024 NETFLIX.COM SUBSCRIPTION", credit: false,
                       ("Netflix", "Subscriptions"))
    }

    func testClassifyPersonishUPITransfer() {
        // Unmatched UPI/IMPS narration with a person-looking payee → Transfers.
        assertClassify("IMPS/John Smith/504403", credit: false, ("John Smith", "Transfers"))
    }

    func testClassifyIncomeDowngradeOnDebits() {
        // Merchant rule says Income, but a DEBIT can't be income:
        // with "transfer" in the text it becomes Transfers, otherwise Other.
        assertClassify("SALARY TRANSFER OUT", credit: false, ("Salary Credit", "Transfers"))
        assertClassify("SALARY REVERSAL", credit: false, ("Salary Credit", "Other"))
        assertClassify("SALARY CREDIT JULY", credit: true, ("Salary Credit", "Income"))
    }

    func testClassifyUnknownFallbacks() {
        assertClassify("XYZZY PLUGH", credit: true, ("XYZZY PLUGH", "Income"))
        assertClassify("XYZZY PLUGH", credit: false, ("XYZZY PLUGH", "Other"))
    }

    // ---- isPersonish ------------------------------------------------------

    func testIsPersonish() {
        XCTAssertTrue(Classify.isPersonish("John Smith"))
        XCTAssertTrue(Classify.isPersonish("JOHN SMITH"))
        XCTAssertTrue(Classify.isPersonish("Ravi K"), "single-initial surname counts")
        XCTAssertFalse(Classify.isPersonish("John"), "one word is not a person")
        XCTAssertFalse(Classify.isPersonish("A B C D"), "four words is not a person")
        XCTAssertFalse(Classify.isPersonish("John Smith Ltd"), "business suffix disqualifies")
        XCTAssertFalse(Classify.isPersonish("Mc Donald Store"), "'store' suffix disqualifies")
        XCTAssertFalse(Classify.isPersonish("John2 Smith"), "digits disqualify")
        XCTAssertFalse(Classify.isPersonish("john smith"), "lowercase words disqualify")
        XCTAssertFalse(Classify.isPersonish(""))
    }

    // ---- barclaysMerchant -------------------------------------------------

    func testBarclaysMerchantExtraction() {
        assertBarclays("Card Payment to Tesco Stores 3297 On 04 Apr", credit: false,
                       ("Tesco Stores 3297", "Groceries"))
        assertBarclays("Direct Debit to British Gas Ref: 12345", credit: false,
                       ("British Gas", "Utilities"))
        assertBarclays("Received From ACME LTD Ref ABC", credit: true,
                       ("ACME LTD", "Income"))
        assertBarclays("Transfer to J SMITH SAVINGS", credit: false,
                       ("J SMITH SAVINGS", "Transfers"))
        assertBarclays("Standing Order to Landlord Properties Ltd", credit: false,
                       ("Landlord Properties Ltd", "Rent"))
    }

    func testBarclaysMerchantIncomeDowngradeAndEmptyFallbacks() {
        // "cashback" keyword says Income, but it's a debit with no "transfer".
        assertBarclays("Payment to Cashback Site", credit: false, ("Cashback Site", "Other"))
        assertBarclays("", credit: true, ("Income", "Income"))
        assertBarclays("", credit: false, ("Other", "Other"))
    }

    func testBarclaysMerchantNameTruncatedTo60() {
        let longName = String(repeating: "A", count: 70)
        let (name, cat) = Classify.barclaysMerchant("Payment to " + longName,
                                                    isCredit: false, categories: cats)
        XCTAssertEqual(name, String(repeating: "A", count: 60),
                       "merchant name must be truncated to 60 chars")
        XCTAssertEqual(cat, "Other")
    }

    // ---- description category hints (feed ingest's category override) -----

    func testExtractCategoryHint() {
        // Two-word hint at the end.
        let (c2, h2) = Describe.extractCategoryHint("ACME LTD Direct Debit")
        XCTAssertEqual(c2, "ACME LTD")
        XCTAssertEqual(h2, "Direct Debit")
        // One-word hint, punctuation stripped.
        let (c1, h1) = Describe.extractCategoryHint("AMZN Refund.")
        XCTAssertEqual(c1, "AMZN")
        XCTAssertEqual(h1, "Refund")
        let (cg, hg) = Describe.extractCategoryHint("TESCO STORES Groceries")
        XCTAssertEqual(cg, "TESCO STORES")
        XCTAssertEqual(hg, "Groceries")
        // No hint → unchanged, nil.
        let (cn, hn) = Describe.extractCategoryHint("PLAIN DESCRIPTION")
        XCTAssertEqual(cn, "PLAIN DESCRIPTION")
        XCTAssertNil(hn)
        // "Card Payment" alone is only 2 tokens — the 2-word path needs 3+.
        let (cc, hc) = Describe.extractCategoryHint("Card Payment")
        XCTAssertEqual(cc, "Card Payment")
        XCTAssertNil(hc)
        let (ce, he) = Describe.extractCategoryHint("")
        XCTAssertEqual(ce, "")
        XCTAssertNil(he)
    }

    func testNormalizeCategory() {
        XCTAssertEqual(Describe.normalizeCategory("groceries"), "Groceries")
        XCTAssertEqual(Describe.normalizeCategory("salary"), "Income")
        XCTAssertEqual(Describe.normalizeCategory("petrol"), "Transport")
        XCTAssertEqual(Describe.normalizeCategory("Subscription"), "Subscriptions")
        // Substring quirk, parity with Python: "neTFLix" contains "tfl" and the
        // Transport check runs before Entertainment.
        XCTAssertEqual(Describe.normalizeCategory("netflix"), "Transport")
        XCTAssertNil(Describe.normalizeCategory("Direct Debit"))
        XCTAssertNil(Describe.normalizeCategory("unknownxyz"))
        XCTAssertNil(Describe.normalizeCategory(""))
        XCTAssertNil(Describe.normalizeCategory(nil))
    }
}

// MARK: - PyKit numeric + string shims

final class PyKitStringTests: XCTestCase {

    func testPyRoundIsBankersRounding() {
        XCTAssertEqual(pyRound(0.5), 0, "Python round(0.5) == 0")
        XCTAssertEqual(pyRound(1.5), 2)
        XCTAssertEqual(pyRound(2.5), 2, "half-to-even, not half-up")
        XCTAssertEqual(pyRound(-0.5), 0)
        XCTAssertEqual(pyRound(-1.5), -2)
        XCTAssertEqual(pyRound(2.4), 2)
        XCTAssertEqual(pyRound(2.6), 3)
    }

    func testPyIntTruncatesTowardZero() {
        XCTAssertEqual(pyInt(1.9), 1)
        XCTAssertEqual(pyInt(-1.9), -1, "Python int() truncates toward zero, not floor")
        XCTAssertEqual(pyInt(-0.99), 0)
        XCTAssertEqual(pyInt(0.0), 0)
    }

    func testPyStrip() {
        XCTAssertEqual("  a b \t\n".pyStrip(), "a b")
        XCTAssertEqual("--a-b--".pyStrip("-"), "a-b")
        XCTAssertEqual(".,x.,".pyStrip(".,"), "x")
        XCTAssertEqual("".pyStrip(), "")
    }

    func testPyTitle() {
        XCTAssertEqual("hello world".pyTitle(), "Hello World")
        XCTAssertEqual("don't".pyTitle(), "Don'T", "Python title() uppercases after apostrophe")
        XCTAssertEqual("h3 2vx".pyTitle(), "H3 2Vx", "letter after digit is a word start")
        XCTAssertEqual("ABC".pyTitle(), "Abc")
    }

    func testPyIsUpper() {
        XCTAssertTrue("ABC".pyIsUpper())
        XCTAssertTrue("AB1".pyIsUpper(), "digits are uncased, don't break isupper")
        XCTAssertFalse("Abc".pyIsUpper())
        XCTAssertFalse("123".pyIsUpper(), "no cased char → False")
        XCTAssertFalse("".pyIsUpper())
    }

    func testPyIsDigit() {
        XCTAssertTrue("123".pyIsDigit())
        XCTAssertFalse("".pyIsDigit())
        XCTAssertFalse("12a".pyIsDigit())
        XCTAssertFalse("1 2".pyIsDigit())
    }

    func testPySplitWhitespace() {
        XCTAssertEqual("a  b\tc".pySplit(), ["a", "b", "c"])
        XCTAssertEqual("".pySplit(), [], "Python ''.split() == []")
        XCTAssertEqual("   ".pySplit(), [], "whitespace-only splits to []")
    }

    func testPySplitLiteralSeparatorKeepsEmpties() {
        XCTAssertEqual("a,,b".pySplit(","), ["a", "", "b"])
        XCTAssertEqual("".pySplit(","), [""], "Python ''.split(',') == ['']")
        XCTAssertEqual("a,b,".pySplit(","), ["a", "b", ""])
    }

    func testPyRSplit() {
        XCTAssertEqual("a b c d".pyRSplit(maxsplit: 2), ["a b", "c", "d"])
        XCTAssertEqual("a  b c".pyRSplit(maxsplit: 1), ["a  b", "c"],
                       "left remainder keeps its internal whitespace")
        XCTAssertEqual("abc".pyRSplit(maxsplit: 2), ["abc"], "no whitespace → whole string")
        XCTAssertEqual("a b".pyRSplit(maxsplit: 3), ["a", "b"],
                       "maxsplit larger than available splits")
    }

    func testPyRSplitEdgeWhitespaceMatchesPython() {
        // Python's whitespace rsplit never yields empty parts:
        // ' a b'.rsplit(maxsplit=5) == ['a', 'b'] and 'a b '.rsplit(maxsplit=2)
        // == ['a', 'b'] (verified against CPython).
        XCTAssertEqual(" a b".pyRSplit(maxsplit: 5), ["a", "b"],
                       "leading whitespace must not produce an empty leading part")
        XCTAssertEqual("a b ".pyRSplit(maxsplit: 2), ["a", "b"],
                       "trailing whitespace must not produce an empty trailing part")
    }

    func testPySplitLines() {
        XCTAssertEqual("a\n\nb\r\nc\rd".pySplitLines(), ["a", "", "b", "c", "d"],
                       "\\n, \\r\\n and \\r are all single separators")
        XCTAssertEqual("a\n".pySplitLines(), ["a"], "no phantom empty final line")
        XCTAssertEqual("".pySplitLines(), [])
        XCTAssertEqual("\n".pySplitLines(), [""])
    }

    func testPyPrefix() {
        XCTAssertEqual("hello".pyPrefix(3), "hel")
        XCTAssertEqual("hi".pyPrefix(10), "hi", "n beyond length is safe")
        XCTAssertEqual("hi".pyPrefix(0), "")
    }

    func testPyContainsEmptySubstring() {
        // Python: "" in s is always True; Swift's contains("") is false, hence the shim.
        XCTAssertTrue("abc".pyContains(""))
        XCTAssertTrue("".pyContains(""))
        XCTAssertTrue("abc".pyContains("b"))
        XCTAssertFalse("abc".pyContains("x"))
    }
}

// MARK: - PyRegex (re-alike)

final class PyRegexTests: XCTestCase {

    func testSearchVsMatchAnchoring() {
        XCTAssertNil(PyRegex("\\d+").match("ab12"), "match is anchored at the start")
        let m = PyRegex("\\d+").search("ab12")
        XCTAssertEqual(m?.group(), "12", "search finds a match anywhere")
        XCTAssertEqual(m?.start, 2)
        XCTAssertEqual(m?.end, 4)
    }

    func testFullmatchMustConsumeWholeString() {
        XCTAssertNotNil(PyRegex("\\d+").fullmatch("123"))
        XCTAssertNil(PyRegex("\\d+").fullmatch("123a"))
        XCTAssertNil(PyRegex("\\d+").fullmatch(""))
    }

    func testNamedGroupsPythonSyntax() {
        // (?P<name>...) must be accepted (translated to ICU (?<name>...)).
        let m = PyRegex("(?P<y>\\d{4})-(?P<m>\\d{2})").search("on 2024-05 maybe")
        XCTAssertEqual(m?.group("y"), "2024")
        XCTAssertEqual(m?.group("m"), "05")
        XCTAssertEqual(m?.groupDict(["y", "m"]), ["y": "2024", "m": "05"])
    }

    func testGroupsWithNonParticipatingAlternative() {
        let g = PyRegex("(a)|(b)").search("b")?.groups()
        XCTAssertEqual(g, [nil, "b"], "non-participating group must be nil, like Python")
    }

    func testSubLiteralByDefault() {
        // Default replacement is literal — "$1" must NOT be a backreference.
        XCTAssertEqual(PyRegex("\\d+").sub("[$1]", "a12b"), "a[$1]b")
        XCTAssertEqual(PyRegex("a+").sub("-", "baaad"), "b-d")
    }

    func testSubTemplateMode() {
        XCTAssertEqual(PyRegex("(\\d+)").sub("<$1>", "a12b", template: true), "a<12>b")
    }

    func testSplit() {
        XCTAssertEqual(PyRegex("\\s+").split("a b  c"), ["a", "b", "c"])
        XCTAssertEqual(PyRegex("\\s+").split("a b c", maxsplit: 1), ["a", "b c"])
        XCTAssertEqual(PyRegex(",").split("a,b,"), ["a", "b", ""],
                       "trailing separator yields trailing empty, like re.split")
        XCTAssertEqual(PyRegex("x").split("abc"), ["abc"], "no match → single part")
    }

    func testFindall() {
        XCTAssertEqual(PyRegex("\\d+").findall("a1 b22"), ["1", "22"],
                       "zero-group pattern returns whole matches")
        XCTAssertEqual(PyRegex("([A-Za-z]+)\\d").findall("ab1 cd2"), ["ab", "cd"],
                       "one-group pattern returns group 1")
        XCTAssertEqual(PyRegex("z").findall("abc"), [])
    }

    func testFinditerAndCount() {
        let ms = PyRegex("o").finditer("foo")
        XCTAssertEqual(ms.count, 2)
        XCTAssertEqual(ms.map(\.start), [1, 2])
        XCTAssertEqual(PyRegex("an").count("banana"), 2)
        XCTAssertEqual(PyRegex("q").count("banana"), 0)
    }

    func testEscapeProducesLiteralPattern() {
        let esc = PyRegex.escape("a.b(c)")
        XCTAssertNotNil(PyRegex(esc).fullmatch("a.b(c)"),
                        "escaped pattern must match the literal text")
        XCTAssertNil(PyRegex(esc).search("aXb(c)"),
                     "escaped '.' must not act as a wildcard")
    }

    func testIgnoreCaseOption() {
        XCTAssertNotNil(PyRegex("tesco", ignoreCase: true).search("TESCO STORE"))
        XCTAssertNil(PyRegex("tesco").search("TESCO STORE"))
    }

    func testWordBoundarySemantics() {
        // \b behaviour the category rules depend on: matches after punctuation
        // and start-of-string, never mid-word.
        XCTAssertNotNil(PyRegex("\\btesco", ignoreCase: true).search("- Tesco Stores"))
        XCTAssertNotNil(PyRegex("\\btesco", ignoreCase: true).search("(TESCO)"))
        XCTAssertNil(PyRegex("\\btesco", ignoreCase: true).search("xtesco"))
    }
}
