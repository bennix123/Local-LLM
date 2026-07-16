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

    public init(date: String, description: String, debit: Double?, credit: Double?, balance: Double?) {
        self.date = date; self.description = description
        self.debit = debit; self.credit = credit; self.balance = balance
    }

    enum CodingKeys: String, CodingKey { case date, description, debit, credit, balance }

    // `Swift.Decoder` is qualified because the Tokenizers module (imported for MLX)
    // also exports a `Decoder` type, which would otherwise shadow this.
    public init(from decoder: Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = (try? c.decode(String.self, forKey: .date)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        debit = Transaction.number(c, .debit)
        credit = Transaction.number(c, .credit)
        balance = Transaction.number(c, .balance)
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
