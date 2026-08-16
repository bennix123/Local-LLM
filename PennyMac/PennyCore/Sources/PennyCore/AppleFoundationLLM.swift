import Foundation

// AppleFoundationLLM — the on-device Apple system model path (FoundationModels).
//
// This is Penny's implementation of WWDC26-326 "Integrate on-device AI models
// into your app using Core AI": we run the built-in Apple system model through
// `LanguageModelSession`, using `@Generable` structured output so categorization
// yields validated Swift structs (no fragile JSON to truncate) and chat answers
// stream from the same on-device model. No weights to download, no cloud.
//
// PennyLLM prefers this path whenever Apple Intelligence is available on the
// machine, and falls back to the bundled MLX model otherwise — so nothing here
// is required for Penny to work; it's a zero-download upgrade when present.
//
// Everything is gated `@available(macOS 26.0, *)`; PennyLLM only reaches it from
// inside `if #available(macOS 26.0, *)`, so the package still targets macOS 14.

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
enum AppleFoundationLLM {

    /// Whether the Apple system model is ready to answer *right now* — i.e. the
    /// device is eligible, Apple Intelligence is on, and the model is downloaded.
    /// PennyLLM checks this before choosing this path over MLX.
    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    // MARK: - Categorization (structured output)

    /// One merchant verdict the model must produce. `@Generable` forces the model
    /// to emit this shape directly — the framework validates it, so we never parse
    /// (or lose to a truncated) JSON array the way the raw-text MLX path can.
    @Generable
    struct Verdict: Equatable {
        @Guide(description: "The merchant descriptor copied back EXACTLY as it was given, character for character.")
        let merchant: String
        @Guide(description: "A 1 to 3 word Title Case category naming the merchant's real-world business type, e.g. Groceries, Transport, Fees, Transfers, Dining.")
        let category: String
    }

    @Generable
    struct VerdictList: Equatable {
        @Guide(description: "One verdict per input descriptor, in the same order they were given.")
        let verdicts: [Verdict]
    }

    /// Categorize a small batch of descriptors with the Apple system model.
    /// Mirrors `PennyLLM.categorizeMerchants`' contract (dynamic taxonomy, optional
    /// "no Other" guarantee) and reuses PennyLLM's descriptor-matching + category
    /// normalization so both engines return interchangeable results.
    static func categorize(_ descriptors: [String],
                           seedCategories: [String],
                           forbidOther: Bool) async throws -> [MerchantCategory] {
        guard !descriptors.isEmpty else { return [] }

        let otherRule = forbidOther ? """
            NEVER use "Other", "Unknown", "Uncategorized", "Misc" or "N/A" — every \
            descriptor MUST get a concrete category. Only when the payee is a person \
            or cannot be identified at all, use "Transfers". Metro / rail / bus / \
            transit is "Transport". Card-network, forex markup, ATM or bank charges \
            are "Fees & Charges". If still unsure, pick the single closest real \
            category — never "Other".
            """ : """
            Use "Other" only when a descriptor is truly unguessable.
            """
        let instructions = """
            You categorize bank- and card-statement transactions for a \
            personal-finance app. Classify by WHO was paid, never by HOW the money \
            moved: UPI / IMPS / NEFT / cards are payment methods, not categories. \
            Priority: 1) the merchant or payee name — including names inside UPI \
            VPA handles ("BurgerKingIndia@…" → Burger King → Food & Dining, \
            "billdeskpg.appleservices@…" → Apple → Subscriptions) and \
            card-acquirer prefixes (DOJO*, TST-, SQ*, IZ*, TEYA*); 2) the rest of \
            the description and location hints; 3) the payment method only when \
            nothing identifies the payee. "Transfers" is ONLY for money sent to an \
            individual or own-account moves — a recognizable business is NEVER \
            "Transfers". Prefer one of the KNOWN CATEGORIES when it fits; otherwise \
            coin a concise 1 to 3 word Title Case category describing the business \
            type. \(otherRule) Echo each merchant string back exactly, one verdict \
            per descriptor, in the given order.

            KNOWN CATEGORIES: \(seedCategories.joined(separator: ", ")).
            """

        let list = descriptors.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        let prompt = "Categorize these \(descriptors.count) merchant descriptors:\n\(list)"

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt,
            generating: VerdictList.self,
            options: GenerationOptions(temperature: 0))
        let verdicts = response.content.verdicts

        // Reconcile the model's echoes back to the original spellings, exactly like
        // the MLX path (case/punctuation-insensitive, with positional fallback).
        var originals: [String: String] = [:]
        for d in descriptors where originals[PennyLLM.matchKey(d)] == nil {
            originals[PennyLLM.matchKey(d)] = d
        }
        var out: [MerchantCategory] = []
        for (i, v) in verdicts.enumerated() {
            let positional = verdicts.count == descriptors.count ? descriptors[i] : nil
            guard let merchant = originals[PennyLLM.matchKey(v.merchant)] ?? positional else { continue }
            let category = PennyLLM.normalizeCategory(v.category, seeds: seedCategories)
            // The system model gives no calibrated score; it commits to a label, so
            // we tag a high-but-not-certain confidence (well above accept thresholds).
            out.append(MerchantCategory(merchant: merchant, category: category, confidence: 0.9))
        }
        return out
    }

    // MARK: - Issuer detection

    /// Name the institution that issued a statement, on-device. Mirrors
    /// `PennyLLM.detectIssuer`' contract: returns the bare common name, or nil for
    /// an empty / "UNKNOWN" / implausible answer (reusing PennyLLM.cleanIssuer so
    /// both engines normalize identically).
    static func detectIssuer(from statementText: String) async throws -> String? {
        let head = String(statementText.prefix(2_000))
        let instructions = """
            You identify the financial institution that issued a bank or credit-card \
            statement. Reply with ONLY the institution's common name — for example \
            "American Express", "Monzo", "Barclays", "NatWest". No account type, no \
            extra words, no punctuation, no quotes, no explanation. If you genuinely \
            cannot tell, reply exactly UNKNOWN.
            """
        let prompt = "STATEMENT (header text):\n\(head)\n\nInstitution name:"
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt,
            options: GenerationOptions(temperature: 0, maximumResponseTokens: 16))
        return PennyLLM.cleanIssuer(response.content)
    }

    // MARK: - Header facts (structured output)

    /// The header facts the model reads off a statement. Empty strings mean "not
    /// printed" — mapped to nil in `extractFacts`. `@Generable` so the framework
    /// validates the shape (no JSON to truncate), same as `Verdict`.
    @Generable
    struct Facts: Equatable {
        @Guide(description: "The full name of the person the statement is prepared for, or the account holder, exactly as printed on the statement. Empty string if the header does not clearly show a name.")
        let cardholder: String
        @Guide(description: "The statement date or closing date printed in the statement header, exactly as printed. This is NOT the payment due date and NOT a transaction date. Empty string if the header does not clearly show one.")
        let statementDate: String
    }

    /// Read header facts (cardholder, statement date) off a statement on-device,
    /// generalizing to any layout. Mirrors `PennyLLM.extractStatementFacts`' contract
    /// (blank fields → nil). Returns raw strings; the app validates/normalizes them.
    static func extractFacts(from statementText: String) async throws -> StatementFacts {
        let head = String(statementText.prefix(2_500))
        let instructions = """
            You read header facts off a bank or credit-card statement — the name it \
            is prepared for and the statement (closing) date. Copy values EXACTLY as \
            printed. Never return the payment due date or a transaction date as the \
            statement date. If the header does not clearly show a field, return an \
            empty string for it. Do not guess.
            """
        let prompt = "STATEMENT (header text):\n\(head)"
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt,
            generating: Facts.self,
            options: GenerationOptions(temperature: 0))
        func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t.isEmpty || t.caseInsensitiveCompare("null") == .orderedSame) ? nil : t
        }
        return StatementFacts(cardholder: clean(response.content.cardholder),
                              statementDate: clean(response.content.statementDate))
    }

    // MARK: - Structured transaction extraction

    /// One extracted row. All amounts are strings ("" when absent) so guided
    /// generation stays on the same shape family as `Verdict`; PennyLLM parses the
    /// numbers. The model only reads rows out — every figure is recomputed in Swift.
    @Generable
    struct Row: Equatable {
        @Guide(description: "The transaction date exactly as printed on the statement.")
        let date: String
        @Guide(description: "The merchant or description text for the transaction.")
        let description: String
        @Guide(description: "Money out (debit) as a plain number with no currency symbol or thousands separators, or an empty string if there is none.")
        let debit: String
        @Guide(description: "Money in (credit) as a plain number with no currency symbol or thousands separators, or an empty string if there is none.")
        let credit: String
        @Guide(description: "The running balance as a plain number with no currency symbol or thousands separators, or an empty string if absent.")
        let balance: String
    }

    @Generable
    struct RowList: Equatable {
        @Guide(description: "Every transaction on the statement, in the order it appears.")
        let rows: [Row]
    }

    /// Fallback structured extraction on the Apple system model. The deterministic
    /// parser is Penny's primary path; this only runs when a caller needs the model
    /// to read rows out of text the parser couldn't structure.
    static func extractTransactions(from statementText: String, maxTokens: Int) async throws -> [Transaction] {
        let clipped = String(statementText.prefix(16_000))
        let instructions = """
            You extract structured data from bank statements. Return every transaction \
            in order. For each: the date as printed, the description, and the debit \
            (money out), credit (money in) and balance as plain numbers — no currency \
            symbols, no thousands separators. Use an empty string when a value is absent.
            """
        let prompt = "BANK STATEMENT TEXT:\n\(clipped)"
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt,
            generating: RowList.self,
            options: GenerationOptions(temperature: 0, maximumResponseTokens: maxTokens))
        return response.content.rows.map { r in
            Transaction(date: r.date, description: r.description,
                        debit: Self.number(r.debit), credit: Self.number(r.credit),
                        balance: Self.number(r.balance))
        }
    }

    /// Parse a model-emitted amount string ("1,234.50", "₹1,00,000", "") to a Double,
    /// keeping digits, dot and minus — nil for empty/unparseable, matching the MLX path.
    private static func number(_ s: String) -> Double? {
        let cleaned = s.filter { $0.isNumber || $0 == "." || $0 == "-" }
        return cleaned.isEmpty ? nil : Double(cleaned)
    }

    // MARK: - Chat

    /// One grounded answer over one statement from the Apple system model, **streamed
    /// token-by-token** through `onToken` for immediate time-to-first-token, and
    /// returning the full text. `ResponseStream<String>` yields cumulative snapshots,
    /// so we forward only the newly-appended suffix each tick.
    ///
    /// Fallback contract: it throws ONLY when nothing was emitted (an empty-stream
    /// failure), so PennyLLM can cleanly fall back to MLX. Once any text has streamed
    /// it commits to this answer — a mid-stream error returns the partial rather than
    /// failing, so the UI never double-answers.
    static func answer(question: String, statementText: String, maxTokens: Int,
                       onToken: @Sendable (String) -> Void) async throws -> String {
        let clipped = String(statementText.prefix(12_000))
        let prompt = """
            BANK STATEMENT TEXT:
            \(clipped)

            QUESTION: \(question)
            """
        let session = LanguageModelSession(instructions: PennyLLM.systemPrompt)
        let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: maxTokens)
        var shown = ""
        do {
            for try await snapshot in session.streamResponse(to: prompt, options: options) {
                let full = snapshot.content                    // cumulative text so far
                guard full.count > shown.count else { continue }
                onToken(String(full.suffix(full.count - shown.count)))
                shown = full
            }
        } catch {
            if shown.isEmpty { throw error }                   // nothing streamed → caller falls back to MLX
            // otherwise keep the partial already shown (never fail after streaming)
        }
        return shown
    }
}
#endif
