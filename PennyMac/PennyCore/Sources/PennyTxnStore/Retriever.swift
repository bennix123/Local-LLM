// Retriever — on-device hybrid retrieval over parsed transactions (P2 RAG).
//
// Swift port of finquery's hybrid search, but with NO external ML deps:
//   • dense  — Apple's `NLEmbedding` (NaturalLanguage, on-device, sandbox-safe;
//              replaces PyTorch sentence-transformers, no bundled model)
//   • sparse — BM25 (pure Swift; replaces the keyword leg)
//   • fusion — reciprocal rank fusion (replaces weighted score blending)
//
// It answers "which transactions are most relevant to this question?" so the
// LLM is grounded on the few rows that matter instead of the whole statement.
// If the embedding model is unavailable it degrades gracefully to BM25-only.
import Foundation
import NaturalLanguage

public final class TxnRetriever {
    public let rows: [TxnRow]
    private let bm25: BM25
    private let embedding: NLEmbedding?
    private let docVecs: [[Double]?]     // per-row sentence vector (nil if the model had none)
    private let hasDense: Bool

    public init(rows: [TxnRow]) {
        self.rows = rows
        let docs = rows.map { TxnRetriever.docText($0) }
        self.bm25 = BM25(docs: docs.map { TxnRetriever.tokenize($0) })
        let emb = NLEmbedding.sentenceEmbedding(for: .english)
        self.embedding = emb
        let vecs = docs.map { emb?.vector(for: $0) }
        self.docVecs = vecs
        self.hasDense = vecs.contains { $0 != nil }
    }

    /// Top-`k` rows most relevant to `query`, fused across BM25 + dense. Empty
    /// when nothing matches (caller can then fall back to full-document context).
    public func topK(_ query: String, k: Int = 12) -> [TxnRow] {
        guard !rows.isEmpty else { return [] }
        let n = rows.count
        let pool = max(k * 4, 40)

        // sparse leg
        let bmScores = bm25.scores(TxnRetriever.tokenize(query))
        let bmRanks = TxnRetriever.rankMap(bmScores, limit: pool, positiveOnly: true)

        // dense leg (best-effort)
        var dnRanks: [Int: Int] = [:]
        if hasDense, let qv = embedding?.vector(for: query.lowercased()) {
            var dn = [Double](repeating: -Double.greatestFiniteMagnitude, count: n)
            for i in 0..<n where docVecs[i] != nil {
                dn[i] = TxnRetriever.cosine(qv, docVecs[i]!)
            }
            dnRanks = TxnRetriever.rankMap(dn, limit: pool, positiveOnly: false)
        }

        // reciprocal rank fusion (k0 = 60, the standard constant)
        let k0 = 60.0
        var fused = [Double](repeating: 0, count: n)
        for (i, r) in bmRanks { fused[i] += 1.0 / (k0 + Double(r)) }
        for (i, r) in dnRanks { fused[i] += 1.0 / (k0 + Double(r)) }

        let ranked = (0..<n).filter { fused[$0] > 0 }.sorted {
            fused[$0] != fused[$1] ? fused[$0] > fused[$1] : $0 < $1
        }
        return ranked.prefix(k).map { rows[$0] }
    }

    // MARK: - Document text + tokenization

    /// The searchable text for a row: the human-meaningful fields (description,
    /// merchant, category, direction) — the amount/date are handled by the
    /// deterministic router, so they're left out to keep the text semantic.
    static func docText(_ r: TxnRow) -> String {
        let direction = r.debit > 0 ? "spent debit payment outgoing"
                                    : "received credit income deposit incoming"
        return "\(r.descr) \(r.merchant) \(r.category) \(direction)"
    }

    static func tokenize(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 2 }
    }

    // MARK: - Math helpers

    /// index → 1-based rank within the top `limit` by descending score.
    /// `positiveOnly` stops at the first non-positive score (used for BM25, where
    /// 0 means "no term matched" and shouldn't earn a rank).
    static func rankMap(_ scores: [Double], limit: Int, positiveOnly: Bool) -> [Int: Int] {
        let order = (0..<scores.count).sorted {
            scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1
        }
        var out: [Int: Int] = [:]
        for (r, idx) in order.prefix(limit).enumerated() {
            if positiveOnly && scores[idx] <= 0 { break }
            out[idx] = r + 1
        }
        return out
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom > 0 ? dot / denom : 0
    }
}

// MARK: - BM25 (Okapi, k1 = 1.5, b = 0.75)

struct BM25 {
    private let docTF: [[String: Int]]
    private let docLen: [Double]
    private let df: [String: Int]
    private let n: Int
    private let avgdl: Double
    private let k1 = 1.5
    private let b = 0.75

    init(docs: [[String]]) {
        n = docs.count
        var tfs: [[String: Int]] = []
        var lens: [Double] = []
        var df: [String: Int] = [:]
        tfs.reserveCapacity(n)
        for toks in docs {
            var tf: [String: Int] = [:]
            for t in toks { tf[t, default: 0] += 1 }
            tfs.append(tf)
            lens.append(Double(toks.count))
            for t in tf.keys { df[t, default: 0] += 1 }
        }
        docTF = tfs
        docLen = lens
        self.df = df
        avgdl = n > 0 ? lens.reduce(0, +) / Double(n) : 0
    }

    func scores(_ queryTokens: [String]) -> [Double] {
        var out = [Double](repeating: 0, count: n)
        guard !queryTokens.isEmpty, n > 0 else { return out }
        let qset = Array(Set(queryTokens))
        // Precompute IDF per unique query term.
        var idf: [String: Double] = [:]
        for t in qset {
            let dft = Double(df[t] ?? 0)
            idf[t] = log(1 + (Double(n) - dft + 0.5) / (dft + 0.5))
        }
        for i in 0..<n {
            let dl = docLen[i]
            let norm = k1 * (1 - b + b * dl / max(avgdl, 1))
            var s = 0.0
            for t in qset {
                guard let f = docTF[i][t], f > 0, let w = idf[t] else { continue }
                s += w * (Double(f) * (k1 + 1)) / (Double(f) + norm)
            }
            out[i] = s
        }
        return out
    }
}
