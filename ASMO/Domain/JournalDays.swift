import Foundation

enum JournalDays {
    static func ordered(endingAt anchor: PlanDate, recorded: Set<PlanDate>, calendar: Calendar,
                        recentCount: Int = 7) -> [PlanDate] {
        guard let date = anchor.dayOnly.date(in: calendar), recentCount > 0 else { return [] }
        let recent = (0..<recentCount).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: date).map { PlanDate.from($0, calendar: calendar) }
        }
        guard let last = recent.last else { return [] }
        return recent + Set(recorded.lazy.map(\.dayOnly).filter { $0.day != nil && $0 < last }).sorted(by: >)
    }

    static func window(around anchor: PlanDate, before: Int, after: Int, calendar: Calendar) -> [PlanDate] {
        guard before >= 0, after >= 0, let date = anchor.dayOnly.date(in: calendar) else { return [] }
        return (-before...after).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: date).map { PlanDate.from($0, calendar: calendar) }
        }.filter { (1...9999).contains($0.year) }
    }

    /// "2026-11-14" → that day; "2027-01" → the month (a plan for sometime that month). Read by hand, not by
    /// pattern: it runs for every page on every redraw.
    static func date(forKey key: String) -> PlanDate? {
        let bytes = Array(key.utf8)
        guard bytes.count == 7 || bytes.count == 10 else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let byte = bytes[index]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard bytes[4] == 45, let year = number(0..<4), let month = number(5..<7) else { return nil }
        if bytes.count == 7 {
            guard (1...12).contains(month) else { return nil }
            return PlanDate(year: year, month: month, day: nil)
        }
        guard bytes[7] == 45, let day = number(8..<10) else { return nil }
        return PlanDate(year: year, month: month, day: day)
    }
}

struct JournalArchiveText: Equatable, Sendable {
    var text: String
    var completed: Bool

    init(_ raw: String) {
        let text = raw.trimmed
        completed = text.count >= 4 && text.hasPrefix("~~") && text.hasSuffix("~~")
        self.text = completed ? String(text.dropFirst(2).dropLast(2)) : text
    }

    var encoded: String { completed ? "~~\(text)~~" : text }
}

/// The app is 逐日 (English name ASMO). The data store, iCloud container and Reminders list keep "ASMO".
enum AppName {
    static let display = "逐日"
    static let english = "ASMO"
    /// The main window's title (also how the app finds its window).
    static let window = "逐日"
}
