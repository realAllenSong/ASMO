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

    /// "2026-11-14" → that day; "2027-01" → the month (a plan for sometime that month).
    static func date(forKey key: String) -> PlanDate? {
        if let parts = key.match(#"^(\d{4})-(\d{2})$"#), let year = Int(parts[1]), let month = Int(parts[2]), (1...12).contains(month) {
            return PlanDate(year: year, month: month, day: nil)
        }
        guard let parts = key.match(#"^(\d{4})-(\d{2})-(\d{2})$"#),
              let year = Int(parts[1]), let month = Int(parts[2]), let day = Int(parts[3]) else { return nil }
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
