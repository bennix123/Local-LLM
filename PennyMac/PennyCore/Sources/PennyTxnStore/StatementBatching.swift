// StatementBatching — the progressive-analysis engine.
//
// Up to 6 months of statements are processed in month-batches so the UI can show
// the first results fast and keep refreshing as later batches land, instead of
// blocking on the whole set. This file is the PURE, testable core: it plans the
// batches, defines the staged progress model, and isolates retries to a single
// failed batch. The app layer (AppModel) drives real parsing against this plan
// and publishes `AnalysisProgress` + toasts to SwiftUI.
import Foundation

/// One visible step of the analysis, in display order.
public enum AnalysisStage: Equatable, Sendable {
    case readingPDF
    case extractingTransactions
    case analyzing(monthRange: String)   // "1–2", "3–4", "5–6", or "5" for a lone month
    case generatingInsights
    case completed

    /// Human-facing label for the progress UI.
    public var title: String {
        switch self {
        case .readingPDF: return "Reading PDF"
        case .extractingTransactions: return "Extracting transactions"
        case .analyzing(let r): return "Analyzing month \(r)"
        case .generatingInsights: return "Generating insights"
        case .completed: return "Completed"
        }
    }
}

/// One batch of the plan — the statements whose results are published together.
public struct StatementBatch: Equatable, Sendable {
    public let index: Int              // 0-based batch position
    public let fileIndices: [Int]      // indices into the caller's ordered input list
    public let monthRange: String      // "1–2" (nominal months this batch covers)
    public var attempt: Int            // retry counter (0 = first try)
    public var failed: Bool            // set after retries are exhausted

    public init(index: Int, fileIndices: [Int], monthRange: String, attempt: Int = 0, failed: Bool = false) {
        self.index = index; self.fileIndices = fileIndices; self.monthRange = monthRange
        self.attempt = attempt; self.failed = failed
    }
}

/// A snapshot of overall progress for the loading UI.
public struct AnalysisProgress: Equatable, Sendable {
    public var stage: AnalysisStage
    public var stepIndex: Int          // 1-based position in the staged sequence
    public var stepCount: Int          // total steps (Reading + Extracting + N batches + Insights)
    public var fraction: Double        // 0…1 overall, monotonic
    public var batchesDone: Int
    public var batchesTotal: Int

    public init(stage: AnalysisStage, stepIndex: Int, stepCount: Int, fraction: Double,
                batchesDone: Int, batchesTotal: Int) {
        self.stage = stage; self.stepIndex = stepIndex; self.stepCount = stepCount
        self.fraction = fraction; self.batchesDone = batchesDone; self.batchesTotal = batchesTotal
    }

    /// A ready-to-show percentage (0…100).
    public var percent: Int { Int((fraction * 100).rounded()) }

    public static let idle = AnalysisProgress(stage: .readingPDF, stepIndex: 0, stepCount: 1,
                                              fraction: 0, batchesDone: 0, batchesTotal: 0)
}

public enum StatementBatchPlanner {

    public static let defaultMonthsPerBatch = 2
    public static let maxRetriesPerBatch = 2

    /// Group `fileCount` ordered statements (≈ one month each, the common case)
    /// into consecutive batches of `monthsPerBatch`. The final batch may be
    /// smaller. `fileCount == 0` → no batches.
    public static func plan(fileCount: Int, monthsPerBatch: Int = defaultMonthsPerBatch) -> [StatementBatch] {
        guard fileCount > 0 else { return [] }
        let step = max(1, monthsPerBatch)
        var batches: [StatementBatch] = []
        var start = 0, bi = 0
        while start < fileCount {
            let end = min(start + step, fileCount)
            let months = "\(start + 1)" + (end - 1 > start ? "–\(end)" : "")
            batches.append(StatementBatch(index: bi, fileIndices: Array(start..<end), monthRange: months))
            start = end; bi += 1
        }
        return batches
    }

    /// The full ordered stage sequence for a plan, ending in `.completed`:
    /// Reading → Extracting → Analyzing (one per batch) → Generating Insights → Completed.
    public static func stageSequence(for batches: [StatementBatch]) -> [AnalysisStage] {
        var s: [AnalysisStage] = [.readingPDF, .extractingTransactions]
        s += batches.map { .analyzing(monthRange: $0.monthRange) }
        s += [.generatingInsights, .completed]
        return s
    }

    /// Progress at a given stage. `batchesDone` = batches fully published so far.
    /// Fraction is derived from the stage's position in the sequence so it climbs
    /// monotonically and reaches 1.0 only at `.completed`.
    public static func progress(stage: AnalysisStage, batches: [StatementBatch],
                                batchesDone: Int) -> AnalysisProgress {
        let seq = stageSequence(for: batches)
        // The staged UI shows every step except the terminal .completed marker.
        let labeledCount = max(1, seq.count - 1)     // Reading … Insights
        let idx = seq.firstIndex(of: stage) ?? 0     // 0-based position
        let stepIndex = min(idx + 1, labeledCount)   // 1-based
        let fraction: Double
        switch stage {
        case .completed: fraction = 1.0
        default: fraction = min(0.99, Double(idx) / Double(labeledCount))
        }
        return AnalysisProgress(stage: stage, stepIndex: stepIndex, stepCount: labeledCount,
                                fraction: fraction, batchesDone: batchesDone, batchesTotal: batches.count)
    }

    /// Nominal labelled steps for the progress UI (Reading → Extracting →
    /// Analyzing month 1–2 … → Generating insights), given the batch count.
    public static func stageTitles(batchesTotal: Int) -> [String] {
        var t = ["Reading PDF", "Extracting transactions"]
        for i in 0..<max(0, batchesTotal) {
            t.append("Analyzing month \(i * 2 + 1)–\(i * 2 + 2)")
        }
        t.append("Generating insights")
        return t
    }

    /// Retry policy: bump a failed batch's attempt count and return it, or nil once
    /// retries are exhausted (the caller then marks it `.failed` and moves on —
    /// other batches are untouched).
    public static func nextAttempt(_ batch: StatementBatch,
                                   maxRetries: Int = maxRetriesPerBatch) -> StatementBatch? {
        guard batch.attempt < maxRetries else { return nil }
        var b = batch; b.attempt += 1; return b
    }
}
