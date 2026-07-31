import Foundation
import MLXLMCommon
import MLXLLM
import MLXHuggingFace
import HuggingFace   // HubClient — referenced by the #hubDownloader macro expansion
import Tokenizers    // AutoTokenizer — referenced by the #huggingFaceTokenizerLoader expansion

/// One parsed transaction. The model only EXTRACTS these from the statement text;
/// all figures (totals, balances, category sums) are then computed deterministically
/// in Swift, so the numbers themselves are not model-guessed.
public struct Transaction: Sendable, Codable, Equatable {
    public let date: String
    public let description: String
    public let debit: Double?    // money out
    public let credit: Double?   // money in
    public let balance: Double?
    /// Deterministic category from PennyTxnStore's `categories.json` (nil when the
    /// row came from the model-extraction fallback, which doesn't categorize).
    public var category: String?

    public init(date: String, description: String, debit: Double?, credit: Double?, balance: Double?, category: String? = nil) {
        self.date = date; self.description = description
        self.debit = debit; self.credit = credit; self.balance = balance
        self.category = category
    }

    enum CodingKeys: String, CodingKey { case date, description, debit, credit, balance, category }

    // `Swift.Decoder` is qualified because the Tokenizers module (imported for MLX)
    // also exports a `Decoder` type, which would otherwise shadow this.
    public init(from decoder: Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = (try? c.decode(String.self, forKey: .date)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        debit = Transaction.number(c, .debit)
        credit = Transaction.number(c, .credit)
        balance = Transaction.number(c, .balance)
        category = try? c.decode(String.self, forKey: .category)
    }

    /// Accept a number, or a string like "1,234.50" / "₹1,00,000" (models often quote amounts).
    private static func number(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        if let d = try? c.decode(Double.self, forKey: key) { return d }
        if let s = try? c.decode(String.self, forKey: key) {
            let cleaned = s.filter { $0.isNumber || $0 == "." || $0 == "-" }
            return cleaned.isEmpty ? nil : Double(cleaned)
        }
        return nil
    }
}

/// One on-device category verdict for a merchant descriptor, from
/// `PennyLLM.categorizeMerchants`. `category` may be a brand-new name the model
/// coined (dynamic taxonomy) — not just one of the seeds it was shown.
public struct MerchantCategory: Sendable, Equatable {
    public let merchant: String     // the input descriptor, original spelling
    public let category: String     // normalized Title Case, 1–3 words
    public let confidence: Double   // 0…1
    public init(merchant: String, category: String, confidence: Double) {
        self.merchant = merchant; self.category = category; self.confidence = confidence
    }
}

/// The ONE place the app talks to a model — the Swift port of
/// finquery/backend/src/services/llm_provider.py.
///
/// MLX runs in-process on Metal: no llama.cpp, no GGUF, no subprocess, no localhost
/// server. That is exactly what makes this sandbox / App Store legal.
public actor PennyLLM {

    /// Same catalogue as the FinQuery reference (MLX-format weights on HuggingFace).
    public struct CatalogEntry: Sendable {
        public let id: String
        public let name: String
        public let size: String
        public let minRAMGB: Int
        public let note: String
    }

    public static let catalog: [CatalogEntry] = [
        .init(id: "mlx-community/Llama-3.1-8B-Instruct-4bit", name: "Llama 3.1 8B", size: "4.5 GB", minRAMGB: 16, note: "Best reasoning · recommended"),
        .init(id: "mlx-community/Qwen2.5-7B-Instruct-4bit",  name: "Qwen 2.5 7B",  size: "4.3 GB", minRAMGB: 16, note: "Strong all-rounder"),
        .init(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", name: "Llama 3.2 3B", size: "1.8 GB", minRAMGB: 8,  note: "Balanced · low memory"),
        .init(id: "mlx-community/Qwen2.5-3B-Instruct-4bit",  name: "Qwen 2.5 3B",  size: "1.7 GB", minRAMGB: 8,  note: "Fast · lightest"),
    ]

    /// Small + fast — the vertical-slice default. Swap to the 8B once the slice works.
    public static let sliceModelID = "mlx-community/Llama-3.2-3B-Instruct-4bit"

    /// Grounding rules distilled from finquery/scripts/test_server/prompts.py.
    public static let systemPrompt = """
        You are Penny, an offline personal-finance assistant. Answer the user's question \
        using ONLY the bank-statement text provided. Quote amounts exactly as they appear \
        in the text; never invent, guess, round or calculate numbers that are not written \
        there. If the answer is not in the statement, say so plainly. Be concise, warm and \
        plain-English. No headings, no 'Answer:' prefix.

        When the user asks for transactions, a list, or "table" data, reply with a clean \
        GitHub-flavored Markdown table: pipe "|" separated columns with a "---" header \
        separator row, and one transaction per row. Prefer concise columns such as Date, \
        Description, Debit, Credit, Balance. NEVER output comma-separated values, and do \
        not dump raw reference numbers, cheque numbers or branch codes unless explicitly asked.
        """

    /// Download/load progress, richer than a bare fraction so the UI can show
    /// "1.9 / 4.5 GB" and a real percentage even while one huge weights file
    /// dominates the byte count.
    public struct LoadProgress: Sendable {
        public let fraction: Double       // 0…1 (Progress.fractionCompleted)
        public let completedBytes: Int64  // Progress.completedUnitCount
        public let totalBytes: Int64      // Progress.totalUnitCount
    }

    private let modelID: String
    private var container: ModelContainer?

    public init(modelID: String = PennyLLM.sliceModelID) {
        self.modelID = modelID
    }

    public var isLoaded: Bool { container != nil }

    /// True when Apple's on-device system model (FoundationModels) is ready — chat
    /// and categorization then run with NO MLX download. Lets callers relax the
    /// "load the model first" gate and advertise on-device readiness up front.
    public static var systemModelAvailable: Bool {
        if #available(macOS 26.0, *) { return AppleFoundationLLM.isAvailable }
        return false
    }

    /// Load (downloading the weights on first use) and cache the model.
    /// The Swift twin of ensure_loaded() in the reference.
    @discardableResult
    public func load(onProgress: (@Sendable (LoadProgress) -> Void)? = nil) async throws -> ModelContainer {
        if let container { return container }
        let configuration = ModelConfiguration(id: modelID)
        // Downloads from HuggingFace on first use, then loads onto the GPU (Metal).
        // The Hub reports a Foundation `Progress` ~every 100ms; forward the byte
        // counts too so the UI can render smooth, honest download progress.
        let container = try await #huggingFaceLoadModelContainer(
            configuration: configuration,
            progressHandler: { p in
                onProgress?(LoadProgress(
                    fraction: p.fractionCompleted,
                    completedBytes: p.completedUnitCount,
                    totalBytes: p.totalUnitCount
                ))
            }
        )
        self.container = container
        return container
    }

    /// One grounded question over one statement, streamed token-by-token.
    /// The Swift twin of stream() in the reference (temp 0.3 / top-p 0.9).
    /// The slice deliberately has NO RAG yet — the whole doc is stuffed into context.
    @discardableResult
    public func ask(
        question: String,
        statementText: String,
        maxTokens: Int = 600,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        // Apple's on-device system model first (no download); MLX is the fallback.
        // Non-streaming, so a failure emits nothing and the MLX path can take over
        // cleanly without double-showing a half-streamed answer. See WWDC26-326.
        if #available(macOS 26.0, *), AppleFoundationLLM.isAvailable {
            do {
                let ans = try await AppleFoundationLLM.answer(
                    question: question, statementText: statementText, maxTokens: maxTokens)
                onToken(ans)
                return ans
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // fall through to the MLX model below
            }
        }
        let container = try await load()

        let clipped = String(statementText.prefix(12_000))
        let user = """
            BANK STATEMENT TEXT:
            \(clipped)

            QUESTION: \(question)
            """

        let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0.3, topP: 0.9)

        return try await container.perform { context in
            let input = try await context.processor.prepare(
                input: UserInput(chat: [
                    .system(Self.systemPrompt),
                    .user(user),
                ])
            )
            var output = ""
            let stream = try MLXLMCommon.generate(input: input, parameters: parameters, context: context)
            for await generation in stream {
                // Cooperative cancellation: the MLX stream won't stop on its own, so
                // bail out when the caller cancels the task (e.g. the Stop button).
                if Task.isCancelled { break }
                if case .chunk(let piece) = generation {
                    output += piece
                    onToken(piece)
                }
            }
            return output
        }
    }

    /// One-time structured extraction: turn the statement text into `[Transaction]`.
    /// The model ONLY reads out the rows; every figure is later computed in Swift, so
    /// the model can't fudge a total. Temperature 0 for deterministic extraction.
    public func extractTransactions(from statementText: String, maxTokens: Int = 4096) async throws -> [Transaction] {
        let container = try await load()
        let clipped = String(statementText.prefix(16_000))
        let system = """
            You extract structured data from bank statements. Output ONLY a JSON array (no \
            prose, no markdown code fences). Each element is a transaction object with keys: \
            "date" (string as printed), "description" (string), "debit" (number or null = money \
            out), "credit" (number or null = money in), "balance" (number or null = running \
            balance). Use null when a value is absent. Numbers must be plain — no currency \
            symbols and no thousands separators. Include every transaction, in order.
            """
        let user = "BANK STATEMENT TEXT:\n\(clipped)\n\nReturn the JSON array now."
        let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0, topP: 1.0)

        let raw = try await container.perform { context in
            let input = try await context.processor.prepare(
                input: UserInput(chat: [.system(system), .user(user)])
            )
            var output = ""
            let stream = try MLXLMCommon.generate(input: input, parameters: parameters, context: context)
            for await generation in stream {
                if case .chunk(let piece) = generation { output += piece }
            }
            return output
        }
        return Self.parseTransactions(from: raw)
    }

    /// One-shot issuer classification for the account list: read the bank, card
    /// issuer or provider name off the statement header. This generalizes past the
    /// deterministic parser's fixed fast-track list (which only knows a handful of
    /// banks) to any institution the model recognizes. Deterministic (temp 0) and
    /// tiny — a dozen output tokens. Returns nil when it can't identify one.
    public func detectIssuer(from statementText: String) async throws -> String? {
        let container = try await load()
        let head = String(statementText.prefix(2_000))
        let system = """
            You identify the financial institution that issued a bank or credit-card \
            statement. Reply with ONLY the institution's common name — for example \
            "American Express", "Monzo", "Barclays", "NatWest". No account type, no \
            extra words, no punctuation, no quotes, no explanation. If you genuinely \
            cannot tell, reply exactly UNKNOWN.
            """
        let user = "STATEMENT (header text):\n\(head)\n\nInstitution name:"
        let parameters = GenerateParameters(maxTokens: 16, temperature: 0, topP: 1.0)

        let raw = try await container.perform { context in
            let input = try await context.processor.prepare(
                input: UserInput(chat: [.system(system), .user(user)])
            )
            var output = ""
            let stream = try MLXLMCommon.generate(input: input, parameters: parameters, context: context)
            for await generation in stream {
                if case .chunk(let piece) = generation { output += piece }
            }
            return output
        }
        return Self.cleanIssuer(raw)
    }

    /// Categorize merchant descriptors ON-DEVICE with a dynamic taxonomy: the model
    /// should reuse a `seedCategories` name when one fits, but may coin a NEW concise
    /// category (e.g. "Pet Care") when none does — so the category set adapts to the
    /// user's actual spending instead of being enum-locked. Deterministic (temp 0),
    /// fully offline. Descriptors the model skips are simply absent from the result.
    public func categorizeMerchants(_ descriptors: [String],
                                    seedCategories: [String],
                                    forbidOther: Bool = false) async throws -> [MerchantCategory] {
        guard !descriptors.isEmpty else { return [] }
        // Prefer Apple's on-device system model (FoundationModels) when the machine
        // has Apple Intelligence: it emits validated @Generable structs (no JSON to
        // truncate) and needs no weights download. Falls through to MLX on any error
        // or when it's unavailable. See AppleFoundationLLM / WWDC26-326.
        if #available(macOS 26.0, *), AppleFoundationLLM.isAvailable {
            if let out = try? await AppleFoundationLLM.categorize(
                descriptors, seedCategories: seedCategories, forbidOther: forbidOther), !out.isEmpty {
                return out
            }
        }
        let container = try await load()
        // When `forbidOther`, the model must place EVERY descriptor — no "Other".
        let otherRule = forbidOther ? """
            NEVER answer "Other", "Unknown", "Uncategorized", "Misc" or "N/A" — every \
            descriptor MUST get a concrete category. Money sent to or received from a \
            person, or a UPI / IMPS / NEFT / RTGS / bank transfer, or a "name@bank" UPI \
            handle, is "Transfers". Metro / rail / bus / transit is "Transport". \
            Card-network, forex markup, interest, ATM or bank charges are "Fees". \
            If still unsure, pick the single closest real category — never "Other".
            """ : """
            Use "Other" only when the descriptor is truly unguessable.
            """
        let system = """
            You categorize bank- and card-statement merchant descriptors for a \
            personal-finance app. Judge each merchant's real-world business type from \
            brand names, card-acquirer prefixes (DOJO*, TST-, SQ*, IZ*, TEYA*) and \
            location hints.

            Prefer one of the KNOWN CATEGORIES when it fits. If none fits, invent a \
            NEW concise category name — 1 to 3 words, Title Case, like "Pet Care" or \
            "Home Improvement" — describing the business type. \(otherRule)

            Output ONLY a JSON array (no prose, no markdown code fences). One object \
            per descriptor, in the given order, with keys: "merchant" (the descriptor \
            exactly as given), "category" (string), "confidence" (number 0 to 1, \
            1 = certain).

            KNOWN CATEGORIES: \(seedCategories.joined(separator: ", ")).
            """
        let list = descriptors.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let user = "Categorize these \(descriptors.count) merchant descriptors:\n\(list)\n\nReturn the JSON array now."
        let parameters = GenerateParameters(maxTokens: min(4096, 256 + descriptors.count * 50),
                                            temperature: 0, topP: 1.0)

        let raw = try await container.perform { context in
            let input = try await context.processor.prepare(
                input: UserInput(chat: [.system(system), .user(user)])
            )
            var output = ""
            let stream = try MLXLMCommon.generate(input: input, parameters: parameters, context: context)
            for await generation in stream {
                if Task.isCancelled { break }
                if case .chunk(let piece) = generation { output += piece }
            }
            return output
        }
        return Self.parseMerchantCategories(from: raw, descriptors: descriptors, seeds: seedCategories)
    }

    /// Pull the verdict array out of the model's reply and reconcile it against the
    /// input descriptors. Small local models mangle echoes, so each verdict is
    /// matched back alphanumerically case-insensitively — and by position as a
    /// last resort when the model returned exactly one verdict per input. A verdict
    /// that names a category but no confidence gets 0.75 (the accept-and-log band):
    /// the model committed to an answer; a missing number shouldn't discard it.
    public static func parseMerchantCategories(from raw: String, descriptors: [String],
                                               seeds: [String]) -> [MerchantCategory] {
        guard let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

        var originals: [String: String] = [:]   // match key → original descriptor
        for d in descriptors where originals[matchKey(d)] == nil { originals[matchKey(d)] = d }

        var out: [MerchantCategory] = []
        for (i, obj) in arr.enumerated() {
            guard let catRaw = obj["category"] as? String else { continue }
            let echoed = obj["merchant"] as? String ?? ""
            let positional = arr.count == descriptors.count ? descriptors[i] : nil
            guard let merchant = originals[matchKey(echoed)] ?? positional else { continue }
            let confidence: Double
            if let n = obj["confidence"] as? NSNumber { confidence = n.doubleValue }
            else if let s = obj["confidence"] as? String, let d = Double(s) { confidence = d }
            else { confidence = 0.75 }
            out.append(MerchantCategory(merchant: merchant,
                                        category: normalizeCategory(catRaw, seeds: seeds),
                                        confidence: max(0, min(1, confidence))))
        }
        return out
    }

    /// Case/punctuation-insensitive identity for matching a model's echo of a
    /// descriptor back to the original spelling.
    static func matchKey(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Tidy a model-proposed category name: strip quotes/punctuation, collapse
    /// whitespace, snap a case-insensitive seed match to the seed's canonical
    /// spelling (so "food & dining" can't fork "Food & Dining"), Title-Case new
    /// names, and fall back to "Other" for empty or rambling (>3 words / >28
    /// chars) answers.
    public static func normalizeCategory(_ raw: String, seeds: [String]) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.,:;"))
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !s.isEmpty else { return "Other" }
        if let seed = seeds.first(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) { return seed }
        let words = s.split(separator: " ")
        guard words.count <= 3, s.count <= 28 else { return "Other" }
        return words.enumerated().map { i, w -> String in
            let lw = w.lowercased()
            if i > 0, ["&", "and", "of", "the"].contains(lw) { return lw }
            return w.prefix(1).uppercased() + w.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    /// Normalize the model's reply to a bare institution name (first line, stripped
    /// of quotes/punctuation), or nil for an empty / "UNKNOWN" / implausibly long answer.
    static func cleanIssuer(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nl = s.firstIndex(where: { $0.isNewline }) { s = String(s[..<nl]) }
        // Drop a leading conversational prefix the model sometimes adds.
        s = s.replacingOccurrences(
            of: #"^(the\s+)?(institution|issuer|bank|name)(\s+is|:)?\s+"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.,:;- \t"))
        if s.isEmpty || s.caseInsensitiveCompare("UNKNOWN") == .orderedSame { return nil }
        if s.count > 40 { return nil }   // the model rambled — not a name
        return s
    }

    /// Pull the JSON array out of the model's reply (it may wrap it in prose/fences) and
    /// decode it, tolerating malformed output by returning what parses.
    static func parseTransactions(from raw: String) -> [Transaction] {
        guard let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]"), start < end else { return [] }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Transaction].self, from: data)) ?? []
    }
}
