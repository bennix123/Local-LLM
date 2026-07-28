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

    /// Penny's canonical spend taxonomy — the closed set the model must choose from.
    public static let canonicalCategories = [
        "Groceries", "Food & Dining", "Transport", "Shopping", "Subscriptions",
        "Entertainment", "Healthcare", "Utilities", "Rent", "Cash", "Fees & Charges",
        "Education", "Income", "Transfers", "Investment & Insurance", "Payments", "Other",
    ]

    let apiKey: String
    let model: String
    let session: URLSession

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
        guard !apiKey.isEmpty else { throw ClaudeCategorizerError.missingKey }
        let merchants = Array(NSOrderedSet(array: descriptions)) as? [String] ?? descriptions
        guard !merchants.isEmpty else { return [] }

        // "Other" must always be an allowed escape hatch.
        var cats = allowedCategories
        if !cats.contains("Other") { cats.append("Other") }

        let body = requestBody(merchants: merchants, categories: cats)
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeCategorizerError.badResponse("no HTTP response")
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard http.statusCode == 200 else {
            throw ClaudeCategorizerError.http(status: http.statusCode, body: text)
        }

        let parsed = try parseResults(data: data, merchants: merchants, allowed: Set(cats))
        // Fill any omissions so the caller gets one row per input.
        let byName = Dictionary(parsed.map { ($0.merchant, $0) }, uniquingKeysWith: { a, _ in a })
        return merchants.map { byName[$0] ?? ClaudeCategorization(merchant: $0, category: "Other", confidence: 0) }
    }

    // MARK: - Request

    private func requestBody(merchants: [String], categories: [String]) -> [String: Any] {
        let list = merchants.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let system = """
        You categorize bank- and card-statement merchant descriptors into a fixed \
        set of personal-finance categories. Use the merchant's real-world business \
        type, inferring from brand names, card-acquirer prefixes (e.g. DOJO*, TST-, \
        TEYA*), and location hints. Assign exactly one category per descriptor from \
        the allowed list. Use "Other" only when you genuinely cannot tell. Return a \
        confidence from 0 to 1 (1 = certain).

        Allowed categories: \(categories.joined(separator: ", ")).
        """
        // Structured-outputs schema: category is enum-locked to the taxonomy.
        let itemSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "merchant": ["type": "string"],
                "category": ["type": "string", "enum": categories],
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
            "max_tokens": max(1024, min(8192, merchants.count * 80 + 512)),
            "system": system,
            "output_config": ["format": ["type": "json_schema", "schema": schema]],
            "messages": [[
                "role": "user",
                "content": "Categorize these \(merchants.count) merchant descriptors, echoing each `merchant` back verbatim:\n\(list)",
            ]],
        ]
    }

    // MARK: - Response

    private func parseResults(data: Data, merchants: [String], allowed: Set<String>)
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
            // Guard against an off-taxonomy label leaking through.
            let cat = allowed.contains(c) ? c : "Other"
            return ClaudeCategorization(merchant: m, category: cat, confidence: max(0, min(1, conf)))
        }
    }
}
