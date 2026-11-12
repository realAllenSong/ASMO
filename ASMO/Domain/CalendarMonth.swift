import Foundation

struct CalendarMonth: Sendable {
    let days: [PlanDate]
    let weekdays: [String]

    init(containing date: PlanDate, calendar: Calendar) {
        let labels = ["日", "一", "二", "三", "四", "五", "六"]
        let firstWeekday = (calendar.firstWeekday - 1) % labels.count
        weekdays = (0..<7).map { labels[($0 + firstWeekday) % labels.count] }
        let first = PlanDate(year: date.year, month: date.month, day: 1)
        guard let start = first.date(in: calendar),
              let range = calendar.range(of: .day, in: .month, for: start) else {
            days = []
            return
        }
        let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let count = ((leading + range.count + 6) / 7) * 7
        days = (0..<count).compactMap { index in
            calendar.date(byAdding: .day, value: index - leading, to: start).map { PlanDate.from($0, calendar: calendar) }
        }
    }
}
