import Foundation

struct PlanDate: Codable, Hashable, Comparable, Sendable {
    var year: Int
    var month: Int
    var day: Int?
    var hour: Int?
    var minute: Int?

    var key: String {
        String(format: "%04d-%02d", year, month) + (day.map { String(format: "-%02d", $0) } ?? "")
    }

    var label: String {
        "\(year)年\(month)月" + (day.map { "\($0)日" } ?? "") +
        (hour.map { String(format: " %02d:%02d", $0, minute ?? 0) } ?? "")
    }

    var dayOnly: PlanDate { PlanDate(year: year, month: month, day: day) }
    var minuteOfDay: Int? { hour.map { $0 * 60 + (minute ?? 0) } }

    func followingToday(from previous: PlanDate, to current: PlanDate) -> PlanDate {
        self == previous ? current : self
    }

    /// The order of `key` (a month before its days), then the time; compared as numbers (formatting keys made
    /// sorting years of days slow).
    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day ?? 0, lhs.hour ?? -1, lhs.minute ?? -1)
            < (rhs.year, rhs.month, rhs.day ?? 0, rhs.hour ?? -1, rhs.minute ?? -1)
    }

    static func from(_ date: Date, calendar: Calendar, includeTime: Bool = false) -> Self {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return Self(year: components.year ?? 2000, month: components.month ?? 1, day: components.day,
                    hour: includeTime ? components.hour : nil, minute: includeTime ? components.minute : nil)
    }

    func date(in calendar: Calendar) -> Date? {
        guard (1...9999).contains(year), (1...12).contains(month),
              (1...31).contains(day ?? 1), (0...23).contains(hour ?? 0),
              (0...59).contains(minute ?? 0) else { return nil }
        let components = DateComponents(year: year, month: month, day: day ?? 1, hour: hour ?? 12, minute: minute ?? 0)
        guard let date = calendar.date(from: components) else { return nil }
        let actual = Self.from(date, calendar: calendar, includeTime: true)
        guard actual.year == year, actual.month == month, actual.day == (day ?? 1),
              hour == nil || (actual.hour == hour && actual.minute == (minute ?? 0)) else { return nil }
        return date
    }
}

struct CaptureClock: Sendable {
    #if DEBUG
    /// Debug builds: moves "now" (the nav driver's "clock:SECONDS"), for testing midnight without waiting for it.
    nonisolated(unsafe) static var debugShift: TimeInterval = 0
    var now: Date = Date.now.addingTimeInterval(CaptureClock.debugShift)
    #else
    var now: Date = .now
    #endif
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    var today: PlanDate { PlanDate.from(now, calendar: calendar) }

    func offset(days: Int) -> PlanDate? {
        calendar.date(byAdding: .day, value: days, to: now).map { PlanDate.from($0, calendar: calendar) }
    }

    func offset(months: Int) -> PlanDate? {
        calendar.date(byAdding: .month, value: months, to: now).map {
            let day = PlanDate.from($0, calendar: calendar)
            return PlanDate(year: day.year, month: day.month)
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    func match(_ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let result = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return (0..<result.numberOfRanges).map { index in
            Range(result.range(at: index), in: self).map { String(self[$0]) } ?? ""
        }
    }
}
