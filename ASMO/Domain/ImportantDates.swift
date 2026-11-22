import Foundation

enum ImportantDateSystem: String, Codable, CaseIterable, Sendable {
    case gregorian, lunar

    var label: String { self == .lunar ? String(localized: "农历") : String(localized: "公历") }
}

enum ImportantDateKind: String, Codable, CaseIterable, Sendable {
    case birthday, anniversary, holiday

    var label: String {
        switch self {
        case .birthday: String(localized: "生日")
        case .anniversary: String(localized: "纪念日")
        case .holiday: String(localized: "节假日")
        }
    }

    var icon: String {
        switch self {
        case .birthday: "birthday.cake"
        case .anniversary: "sparkle"
        case .holiday: "flag"
        }
    }
}

enum ImportantDateTimeZone: String, CaseIterable {
    static let deviceID = "device"
    case china = "Asia/Shanghai"
    case eastern = "America/New_York"
    case central = "America/Chicago"
    case mountain = "America/Denver"
    case pacific = "America/Los_Angeles"

    var label: String {
        switch self {
        case .china: String(localized: "中国时间")
        case .eastern: String(localized: "美东时间")
        case .central: String(localized: "美中时间")
        case .mountain: String(localized: "美国山地时间")
        case .pacific: String(localized: "美西时间")
        }
    }

    static func label(for id: String?) -> String {
        guard let id, id != deviceID else { return String(localized: "跟随设备") }
        return Self(rawValue: id)?.label ?? TimeZone(identifier: id)?
            .localizedName(for: .generic, locale: Locale(identifier: "zh-Hans")) ?? id
    }

    static func resolve(_ id: String?, device: TimeZone) -> TimeZone? {
        guard let id, id != deviceID else { return device }
        return TimeZone(identifier: id)
    }

    static func offsetLabel(_ zone: TimeZone, at instant: Date) -> String {
        let minutes = zone.secondsFromGMT(for: instant) / 60
        return String(format: "UTC%@%02d:%02d", minutes < 0 ? "−" : "+", abs(minutes) / 60, abs(minutes) % 60)
    }
}

struct ImportantDateRule: Codable, Hashable, Sendable {
    var month: Int
    var day: Int
    var year: Int?
    var system: ImportantDateSystem = .gregorian
    var timeZoneID: String? = nil

    var label: String {
        let zone = timeZoneID.map { " · " + ImportantDateTimeZone.label(for: $0) } ?? ""
        return (year.map { String(localized: "\($0) 年 · ") } ?? String(localized: "每年 · ")) + String(localized: "\(system.label) \(month) 月 \(day) 日") + zone
    }

    func withDefaultTimeZone(for kind: ImportantDateKind) -> Self {
        guard kind == .birthday, timeZoneID == nil else { return self }
        var rule = self
        rule.timeZoneID = ImportantDateTimeZone.china.rawValue
        return rule
    }

    func time(on day: PlanDate, hour: Int, minute: Int, localCalendar: Calendar) -> Date? {
        guard matches(day, calendar: localCalendar) else { return nil }
        return Self.time(on: day, hour: hour, minute: minute, zoneID: timeZoneID, localCalendar: localCalendar)
    }

    static func time(on day: PlanDate, hour: Int, minute: Int, zoneID: String?, localCalendar: Calendar) -> Date? {
        var calendar = localCalendar
        guard let zone = ImportantDateTimeZone.resolve(zoneID, device: localCalendar.timeZone) else { return nil }
        calendar.timeZone = zone
        var wallTime = day.dayOnly
        wallTime.hour = hour
        wallTime.minute = minute
        return wallTime.date(in: calendar)
    }

    func isValid(calendar: Calendar) -> Bool {
        if system == .lunar { return year == nil && (1...12).contains(month) && (1...30).contains(day) }
        return PlanDate(year: year ?? 2000, month: month, day: day).date(in: calendar) != nil
    }

    func matches(_ date: PlanDate, calendar: Calendar) -> Bool {
        var sourceCalendar = calendar
        guard let zone = ImportantDateTimeZone.resolve(timeZoneID, device: calendar.timeZone) else { return false }
        sourceCalendar.timeZone = zone
        guard date.day != nil, let localNoon = date.dayOnly.date(in: sourceCalendar) else { return false }
        if system == .gregorian {
            return month == date.month && day == date.day && (year == nil || year == date.year)
        }
        var lunar = Calendar(identifier: .chinese)
        lunar.timeZone = sourceCalendar.timeZone
        let parts = lunar.dateComponents([.month, .day, .isLeapMonth], from: localNoon)
        guard parts.month == month, parts.isLeapMonth != true else { return false }
        // In a short lunar month, an anniversary on the 30th falls on its last day.
        let actualDay = day == 30 ? min(day, lunar.range(of: .day, in: .month, for: localNoon)?.count ?? day) : day
        return parts.day == actualDay
    }
}

/// A yearly date seen from where the reader is: the day it is there, and when that day begins here.
struct ImportantDateStart: Equatable, Sendable {
    /// The date in the date's own time zone.
    let there: PlanDate
    /// Minutes after local midnight at which that day begins there (0 when it begins with the local day).
    let minute: Int
    /// The moment it begins.
    let instant: Date
}

extension ImportantDateRule {
    /// Whether this date's day begins during the local day `day`, and when. A birthday kept in China time is the
    /// 22nd there from 11:00 on the 21st in New York: that is when to send wishes, so that is where it shows.
    func start(onLocal day: PlanDate, localCalendar: Calendar) -> ImportantDateStart? {
        guard let begins = Self.dayBeginning(onLocal: day, zoneID: timeZoneID, localCalendar: localCalendar),
              matches(begins.there, calendar: localCalendar) else { return nil }
        return begins
    }

    /// The day, in the time zone `zoneID`, whose first moment falls inside the local day `day` (there is one,
    /// except across a clock change): what any date kept in that zone is checked against.
    static func dayBeginning(onLocal day: PlanDate, zoneID: String?, localCalendar: Calendar) -> ImportantDateStart? {
        guard day.day != nil, let zone = ImportantDateTimeZone.resolve(zoneID, device: localCalendar.timeZone),
              let noon = day.dayOnly.date(in: localCalendar) else { return nil }
        let localStart = localCalendar.startOfDay(for: noon)
        guard let localEnd = localCalendar.date(byAdding: .day, value: 1, to: localStart) else { return nil }
        var there = localCalendar
        there.timeZone = zone
        let begins = there.startOfDay(for: localEnd.addingTimeInterval(-1))
        guard begins >= localStart else { return nil }
        return ImportantDateStart(there: PlanDate.from(begins, calendar: there),
                                  minute: Int(begins.timeIntervalSince(localStart) / 60), instant: begins)
    }
}

struct BirthdayGreetingTime: Equatable, Sendable {
    let instant: Date
    let recipient: PlanDate
    let local: PlanDate
    let recipientZone: TimeZone

    var crossesDateBoundary: Bool { recipient.dayOnly != local.dayOnly }
}

extension ImportantDateRule {
    func greeting(on birthday: PlanDate, at minute: Int, localCalendar: Calendar) -> BirthdayGreetingTime? {
        guard (0..<PlannerClockTime.minutesPerDay).contains(minute),
              let recipientZone = ImportantDateTimeZone.resolve(timeZoneID, device: localCalendar.timeZone),
              let instant = time(on: birthday, hour: minute / 60, minute: minute % 60,
                                 localCalendar: localCalendar) else { return nil }
        var recipientCalendar = localCalendar
        recipientCalendar.timeZone = recipientZone
        return BirthdayGreetingTime(instant: instant,
                                    recipient: PlanDate.from(instant, calendar: recipientCalendar, includeTime: true),
                                    local: PlanDate.from(instant, calendar: localCalendar, includeTime: true),
                                    recipientZone: recipientZone)
    }

    func suggestedGreeting(on birthday: PlanDate, after now: Date, localCalendar: Calendar) -> BirthdayGreetingTime? {
        // Prefer the recipient's morning. Offer another moment on their birthday
        // when that would be too early, too late, or already past for the sender.
        let future = [9, 20, 12, 18, 21, 22].compactMap {
            greeting(on: birthday, at: $0 * 60, localCalendar: localCalendar)
        }.filter { $0.instant > now }
        return future.first { (8...22).contains($0.local.hour ?? 0) } ?? future.first
    }
}

struct ImportantDateDraft: Identifiable, Sendable {
    let id: String
    let title: String
    let kind: ImportantDateKind
    let rule: ImportantDateRule
    let gregorianAlternative: ImportantDateRule?
    let original: String
}

struct ImportantDateImport: Sendable {
    let entries: [ImportantDateDraft]
    let unparsed: [String]

    static func parse(_ raw: String, calendar: Calendar) -> Self {
        var entries: [ImportantDateDraft] = []
        var unparsed: [String] = []
        for line in raw.components(separatedBy: .newlines).map(\.trimmed) where !line.isEmpty {
            if ["生日归档", "重要日期", "重要日期归档", "纪念日归档"].contains(line) { continue }
            if let entry = entry(line, calendar: calendar) { entries.append(entry) }
            else { unparsed.append(line) }
        }
        return Self(entries: entries, unparsed: unparsed)
    }

    private static func entry(_ line: String, calendar: Calendar) -> ImportantDateDraft? {
        var title: String
        let solar: ImportantDateRule
        if let parts = line.match(#"^(\d{1,2})[.．/月](\d{1,2})[日号]?\s*[:：]\s*(.+)$"#),
           let month = Int(parts[1]), let day = Int(parts[2]) {
            solar = ImportantDateRule(month: month, day: day)
            title = parts[3]
        } else if let parts = line.match(#"^(.+?)\s+(\d{4})[.．/\-年](\d{1,2})[.．/\-月](\d{1,2})[日号]?$"#),
                  let month = Int(parts[3]), let day = Int(parts[4]) {
            solar = ImportantDateRule(month: month, day: day)
            title = parts[1]
        } else { return nil }
        guard solar.isValid(calendar: calendar) else { return nil }

        var lunar: ImportantDateRule?
        let lunarPattern = #"(?:(?:农历|阴历)\s*([一二两三四五六七八九十\d]+)月\s*([一二两三四五六七八九十\d]+)[日号]?|([一二两三四五六七八九十\d]+)月\s*([一二两三四五六七八九十\d]+)[日号]?\s*(?:农历|阴历))"#
        if let match = title.match(lunarPattern) {
            guard let month = CaptureParser.number(match[1].isEmpty ? match[3] : match[1]),
                  let day = CaptureParser.number(match[2].isEmpty ? match[4] : match[2]) else { return nil }
            let candidate = ImportantDateRule(month: month, day: day, system: .lunar)
            guard candidate.isValid(calendar: calendar) else { return nil }
            lunar = candidate
            title = title.replacingOccurrences(of: match[0], with: "")
        }

        title = title.replacingOccurrences(of: #"\s*\d{2,4}[.．/\-年]\d{1,2}[.．/\-月]\d{1,2}[日号]?\s*$"#,
                                           with: "", options: .regularExpression).trimmed
        guard !title.isEmpty else { return nil }
        let kind: ImportantDateKind
        if title.contains("忌日") || title.contains("纪念") || title.contains("周年") {
            kind = .anniversary
        } else if title.contains("节") || title.contains("假日") {
            kind = .holiday
        } else {
            kind = .birthday
            if !title.contains("生日") { title += "生日" }
        }
        let rule = lunar ?? solar
        let key = [title.lowercased(), kind.rawValue, rule.system.rawValue, "\(rule.month)", "\(rule.day)"].joined(separator: "|")
        return ImportantDateDraft(id: key, title: title, kind: kind, rule: rule,
                                  gregorianAlternative: lunar == nil ? nil : solar, original: line)
    }
}
