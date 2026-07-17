// BankProfiles — the profile registry (Stage 4 HLD) from parsers.py.
// Profiles are JSON files describing how to recognize a bank's statement.
import Foundation

public struct BankProfile {
    public let bankName: String
    public let textContainsAny: [String]
    public let headerRowContainsAny: [String]
    public let currency: String

    init?(json: [String: Any]) {
        guard let name = json["bank_name"] as? String else { return nil }
        bankName = name
        let ids = json["identifiers"] as? [String: Any] ?? [:]
        textContainsAny = ids["text_contains_any"] as? [String] ?? []
        headerRowContainsAny = ids["header_row_contains_any"] as? [String] ?? []
        currency = json["currency"] as? String ?? ""
    }
}

public final class BankProfileRegistry {
    let profiles: [BankProfile]

    /// Loads every *.json in `dir` (sorted by filename for determinism —
    /// Python's glob order is filesystem-dependent, but no two profiles
    /// tie-score on the same document in practice).
    public init(dir: String) {
        var loaded: [BankProfile] = []
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: dir) {
            for name in names.sorted() where name.hasSuffix(".json") {
                let path = (dir as NSString).appendingPathComponent(name)
                if let data = fm.contents(atPath: path),
                   let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let p = BankProfile(json: json) {
                    loaded.append(p)
                }
            }
        }
        profiles = loaded
    }

    /// match(): best profile above threshold, or nil.
    public func match(_ documentText: String) -> BankProfile? {
        let low = documentText.pyLower()
        var bestScore = 0.0
        var best: BankProfile? = nil
        for p in profiles {
            let textHits = p.textContainsAny.filter { low.pyContains($0.pyLower()) }.count
            // Bank-specific profiles must match their distinctive text, not just
            // generic UK header words (see parsers.py for the Barclays mishap).
            if !p.textContainsAny.isEmpty, textHits == 0 { continue }
            var score = min(0.5 * Double(textHits), 1.0)
            let headerScore = 0.25 * Double(p.headerRowContainsAny.filter { low.pyContains($0.pyLower()) }.count)
            score += min(headerScore, 1.0)
            if score > bestScore {
                bestScore = score
                best = p
            }
        }
        return bestScore >= 0.5 ? best : nil
    }
}
