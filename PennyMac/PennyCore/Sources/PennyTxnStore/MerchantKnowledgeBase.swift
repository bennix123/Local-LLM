// MerchantKnowledgeBase — the growing, persistent memory of who each merchant is.
//
// The merchant-first categorizer (ClaudeCategorizer, rich mode) is expensive and
// network-bound. Once the model has identified a merchant — its business, its
// primary + specific secondary category — there is no reason to ask again. This
// stores that verdict keyed by the NORMALIZED merchant name, so:
//
//   • Step 6 (merchant knowledge): recognised merchants resolve instantly.
//   • Step 8 (consistency): the same merchant ALWAYS gets the same category —
//     every raw variant ("LIME PASS", "LIME RIDE", "LIME UK") normalizes to one
//     key ("lime") and reads the one stored profile.
//   • Cost: only genuinely new merchants ever reach the LLM.
//
// It is a plain value type with a Codable snapshot; the app layer owns the file
// URL (Application Support) and the main-actor lifecycle. Pure and offline, so it
// is fully unit-testable and never touches the deterministic ingest contract.
import Foundation

/// One learned merchant. `merchant` is the clean display name; `aliases` are the
/// raw descriptor variants seen for it.
public struct MerchantProfile: Codable, Sendable, Equatable {
    public var merchant: String            // normalized display name, e.g. "The Craft Beer Co"
    public var business: String?           // what it does, e.g. "Bar"
    public var primaryCategory: String     // broad bucket, e.g. "Food & Drink"
    public var secondaryCategory: String?  // specific, e.g. "Bar"
    public var confidence: Double          // the verdict's confidence, 0…1
    public var country: String?
    public var aliases: [String]           // raw variants that mapped here
    public var updatedAt: Date

    public init(merchant: String, business: String? = nil,
                primaryCategory: String, secondaryCategory: String? = nil,
                confidence: Double, country: String? = nil,
                aliases: [String] = [], updatedAt: Date = Date()) {
        self.merchant = merchant; self.business = business
        self.primaryCategory = primaryCategory; self.secondaryCategory = secondaryCategory
        self.confidence = confidence; self.country = country
        self.aliases = aliases; self.updatedAt = updatedAt
    }

    /// The category the app should DISPLAY — the specific secondary when we have
    /// one, else the broad primary (spec Step 5: prefer specific).
    public var displayCategory: String {
        if let s = secondaryCategory, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
        return primaryCategory
    }
}

public struct MerchantKnowledgeBase: Sendable, Equatable {

    /// Only verdicts at/above this confidence become authoritative KB entries.
    /// Weaker guesses are left out so they're re-asked (and never cached as fact)
    /// — matching the spec's "never high confidence for unknown merchants".
    public static let learnThreshold = 0.85

    private var byKey: [String: MerchantProfile] = [:]

    public init() {}
    public init(profiles: [MerchantProfile]) {
        for p in profiles {
            byKey[Self.key(for: p.merchant)] = p
            for a in p.aliases where byKey[Self.key(for: a)] == nil {
                // aliases also resolve to the same profile
                byKey[Self.key(for: a)] = p
            }
        }
    }

    /// The de-duplicated set of stored profiles (one per canonical key), for
    /// persistence. Alias-only keys are not re-emitted.
    public var profiles: [MerchantProfile] {
        var seen = Set<String>()
        var out: [MerchantProfile] = []
        for p in byKey.values where seen.insert(Self.key(for: p.merchant)).inserted {
            out.append(p)
        }
        return out.sorted { $0.merchant.lowercased() < $1.merchant.lowercased() }
    }

    public var count: Int { profiles.count }

    /// Normalized lookup key for a raw descriptor: the display-normalized merchant
    /// name, folded to lowercase. Two variants of the same merchant collapse here.
    public static func key(for raw: String) -> String {
        let norm = MerchantNormalizer.normalize(raw)
        let base = norm.isEmpty ? raw : norm
        return base.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The stored profile for a raw descriptor, or nil if the merchant is unknown.
    public func lookup(_ raw: String) -> MerchantProfile? {
        let k = Self.key(for: raw)
        return k.isEmpty ? nil : byKey[k]
    }

    public func contains(_ raw: String) -> Bool { lookup(raw) != nil }

    /// Record a rich verdict. No-op (returns false) for verdicts below
    /// `minConfidence` or that resolve to an empty key. When a merchant is already
    /// known, the higher-confidence verdict wins; the raw descriptor is always
    /// added to the profile's alias list.
    @discardableResult
    public mutating func learn(_ c: ClaudeCategorization,
                               minConfidence: Double = learnThreshold,
                               at date: Date = Date()) -> Bool {
        guard c.confidence >= minConfidence else { return false }
        let k = Self.key(for: c.merchant)
        guard !k.isEmpty else { return false }

        let display = (c.cleanMerchant?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
            ?? { let n = MerchantNormalizer.normalize(c.merchant); return n.isEmpty ? c.merchant : n }()
        let primary = c.primaryCategory ?? c.category

        var profile = byKey[k] ?? MerchantProfile(merchant: display,
                                                  primaryCategory: primary,
                                                  confidence: 0, aliases: [], updatedAt: date)
        // The stronger verdict is authoritative.
        if c.confidence >= profile.confidence {
            profile.merchant = display
            profile.business = c.business ?? profile.business
            profile.primaryCategory = primary
            profile.secondaryCategory = c.secondaryCategory ?? profile.secondaryCategory
            profile.confidence = c.confidence
            profile.updatedAt = date
        }
        if !profile.aliases.contains(c.merchant) { profile.aliases.append(c.merchant) }
        byKey[k] = profile
        // keep the raw variant resolvable directly too
        let rawKey = Self.key(for: c.merchant)
        if !rawKey.isEmpty { byKey[rawKey] = profile }
        return true
    }

    // MARK: - Persistence

    private struct Snapshot: Codable { var version: Int; var profiles: [MerchantProfile] }
    private static let snapshotVersion = 1

    /// Load a KB from disk. A missing or unreadable file yields an empty KB — the
    /// steady state before any merchant has been learned.
    public static func load(from url: URL) -> MerchantKnowledgeBase {
        guard let data = try? Data(contentsOf: url) else { return MerchantKnowledgeBase() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let snap = try? decoder.decode(Snapshot.self, from: data) else {
            return MerchantKnowledgeBase()
        }
        return MerchantKnowledgeBase(profiles: snap.profiles)
    }

    /// Persist atomically. Best-effort — a write failure just means the next run
    /// re-learns the same merchants; the KB is a cache, not the source of truth.
    public func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Snapshot(version: Self.snapshotVersion,
                                                      profiles: profiles)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
