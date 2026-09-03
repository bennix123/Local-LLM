import Foundation
import PennyFinance
import PennyModel

// QueryParser — the LLM-as-parser tier (Rahul's architecture, 2026-09-03).
//
// The model's ONLY job is to map a question onto the restricted vocabulary of
// `ParsedQueryDTO`; the deterministic `QueryDTOMapper` + `QueryEngine` do all
// resolution and math. Apple's on-device guided generation goes first (the
// grammar is enforced by the OS — the model cannot emit "summ"), a local MLX
// model is the fallback (JSON-only prompt, decoded + validated). One retry per
// engine carrying the mapper's error message. The prompt contains the QUESTION
// and the data's vocabulary (entity names, months span, today) — never
// transactions.

public enum QueryParser {

    public struct Outcome: Sendable {
        public let query: Query
        public let attempts: Int
        public let engine: String        // "apple" | "mlx"
    }

    /// `mlxGenerate` is the app-supplied fallback: (instructions, prompt) → raw
    /// model text. Pass nil on iOS (Apple-only by product decision) or when no
    /// MLX weights are installed — parsing then quietly returns nil on Apple
    /// failure and the caller falls through to prose chat.
    public static func parse(question: String,
                             vocabulary: QueryVocabulary,
                             today: CalendarDate,
                             mlxGenerate: (@Sendable (String, String) async throws -> String)? = nil)
    async -> Outcome? {
        let instructions = Self.instructions(vocabulary: vocabulary, today: today)
        var attempts = 0

        // ---- Apple on-device guided generation --------------------------------
        if #available(macOS 26.0, iOS 26.0, *), AppleFoundationLLM.isAvailable {
            var feedback: String?
            for _ in 0..<2 {
                attempts += 1
                guard let dto = try? await AppleFoundationLLM.parseQuery(
                    question: question, instructions: instructions, feedback: feedback)
                else { break }   // model unavailable/error → try MLX
                switch QueryDTOMapper.map(dto, vocabulary: vocabulary, today: today) {
                case .success(let q): return Outcome(query: q, attempts: attempts, engine: "apple")
                case .failure(let e):
                    feedback = e.message
                    print("🧭[parse] apple attempt \(attempts) rejected: \(e.message) — dto: \(dto)")
                }
            }
        }

        // ---- MLX fallback (JSON-only prompt) ----------------------------------
        guard let mlxGenerate else { return nil }
        var feedback: String?
        for _ in 0..<2 {
            attempts += 1
            let prompt = Self.mlxPrompt(question: question, feedback: feedback)
            guard let raw = try? await mlxGenerate(instructions, prompt),
                  let dto = Self.decodeJSON(raw) else { return nil }
            switch QueryDTOMapper.map(dto, vocabulary: vocabulary, today: today) {
            case .success(let q): return Outcome(query: q, attempts: attempts, engine: "mlx")
            case .failure(let e): feedback = e.message
            }
        }
        return nil
    }

    // MARK: - prompt

    static func instructions(vocabulary: QueryVocabulary, today: CalendarDate) -> String {
        let cats = vocabulary.categories.prefix(30).joined(separator: ", ")
        let accts = vocabulary.accounts.map(\.name).joined(separator: ", ")
        let merchants = vocabulary.merchants.prefix(40).joined(separator: ", ")
        let span = vocabulary.dateRange.map {
            "\(iso($0.start)) to \(iso($0.end))"
        } ?? "unknown"
        return """
        You translate ONE personal-finance question into a small structured query. \
        You never compute anything — a deterministic engine does the math. Map the \
        question onto these fields and nothing else:

        - aggregate: sum (total money) | count (how many) | average | min | max | \
        top_n (needs topN) | list (show the transactions)
        - direction: "debit" for spending/paying/outgoing, "credit" for \
        income/receiving/incoming. Omit when the question implies neither.
        - category / merchant / account: copy the entity words the user said \
        (spelling mistakes are fine — the engine resolves them). Only fill a field \
        the question actually mentions. Never invent entities.
        - period: a token, never a computed date. Allowed: all, today, yesterday, \
        this_week, last_week, this_month, last_month, this_year, last_year, \
        last_7_days, last_30_days, last_90_days, a year like 2025, a month like \
        2025-11 or "november 2025" or just "november", or an explicit range \
        YYYY-MM-DD..YYYY-MM-DD.
        - amountMin/amountMax: only when the question sets an amount bound \
        ("over 1000", "under 50").
        - groupBy: month | day | category | merchant | account | currency — only \
        for per-X breakdowns ("by month", "per category").
        - text: a free-text word to search descriptions for, when it is clearly \
        not a category/merchant/account.

        Spending questions ("spend", "pay", "cost") are direction=debit with \
        aggregate=sum unless they ask "how many" (count) or biggest/smallest \
        (max/min). Income questions ("receive", "earn", "salary") are \
        direction=credit.

        DATA CONTEXT (for entity spelling only — do not answer from it):
        - today: \(iso(today))
        - data covers: \(span)
        - categories present: \(cats)
        - accounts present: \(accts)
        - some merchants present: \(merchants)
        """
    }

    static func mlxPrompt(question: String, feedback: String?) -> String {
        var p = """
        Translate this question into ONE JSON object with exactly these optional \
        keys: {"aggregate": "...", "direction": "...", "category": "...", \
        "merchant": "...", "account": "...", "period": "...", "amountMin": 0, \
        "amountMax": 0, "groupBy": "...", "topN": 0, "text": "..."}. \
        Output ONLY the JSON object, nothing else.

        QUESTION: \(question)
        """
        if let feedback {
            p += "\n\nYour previous attempt was rejected: \(feedback). Fix it."
        }
        return p
    }

    /// Pull the first {...} block out of raw model text and decode it.
    static func decodeJSON(_ raw: String) -> ParsedQueryDTO? {
        guard let open = raw.firstIndex(of: "{"), let close = raw.lastIndex(of: "}"),
              open < close else { return nil }
        let json = String(raw[open...close])
        return try? JSONDecoder().decode(ParsedQueryDTO.self, from: Data(json.utf8))
    }

    private static func iso(_ d: CalendarDate) -> String {
        String(format: "%04d-%02d-%02d", d.year, d.month, d.day)
    }
}
