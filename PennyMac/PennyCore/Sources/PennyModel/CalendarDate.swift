import Foundation

/// A timezone-free calendar date — year, month, day, with no time, zone, or
/// locale (architecture layer L1, Amendment 01).
///
/// Statement and transaction dates are calendar dates, not instants:
/// representing "15 June" as a `Foundation.Date` would force a timezone choice
/// and let "which day / which month" queries drift across zones. `CalendarDate`
/// removes that whole class of bug. It is `Codable` as an ISO `"YYYY-MM-DD"`
/// string — stable, human-readable, and diff-friendly on disk.
///
/// It is a pure value object: it stores the components as given and performs no
/// validation or calendar arithmetic (that is not the model's job).
public struct CalendarDate: Hashable, Comparable, Codable, Sendable {

    public let year: Int
    public let month: Int   // 1...12
    public let day: Int     // 1...31

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    // Ordered chronologically by (year, month, day).
    public static func < (lhs: CalendarDate, rhs: CalendarDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    // MARK: Codable — an ISO "YYYY-MM-DD" string (no time, no zone).
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "CalendarDate: expected \"YYYY-MM-DD\", got \"\(string)\"")
        }
        self.init(year: year, month: month, day: day)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(format: "%04d-%02d-%02d", year, month, day))
    }
}

/// An inclusive range of calendar dates (`start...end`) — the shape for statement
/// periods and date-range filters (Amendment 01). A pure predicate type;
/// `contains` is its fundamental operation. Amount ranges use
/// `ComparableRange<Decimal>` instead.
public struct CalendarDateRange: Hashable, Codable, Sendable {

    public let start: CalendarDate
    public let end: CalendarDate

    public init(start: CalendarDate, end: CalendarDate) {
        self.start = start
        self.end = end
    }

    /// Whether `date` falls within `start...end`, inclusive.
    public func contains(_ date: CalendarDate) -> Bool {
        date >= start && date <= end
    }
}
