// ClaudeCategorizer — the AI fallback for merchant categorization (Engine v2, Step 3).
//
// The deterministic engine (categories.json + Classify) resolves ~95% of
// merchants. The long-tail "Other" rows — ambiguous single-token or obscure
// merchants no keyword can safely match — are handed to Claude here.
//
// It calls the Anthropic Messages API over raw HTTPS (there is no Swift SDK),
// constrains the response with structured outputs (a JSON schema whose category
// field is enum-locked to Penny's taxonomy), and returns a confidence per
// merchant so the caller can apply the spec's thresholds:
//   ≥ 0.90 accept · 0.70–0.89 accept + log · < 0.70 keep "Other".
//
// This is OPTIONAL and NETWORK-BOUND — the deterministic ingest never calls it,
// so the offline contract and the 15-fixture conformance suite are untouched.
// The API key is injected by the caller (Keychain/settings in the app, the
// ANTHROPIC_API_KEY env var in the CLI); it is never stored here.
import Foundation

public struct ClaudeCategorization: Sendable, Equatable {
    public let merchant: String     // the descriptor we asked about
    public let category: String     // one of `allowedCategories`
    public let confidence: Double   // 0…1
    public init(merchant: String, category: String, confidence: Double) {
        self.merchant = merchant; self.category = category; self.confidence = confidence
    }
}

public enum ClaudeCategorizerError: Error, LocalizedError {
    case missingKey
    case http(status: Int, body: String)
    case refused(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey: return "No Anthropic API key was provided."
        case .http(let s, let b): return "Anthropic API HTTP \(s): \(b.prefix(300))"
        case .refused(let r): return "The model declined the request (\(r))."
        case .badResponse(let d): return "Could not parse the model response: \(d)"
        }
    }
}

public final class ClaudeCategorizer {

    /// Penny's canonical taxonomy — the seed set offered to the model (and the
    /// closed set in enum-locked mode). Merchant-type buckets first, then money
    /// movement. "Transfers" is for genuine person-to-person/self transfers
    /// only — never a catch-all for UPI/IMPS/NEFT rails (user directive).
    public static let canonicalCategories = [
        "Food & Dining", "Groceries", "Shopping", "Transport", "Fuel",
        "Utilities", "Healthcare", "Personal Care", "Entertainment",
        "Subscriptions", "Education", "Rent", "Investment", "Insurance",
        "Loan Repayment", "Government", "Taxes", "ATM Withdrawal",
        "Cash Deposit", "Fees & Charges", "Payments", "Income", "Salary",
        "Interest", "Refund", "Transfers", "Other",
    ]

    let apiKey: String
    let model: String
    let session: URLSession

    /// Byte size of the last request body sent to the API. The app reads this to
    /// honestly report "data sent out" (its privacy panel). 0 until a call runs.
    public private(set) var lastRequestByteCount = 0

    /// `model` defaults to Opus 4.8. For this classification task Haiku 4.5
    /// (`claude-haiku-4-5`) is far cheaper and plenty capable — pass it explicitly
    /// to switch.
    public init(apiKey: String, model: String = "claude-opus-4-8",
                session: URLSession = .shared) {
        self.apiKey = apiKey; self.model = model; self.session = session
    }

    /// Classify each descriptor into exactly one `allowedCategories` value, with a
    /// confidence. One batched request for the whole list. Any descriptor the model
    /// omits is returned as ("Other", 0.0) so the caller always gets full coverage.
    public func categorize(descriptions: [String],
                           allowedCategories: [String] = canonicalCategories)
    async throws -> [ClaudeCategorization] {
        try await run(descriptions: descriptions, categories: allowedCategories, enumLocked: true)
    }

    /// Like `categorize`, but with a DYNAMIC taxonomy: `seedCategories` are offered
    /// as known choices and the model may coin a NEW concise category name (1–3
    /// words, Title Case, e.g. "Pet Care") when none fits — the category field is a
    /// free string, not enum-locked. Callers should normalize/snap the returned
    /// names (the app uses `PennyLLM.normalizeCategory`) before applying them.
    ///
    /// `locationContext` — an optional sentence naming the issuing bank and its
    /// country/currency (see `CategoryMopup.DescriptorGroup.locationContext`).
    /// Appended to the system prompt so the model resolves region-specific
    /// merchants (local grocery chains, transit systems, wallets) correctly.
    public func dynamicCategorize(descriptions: [String],
                                  seedCategories: [String] = canonicalCategories,
                                  locationContext: String? = nil)
    async throws -> [ClaudeCategorization] {
        try await run(descriptions: descriptions, categories: seedCategories,
                      enumLocked: false, locationContext: locationContext)
    }

    private func run(descriptions: [String], categories: [String], enumLocked: Bool,
                     locationContext: String? = nil)
    async throws -> [ClaudeCategorization] {
        guard !apiKey.isEmpty else { throw ClaudeCategorizerError.missingKey }
        let merchants = Array(NSOrderedSet(array: descriptions)) as? [String] ?? descriptions
        guard !merchants.isEmpty else { return [] }

        // "Other" must always be an allowed escape hatch.
        var cats = categories
        if !cats.contains("Other") { cats.append("Other") }

        let body = requestBody(merchants: merchants, categories: cats,
                               enumLocked: enumLocked, locationContext: locationContext)
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        lastRequestByteCount = req.httpBody?.count ?? 0
        req.timeoutInterval = 60

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeCategorizerError.badResponse("no HTTP response")
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard http.statusCode == 200 else {
            throw ClaudeCategorizerError.http(status: http.statusCode, body: text)
        }

        let parsed = try parseResults(data: data, merchants: merchants,
                                      allowed: enumLocked ? Set(cats) : nil)
        // Fill any omissions so the caller gets one row per input.
        let byName = Dictionary(parsed.map { ($0.merchant, $0) }, uniquingKeysWith: { a, _ in a })
        return merchants.map { byName[$0] ?? ClaudeCategorization(merchant: $0, category: "Other", confidence: 0) }
    }

    // MARK: - Request

    private func requestBody(merchants: [String], categories: [String],
                             enumLocked: Bool, locationContext: String? = nil) -> [String: Any] {
        let list = merchants.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        // Merchant-first doctrine (user directive): the category comes from WHO
        // was paid, never from HOW the money moved. UPI/IMPS/NEFT/card are
        // payment methods; labeling them "Transfers" was the old failure mode.
        let doctrine = """
        Classify by WHO was paid, never by HOW the money moved. UPI, IMPS, NEFT, \
        RTGS, card networks and wallets are payment methods, not categories. \
        Work in this priority order: \
        1) the merchant or payee name — including names encoded in UPI VPA \
        handles ("billdeskpg.appleservices@…" → Apple → Subscriptions; \
        "BurgerKingIndia@…" → Burger King → Food & Dining; "airtelpayments@…" → \
        Airtel → Utilities; "zerodha…" → Zerodha → Investment; "paytm metro" → \
        Transport) and card-acquirer prefixes (DOJO*, TST-, SQ*, IZ*, TEYA*); \
        2) the rest of the description (shop/clinic/school/fuel-pump wording, \
        location hints); \
        3) the payment method, ONLY when nothing identifies the payee.

        Use "Transfers" ONLY for genuine person-to-person or self transfers: \
        money sent to an individual by name, own-account moves, or a personal \
        UPI handle with no business identity. A recognizable business or \
        merchant is NEVER "Transfers", whatever the payment rail.
        """
        var system = enumLocked ? """
        You categorize bank- and card-statement transactions into a fixed set of \
        personal-finance categories.

        \(doctrine)

        Assign exactly one category per descriptor from the allowed list. Use \
        "Other" only when you genuinely cannot tell. Return a confidence from \
        0 to 1 (1 = certain).

        Allowed categories: \(categories.joined(separator: ", ")).
        """ : """
        You categorize bank- and card-statement transactions for a \
        personal-finance app.

        \(doctrine)

        Prefer one of the KNOWN CATEGORIES when it fits; if none fits, coin a \
        NEW concise category name — 1 to 3 words, Title Case, like "Pet Care" \
        or "Home Improvement" — describing the payee's business type. Use \
        "Other" only when you genuinely cannot tell. Return a confidence from \
        0 to 1 (1 = certain).

        Known categories: \(categories.joined(separator: ", ")).
        """
        if let locationContext, !locationContext.isEmpty {
            system += "\n\n" + locationContext
        }
        // Structured-outputs schema: category is enum-locked to the taxonomy in
        // fixed mode, a free string in dynamic mode (the model may coin names).
        var categoryField: [String: Any] = ["type": "string"]
        if enumLocked { categoryField["enum"] = categories }
        let itemSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "merchant": ["type": "string"],
                "category": categoryField,
                "confidence": ["type": "number"],
            ],
            "required": ["merchant", "category", "confidence"],
            "additionalProperties": false,
        ]
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["results": ["type": "array", "items": itemSchema]],
            "required": ["results"],
            "additionalProperties": false,
        ]
        return [
            "model": model,
            // Headroom for models that prepend a reasoning block (Sonnet 5)
            // before the JSON text — a truncated response parse-fails and
            // silently costs the whole batch.
            "max_tokens": max(1024, min(8192, merchants.count * 100 + 1024)),
            "system": system,
            "output_config": ["format": ["type": "json_schema", "schema": schema]],
            "messages": [[
                "role": "user",
                "content": "Categorize these \(merchants.count) merchant descriptors, echoing each `merchant` back verbatim:\n\(list)",
            ]],
        ]
    }

    // MARK: - Response

    /// `allowed == nil` means dynamic mode: any category string is accepted.
    private func parseResults(data: Data, merchants: [String], allowed: Set<String>?)
    throws -> [ClaudeCategorization] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeCategorizerError.badResponse("top-level not an object")
        }
        if let stop = obj["stop_reason"] as? String, stop == "refusal" {
            throw ClaudeCategorizerError.refused((obj["stop_details"] as? [String: Any])?["category"] as? String ?? "refusal")
        }
        guard let content = obj["content"] as? [[String: Any]],
              let jsonText = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let inner = jsonText.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: inner) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else {
            throw ClaudeCategorizerError.badResponse("missing content[].text JSON with `results`")
        }
        return results.compactMap { r in
            guard let m = r["merchant"] as? String, let c = r["category"] as? String else { return nil }
            let conf = (r["confidence"] as? NSNumber)?.doubleValue ?? 0
            // In enum-locked mode, guard against an off-taxonomy label leaking through.
            let cat = (allowed == nil || allowed!.contains(c)) ? c : "Other"
            return ClaudeCategorization(merchant: m, category: cat, confidence: max(0, min(1, conf)))
        }
    }
}
