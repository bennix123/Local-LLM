// ClaudeStatementExtractor — the scanned-statement fallback.
//
// Digital PDFs are parsed deterministically from positioned words (PDFTextExtractor
// → bank parsers). A SCANNED / image-only PDF has no text layer, so there is nothing
// deterministic to read. The app OCRs the pages (Apple Vision) and hands the recognised
// text here; this reconstructs canonical `TxnRow`s via the Anthropic Messages API with
// structured outputs (a JSON schema locking dates to YYYY-MM-DD, amounts to numbers, and
// the category to Penny's taxonomy).
//
// It is a FALLBACK for the no-text-layer case only — never on the deterministic path, so
// the offline contract and conformance are untouched. Pages are processed in bounded
// chunks so each request stays small and reliable, then merged. Amounts are LLM-read, so
// results carry a confidence and should be shown as "AI-extracted (review recommended)".
import Foundation

public struct ExtractedStatement: Sendable {
    public let bank: String?
    public let currency: String
    public let rows: [TxnRow]
    public let confidence: Double   // 0…1, averaged across pages
    public init(bank: String?, currency: String, rows: [TxnRow], confidence: Double) {
        self.bank = bank; self.currency = currency; self.rows = rows; self.confidence = confidence
    }
}

public final class ClaudeStatementExtractor {

    let apiKey: String
    let model: String
    let session: URLSession

    /// Total request-body bytes sent across all page chunks of the last
    /// `extract(pages:)` call — the app reads this to honestly report "data sent
    /// out". Reset at the start of each `extract`.
    public private(set) var lastRequestByteCount = 0

    /// Accuracy matters for extraction, so the default is Opus 4.8. The key is
    /// injected (Keychain in the app; ANTHROPIC_API_KEY in the CLI) — never stored.
    public init(apiKey: String, model: String = "claude-opus-4-8", session: URLSession = .shared) {
        self.apiKey = apiKey; self.model = model; self.session = session
    }

    /// Extract transactions from OCR'd page texts. Pages are grouped so each request
    /// covers ≤ `pagesPerRequest` pages; rows are concatenated in document order and
    /// re-sequenced. `hintCurrency` seeds the currency when the statement doesn't name one.
    public func extract(pages: [String], hintCurrency: String? = nil,
                        pagesPerRequest: Int = 2) async throws -> ExtractedStatement {
        guard !apiKey.isEmpty else { throw ClaudeCategorizerError.missingKey }
        lastRequestByteCount = 0
        let nonEmpty = pages.enumerated().filter { !$0.element.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !nonEmpty.isEmpty else { return ExtractedStatement(bank: nil, currency: hintCurrency ?? "", rows: [], confidence: 0) }

        var allRows: [TxnRow] = []
        var confidences: [Double] = []
        var bank: String? = nil
        var currency = hintCurrency ?? ""

        var i = 0
        while i < nonEmpty.count {
            let chunk = nonEmpty[i..<min(i + pagesPerRequest, nonEmpty.count)].map(\.element)
            let page = await extractChunk(chunk.joined(separator: "\n----- page break -----\n"),
                                          currencyHint: currency)
            if bank == nil, let b = page.bank, !b.isEmpty { bank = b }
            if currency.isEmpty, !page.currency.isEmpty { currency = page.currency }
            allRows.append(contentsOf: page.rows)
            if page.confidence > 0 { confidences.append(page.confidence) }
            i += pagesPerRequest
        }

        // Drop exact duplicates that can straddle a chunk boundary, then re-seq.
        var seen = Set<String>()
        var deduped: [TxnRow] = []
        for r in allRows {
            let key = "\(r.txnDate)|\(r.descr)|\(r.debit)|\(r.credit)"
            if seen.insert(key).inserted { deduped.append(r) }
        }
        for k in deduped.indices { deduped[k].seq = k + 1; if deduped[k].currency.isEmpty { deduped[k].currency = currency } }
        let conf = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count)
        return ExtractedStatement(bank: bank, currency: currency.isEmpty ? (hintCurrency ?? "INR") : currency,
                                  rows: deduped, confidence: conf)
    }

    // MARK: - One request

    private struct PageResult { let bank: String?; let currency: String; let rows: [TxnRow]; let confidence: Double }

    private func extractChunk(_ text: String, currencyHint: String) async -> PageResult {
        let body = requestBody(text: text, currencyHint: currencyHint)
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 120
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        lastRequestByteCount += req.httpBody?.count ?? 0

        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["stop_reason"] as? String) != "refusal",
              let content = obj["content"] as? [[String: Any]],
              let json = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let inner = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: inner) as? [String: Any]
        else { return PageResult(bank: nil, currency: "", rows: [], confidence: 0) }

        let cur = (root["currency"] as? String) ?? ""
        let bank = root["bank"] as? String
        let conf = (root["confidence"] as? NSNumber)?.doubleValue ?? 0.7
        let txns = (root["transactions"] as? [[String: Any]]) ?? []
        let rows = txns.compactMap { row(from: $0, currency: cur) }
        return PageResult(bank: bank, currency: cur, rows: rows, confidence: max(0, min(1, conf)))
    }

    private func row(from d: [String: Any], currency: String) -> TxnRow? {
        guard let date = d["date"] as? String, let comps = isoParts(date) else { return nil }
        let debit = (d["debit"] as? NSNumber)?.doubleValue ?? 0
        let credit = (d["credit"] as? NSNumber)?.doubleValue ?? 0
        let balance = (d["balance"] as? NSNumber)?.doubleValue
        return TxnRow(txnDate: date, month: String(date.prefix(7)), year: comps.y, monthNo: comps.m, day: comps.d,
                      descr: (d["description"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                      merchant: "", category: (d["category"] as? String ?? ""),
                      debit: debit, credit: credit, balance: balance, currency: currency, seq: 0)
    }

    private func isoParts(_ s: String) -> (y: Int, m: Int, d: Int)? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, (1...12).contains(p[1]), (1...31).contains(p[2]) else { return nil }
        return (p[0], p[1], p[2])
    }

    // MARK: - Request body (structured outputs)

    private func requestBody(text: String, currencyHint: String) -> [String: Any] {
        let cats = ClaudeCategorizer.canonicalCategories
        let txnItem: [String: Any] = [
            "type": "object",
            "properties": [
                "date": ["type": "string", "description": "ISO YYYY-MM-DD; infer the year from the statement header if the row omits it"],
                "description": ["type": "string"],
                "debit": ["type": "number", "description": "money out, positive; 0 if none"],
                "credit": ["type": "number", "description": "money in, positive; 0 if none"],
                "balance": ["type": ["number", "null"], "description": "running balance if the statement has that column, else null"],
                "category": ["type": "string", "enum": cats],
            ],
            "required": ["date", "description", "debit", "credit", "category"],
            "additionalProperties": false,
        ]
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "bank": ["type": ["string", "null"]],
                "currency": ["type": "string", "description": "ISO code e.g. INR, USD, GBP, EUR"],
                "confidence": ["type": "number", "description": "0..1 — how confident the OCR text was legible enough to extract exactly"],
                "transactions": ["type": "array", "items": txnItem],
            ],
            "required": ["currency", "confidence", "transactions"],
            "additionalProperties": false,
        ]
        let system = """
        You extract transactions from the OCR'd text of a (possibly scanned) bank or card \
        statement. Read amounts EXACTLY as printed — do not compute, round, or invent figures. \
        Output one entry per real transaction row in top-to-bottom order. Skip header, summary, \
        opening/closing-balance and subtotal lines. Put money-out in `debit` and money-in in \
        `credit` as positive numbers (0 for the other). Include `balance` only if the statement \
        shows a running-balance column, else null. Dates as YYYY-MM-DD, inferring the year from \
        the statement period when a row omits it. If the OCR is too garbled to read a figure \
        exactly, lower `confidence` rather than guessing.
        """
        return [
            "model": model,
            "max_tokens": 8000,
            "system": system,
            "output_config": ["format": ["type": "json_schema", "schema": schema]],
            "messages": [["role": "user",
                          "content": "Currency hint: \(currencyHint.isEmpty ? "unknown" : currencyHint).\nStatement text:\n\(text)"]],
        ]
    }
}
