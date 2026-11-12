import Foundation

enum PlannerClockTime {
    static let minutesPerDay = 24 * 60

    static func parse(_ text: String) -> Int? {
        let value = text.trimmed.replacingOccurrences(of: "：", with: ":")
        let fields: (String, String)
        if let parts = value.match(#"^(\d{1,2}):(\d{1,2})$"#) {
            fields = (parts[1], parts[2])
        } else if value.match(#"^\d{1,2}$"#) != nil {
            fields = (value, "0")
        } else if value.match(#"^\d{3,4}$"#) != nil {
            fields = (String(value.dropLast(2)), String(value.suffix(2)))
        } else {
            return nil
        }
        guard let hour = Int(fields.0), let minute = Int(fields.1),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    static func label(_ minutes: Int) -> String {
        let clockMinutes = minutes % minutesPerDay
        return String(format: "%02d:%02d", clockMinutes / 60, clockMinutes % 60)
    }
}

struct PlannerTimeSelection: Equatable, Sendable {
    var start: Int?
    var end: Int?

    var label: String? {
        guard let start else { return nil }
        guard let end else { return PlannerClockTime.label(start) }
        let dayOffset = end / PlannerClockTime.minutesPerDay
        let offset = dayOffset == 0 ? "" : String(localized: " +\(dayOffset) 天")
        return PlannerClockTime.label(start) + "–" + PlannerClockTime.label(end) + offset
    }
}
