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
            descriptor MUST get a concrete category. Money sent to or received from a \
            person, or a UPI / IMPS / NEFT / RTGS / bank transfer, or a "name@bank" UPI \
            handle, is "Transfers". Metro / rail / bus / transit is "Transport". \
            Card-network, forex markup, interest, ATM or bank charges are "Fees". \
            If still unsure, pick the single closest real category — never "Other".
            """ : """
            Use "Other" only when a descriptor is truly unguessable.
            """
        let instructions = """
            You categorize bank- and card-statement merchant descriptors for a \
            personal-finance app. Judge each merchant's real-world business type from \
            brand names, card-acquirer prefixes (DOJO*, TST-, SQ*, IZ*, TEYA*) and \
            location hints. Prefer one of the KNOWN CATEGORIES when it fits; otherwise \
            coin a concise 1 to 3 word Title Case category describing the business type. \
            \(otherRule) Echo each merchant string back exactly, one verdict per \
            descriptor, in the given order.

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

    // MARK: - Chat

    /// One grounded answer over one statement from the Apple system model.
    /// Non-streaming: the whole answer returns at once, so a mid-generation failure
    /// leaves nothing half-shown and PennyLLM can cleanly fall back to MLX.
    static func answer(question: String, statementText: String, maxTokens: Int) async throws -> String {
        let clipped = String(statementText.prefix(12_000))
        let prompt = """
            BANK STATEMENT TEXT:
            \(clipped)

            QUESTION: \(question)
            """
        let session = LanguageModelSession(instructions: PennyLLM.systemPrompt)
        let response = try await session.respond(
            to: prompt,
            options: GenerationOptions(temperature: 0.3, maximumResponseTokens: maxTokens))
        return response.content
    }
}
#endif
