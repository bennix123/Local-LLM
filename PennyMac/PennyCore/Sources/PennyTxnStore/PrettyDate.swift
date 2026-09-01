// PrettyDate — the ONE way dates read in answers, on both platforms:
// "8th September 2026", never "2026-09-08" (2026-09-01 request: name the
// month, ordinal day). Falls back to the input untouched when it isn't an
// ISO day, so it can never mangle a value it doesn't understand.
import Foundation

public enum PrettyDate {

    static let monthNamesFull = ["", "January", "February", "March", "April",
                                 "May", "June", "July", "August", "September",
                                 "October", "November", "December"]

    /// "2026-09-08" → "8th September 2026"
    public static func long(_ iso: String) -> String {
        let p = iso.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, (1...12).contains(p[1]), (1...31).contains(p[2]) else { return iso }
        return "\(ordinal(p[2])) \(monthNamesFull[p[1]]) \(p[0])"
    }

    /// "2026-09" → "September 2026"
    public static func month(_ yyyymm: String) -> String {
        let p = yyyymm.split(separator: "-").compactMap { Int($0) }
        guard p.count >= 2, (1...12).contains(p[1]) else { return yyyymm }
        return "\(monthNamesFull[p[1]]) \(p[0])"
    }

    /// 8 → "8th", 21 → "21st", 12 → "12th"
    public static func ordinal(_ day: Int) -> String {
        let suffix: String
        switch day % 100 {
        case 11, 12, 13: suffix = "th"
        default:
            switch day % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(day)\(suffix)"
    }
}
