/// A non-exclusive classification flag attached to a transaction by the Phase 2
/// detectors. Additive: a transaction may carry several. Each case has a specific
/// detector that produces it.
public enum Tag: String, Equatable, Codable, Sendable, CaseIterable {
    case salary            // SalaryDetector (2.7)
    case refund            // RefundDetector (2.5)
    case subscription      // SubscriptionDetector (2.7)
    case internalTransfer  // InternalTransferDetector (2.8)
    case atm               // AtmDetector (2.4)
    case foreign           // ForeignDetector (2.4)
    case fee               // FeeDetector (2.4)
    case recurring         // RecurringDetector (2.6)
    case possibleDuplicate // DuplicateDetector (2.8)
    // NB: no generic `.transfer` — the "Transfers" category already covers that;
    // only `.internalTransfer` (a distinct, cross-account detector) is a tag.
}

/// A confidence signal — the key of `Enrichment.confidence`. The score for each
/// is a `Double` in `0...1`. Cases track the confidence-bearing detectors;
/// additive as detectors land. Consumed by: Phase 3 low-confidence surfacing,
/// Phase 4 Insights.
public enum Signal: String, Equatable, Codable, Sendable, CaseIterable {
    case merchant          // MerchantNormalizer match quality (2.2)
    case category          // Categorizer (2.3)
    case salary            // (2.7)
    case refund            // (2.5)
    case subscription      // (2.7)
    case foreign           // (2.4)
    case recurring         // (2.6)
    case internalTransfer  // (2.8)
    case duplicate         // (2.8)
}

/// Everything the Phase 2 detectors attach to a transaction (architecture layer
/// L1). Kept separate from the parsed fields so raw provenance is never
/// overwritten. Immutable value type; the empty value is the parsed-state default.
public struct Enrichment: Equatable, Codable, Sendable {

    /// Link to the normalized merchant (Amendment 01: derived, so it lives here,
    /// not on `Transaction`). Consumed by: Phase 1 (`Filter.merchant`), Phase 4
    /// merchant profiles. Set by the MerchantNormalizer (2.2). Optional.
    public let merchantID: MerchantID?

    /// A human-readable description with reference/branch codes stripped
    /// (Amendment 01: derived). nil until the normalizer produces it. Consumed by:
    /// display, Phase 2.2.
    public let cleanDescription: String?

    /// The single assigned category, or nil until categorized. Consumed by:
    /// Phase 1 (`Filter.category`), set by the Categorizer (2.3).
    public let categoryID: CategoryID?

    /// Non-exclusive flags. Consumed by: Phase 1 (`Filter.tag`), set by the
    /// detectors (2.4–2.8). May be empty.
    public let tags: Set<Tag>

    /// Link to the recurring series this transaction belongs to. Consumed by:
    /// Phase 2.6/4. Optional.
    public let recurringID: RecurringID?

    /// The matched opposite leg of an internal transfer. Consumed by: Phase 2.8
    /// and the cash-flow exclusion rule. Optional.
    public let transferPairID: TransactionID?

    /// Per-signal confidence, each `0...1`. Consumed by: Phase 3 hedging, Phase 4
    /// Insights. May be empty.
    public let confidence: [Signal: Double]

    /// The parsed-state default: no merchant, no category, no tags, no links, no
    /// scores. Consumed by: the parser adapter (0.4) when constructing un-enriched rows.
    public static let empty = Enrichment()

    public init(merchantID: MerchantID? = nil, cleanDescription: String? = nil,
                categoryID: CategoryID? = nil, tags: Set<Tag> = [],
                recurringID: RecurringID? = nil, transferPairID: TransactionID? = nil,
                confidence: [Signal: Double] = [:]) {
        self.merchantID = merchantID
        self.cleanDescription = cleanDescription
        self.categoryID = categoryID
        self.tags = tags
        self.recurringID = recurringID
        self.transferPairID = transferPairID
        self.confidence = confidence
    }
}
