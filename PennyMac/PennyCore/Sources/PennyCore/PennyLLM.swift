import Foundation
import PennyTxnStore   // CategoryNormalizer — taxonomy-level category snapping
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

/// Header-level facts read off a statement by the model — the fields that vary
/// too much in layout for a fixed label parser (Amex "Prepared for", Barclays,
/// Monzo, Indian banks each print them differently). Values are the raw strings
/// as printed; the app validates/normalizes them (dates via `CalendarDate`, names
/// title-cased) before display, and never trusts an unparseable one. Both the
/// Apple and MLX engines return this shape, so callers are engine-agnostic.
public struct StatementFacts: Sendable, Codable, Equatable {
    /// The person the statement is prepared for / the account holder, or nil.
    public var cardholder: String?
    /// The statement (closing) date as printed — NOT a due date or a txn date, or nil.
    public var statementDate: String?
    public init(cardholder: String? = nil, statementDate: String? = nil) {
        self.cardholder = cardholder
        self.statementDate = statementDate
    }
    enum CodingKeys: String, CodingKey { case cardholder, statementDate }
    /// Lenient decode: absent/blank/"null"-string fields become nil.
    public init(from decoder: Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func field(_ k: CodingKeys) -> String? {
            guard let s = try? c.decode(String.self, forKey: k) else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t.isEmpty || t.caseInsensitiveCompare("null") == .orderedSame) ? nil : t
        }
        cardholder = field(.cardholder)
        statementDate = field(.statementDate)
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
    ///
    /// Chat-only prompt: the model answers questions in prose. It must NOT build
    /// transaction tables — those are rendered deterministically by the app's
    /// LEDGER path, never the model. Telling a small model to emit a "| Date |
    /// Description |" grid here made it start a table for *any* prompt (even
    /// "roast me" or a greeting) and then degenerate into runaway whitespace.
    public static let systemPrompt = """
        You are Penny, an offline personal-finance assistant. Answer the user's question \
        using ONLY the bank-statement text and figures provided. Quote amounts exactly as \
        they appear; never invent, guess, round or recalculate numbers that are not written \
        there. If the answer isn't in the data, say so plainly.

        Reply in a few short sentences of warm, plain English — like a friend texting back. \
        No headings, no 'Answer:' prefix. Do NOT output a table or a "| Date | Description |" \
        grid, and do not list transactions row by row — those are shown elsewhere in the app. \
        For advice, opinions or a "roast", be specific: name the actual merchants and amounts \
        from the figures provided and keep it to one short, punchy paragraph.
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

    /// Release the MLX container — and with it ~2 GB of wired GPU memory. The
    /// weights stay cached on disk, so the next load() is a fast local reload,
    /// not a re-download. Callers hook this to memory-pressure warnings and
    /// app-background transitions; holding a model nobody is talking to is how
    /// a 16 GB machine ends up swapping.
    public func unload() { container = nil }

    /// True when Apple's on-device system model (FoundationModels) is ready — chat
    /// and categorization then run with NO MLX download. Lets callers relax the
    /// "load the model first" gate and advertise on-device readiness up front.
    public static var systemModelAvailable: Bool {
        if #available(macOS 26.0, iOS 26.0, *) { return AppleFoundationLLM.isAvailable }
        return false
    }

    /// Load (downloading the weights on first use) and cache the model.
    /// The Swift twin of ensure_loaded() in the reference.
    ///
    /// Progress: the Hub's snapshot `Progress` only credits whole COMPLETED files,
    /// so a single 1.7–4.5 GB weights file reports ~0% for the entire download and
    /// then snaps to 100% — which reads as a hang and makes users quit (killing the
    /// download, which has no resume). The Hub total is accurate though, so we pair
    /// it with the bytes actually on disk (cache blobs + URLSession's in-flight
    /// CFNetworkDownload temp files) and report whichever is further along.
    @discardableResult
    public func load(onProgress: (@Sendable (LoadProgress) -> Void)? = nil) async throws -> ModelContainer {
        if let container { return container }
        let store = ModelStore.shared

        // Weights already fetched by an earlier build (Hub layouts) become an
        // instant install instead of a multi-GB re-download.
        if await store.directoryIfInstalled(for: modelID) == nil {
            await store.adoptLegacyCaches(for: modelID)
        }

        // Download whatever is missing — byte-exact resumable, so a cancelled
        // (paused / quit) attempt continues where it stopped, whenever retried.
        if await store.directoryIfInstalled(for: modelID) == nil {
            try await store.download(repo: modelID) { p in
                onProgress?(LoadProgress(
                    // Reserve the top slice of the bar for the GPU load below.
                    fraction: min(0.98, p.fraction),
                    completedBytes: p.bytes,
                    totalBytes: p.total
                ))
            }
        }

        guard let dir = await store.directoryIfInstalled(for: modelID) else {
            // Should be unreachable (download throws on failure) — but never
            // fall through to a silent hub re-download.
            throw NSError(domain: "penny", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Model files incomplete after download — resume to retry."])
        }
        let container = try await loadModelContainer(
            from: dir, using: #huggingFaceTokenizerLoader())
        self.container = container
        onProgress?(LoadProgress(fraction: 1, completedBytes: 0, totalBytes: 0))
        return container
    }

    /// Bytes of this repo already on disk plus any in-flight download temp files.
    /// Checks every cache location swift-huggingface may use (HF_HUB_CACHE, HF_HOME,
    /// ~/.cache/huggingface/hub, and the sandbox/caches fallback). Only temp files
    /// touched in the last minute count — abandoned CFNetworkDownload_*.tmp files
    /// from earlier killed attempts would otherwise inflate the number.
    static func bytesOnDisk(repo: String) -> Int64 {
        let fm = FileManager.default
        let escaped = "models--" + repo.replacingOccurrences(of: "/", with: "--")
        let env = ProcessInfo.processInfo.environment
        var hubDirs: [URL] = []
        if let p = env["HF_HUB_CACHE"] { hubDirs.append(URL(fileURLWithPath: p)) }
        if let p = env["HF_HOME"] { hubDirs.append(URL(fileURLWithPath: p).appendingPathComponent("hub")) }
        // NSHomeDirectory, not homeDirectoryForCurrentUser: the latter is macOS-only
        // API; this resolves to the sandbox container home on iOS.
        hubDirs.append(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache/huggingface/hub"))
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            hubDirs.append(caches.appendingPathComponent("huggingface/hub"))
        }
        var total: Int64 = 0
        for dir in hubDirs {
            let repoDir = dir.appendingPathComponent(escaped)
            guard let en = fm.enumerator(at: repoDir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let u as URL in en {
                total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        let tmp = fm.temporaryDirectory
        if let items = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) {
            for u in items where u.lastPathComponent.hasPrefix("CFNetworkDownload") {
                let vals = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard let mtime = vals?.contentModificationDate, Date().timeIntervalSince(mtime) < 60 else { continue }
                total += Int64(vals?.fileSize ?? 0)
            }
        }
        return total
    }

    /// One grounded question over one statement, streamed token-by-token.
    /// The Swift twin of stream() in the reference (temp 0.3 / top-p 0.9).
    /// The slice deliberately has NO RAG yet — the whole doc is stuffed into context.
    ///
    /// `onEngine` reports which engine is actually answering ("apple" or "mlx") the
    /// moment that path is entered; if Apple fails and MLX takes over, it fires
    /// again — the last value is the engine that produced the returned text.
    @discardableResult
    public func ask(
        question: String,
        statementText: String,
        maxTokens: Int = 600,
        allowMLXFallback: Bool = true,
        onEngine: (@Sendable (String) -> Void)? = nil,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        // An explicitly loaded MLX model answers: the user picked and downloaded it,
        // so it must not be silently bypassed. Apple's on-device system model covers
        // the no-download case, with MLX as the fallback on an Apple failure.
        // Apple's path is non-streaming-on-failure: it only throws when nothing
        // streamed, so the MLX fallback never double-shows a half-streamed answer.
        // `allowMLXFallback: false` (iOS: Apple-only by product decision) surfaces
        // the Apple error instead of triggering a multi-GB weights download.
        if container == nil, #available(macOS 26.0, iOS 26.0, *), AppleFoundationLLM.isAvailable {
            do {
                onEngine?("apple")
                // Streams straight to `onToken` for immediate first-token; returns the
                // full text. Only throws when nothing streamed, so MLX fallback is safe.
                return try await AppleFoundationLLM.answer(
                    question: question, statementText: statementText,
                    maxTokens: maxTokens, onToken: onToken)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard allowMLXFallback else { throw error }
                // nothing was streamed → fall through to the MLX model below
            }
        }
        guard allowMLXFallback || container != nil else {
            throw NSError(domain: "penny", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "On-device generation needs Apple Intelligence on this device."])
        }
        onEngine?("mlx")
        let container = try await load()

        let clipped = String(statementText.prefix(12_000))
        let user = """
            BANK STATEMENT TEXT:
            \(clipped)

            QUESTION: \(question)
            """

        // repetitionPenalty is the safety net: without it a small model that slips
        // into a degenerate pattern (e.g. padding a markdown column with spaces) will
        // repeat it until it burns every one of `maxTokens`, which looks like the app
        // hanging mid-answer. 1.15 over a 40-token window breaks those loops cheaply.
        let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0.3, topP: 0.9,
                                            repetitionPenalty: 1.15, repetitionContextSize: 40)

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
        // Apple's on-device system model first (no download, no MLX/Metal init).
        // Only a genuine FM error falls through to the MLX model below.
        if #available(macOS 26.0, iOS 26.0, *), AppleFoundationLLM.isAvailable {
            do { return try await AppleFoundationLLM.extractTransactions(from: statementText, maxTokens: maxTokens) }
            catch is CancellationError { throw CancellationError() }
            catch { /* fall through to the MLX model below */ }
        }
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
        // Apple's on-device system model first (no download, no MLX/Metal init).
        // A nil result here is a legitimate "UNKNOWN" and is returned as-is; only a
        // genuine FM error falls through to the MLX model below.
        if #available(macOS 26.0, iOS 26.0, *), AppleFoundationLLM.isAvailable {
            do { return try await AppleFoundationLLM.detectIssuer(from: statementText) }
            catch is CancellationError { throw CancellationError() }
            catch { /* fall through to the MLX model below */ }
        }
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

    /// Read header-level facts (cardholder, statement date) off a statement,
    /// on-device. Like `detectIssuer`, this generalizes past the deterministic
    /// label parser's fixed patterns to ANY statement layout the model can read —
    /// the app calls it only when the label parser couldn't find the field. Apple's
    /// system model (validated `@Generable`) first; the MLX model (JSON) otherwise.
    /// Deterministic (temp 0) and small. All fields may be nil ("not printed").
    public func extractStatementFacts(from statementText: String) async throws -> StatementFacts {
        if #available(macOS 26.0, iOS 26.0, *), AppleFoundationLLM.isAvailable {
            do { return try await AppleFoundationLLM.extractFacts(from: statementText) }
            catch is CancellationError { throw CancellationError() }
            catch { /* fall through to the MLX model below */ }
        }
        let container = try await load()
        let head = String(statementText.prefix(2_500))
        let system = """
            You read header facts off a bank or credit-card statement. Output ONLY a \
            JSON object (no prose, no markdown fences) with exactly these keys: \
            "cardholder" (the full name the statement is prepared for / the account \
            holder, exactly as printed) and "statementDate" (the statement or closing \
            date printed in the header — NOT the payment due date and NOT a transaction \
            date, exactly as printed). Use an empty string "" for any field the header \
            does not clearly show. Do not guess.
            """
        let user = "STATEMENT (header text):\n\(head)\n\nReturn the JSON object now."
        let parameters = GenerateParameters(maxTokens: 128, temperature: 0, topP: 1.0)
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
        return Self.parseFacts(from: raw)
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
        if #available(macOS 26.0, iOS 26.0, *), AppleFoundationLLM.isAvailable {
            if let out = try? await AppleFoundationLLM.categorize(
                descriptors, seedCategories: seedCategories, forbidOther: forbidOther), !out.isEmpty {
                return out
            }
        }
        let container = try await load()
        // When `forbidOther`, the model must place EVERY descriptor — no "Other".
        let otherRule = forbidOther ? """
            NEVER answer "Other", "Unknown", "Uncategorized", "Misc" or "N/A" — every \
            descriptor MUST get a concrete category. Only when the payee is a person \
            or cannot be identified at all, use "Transfers". Metro / rail / bus / \
            transit is "Transport". Card-network, forex markup, ATM or bank charges \
            are "Fees & Charges". If still unsure, pick the single closest real \
            category — never "Other".
            """ : """
            Use "Other" only when the descriptor is truly unguessable.
            """
        let system = """
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
            "Transfers".

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


    /// Forwarder: category normalization lives with the taxonomy in
    /// PennyTxnStore (`CategoryNormalizer`) — kept here so existing callers
    /// (AppleFoundationLLM, the app) don't churn.
    public static func normalizeCategory(_ raw: String, seeds: [String]) -> String {
        CategoryNormalizer.normalize(raw, seeds: seeds)
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

    /// Pull the JSON object out of the model's reply (it may wrap it in prose/fences)
    /// and decode it into `StatementFacts`, tolerating malformed output (returns an
    /// all-nil value rather than throwing).
    static func parseFacts(from raw: String) -> StatementFacts {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8) else {
            return StatementFacts()
        }
        return (try? JSONDecoder().decode(StatementFacts.self, from: data)) ?? StatementFacts()
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
