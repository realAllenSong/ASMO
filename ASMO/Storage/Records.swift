import Foundation
import SwiftData

@Model
final class TaskRecord {
    var id: UUID = UUID()
    var title = ""
    var note = ""
    var year: Int?
    var month: Int?
    var day: Int?
    var hour: Int?
    var minute: Int?
    var completed = false
    var createdAt = Date.now
    var importKey: String?
    var pendingReminder: Date?
    var endMinute: Int?
    var calendarLinked = false
    var linkedEventStart: Date?
    var sourceText: String?
    /// Day key ("2026-11-05") the task was originally planned for, when it rolled forward unfinished.
    var carriedFrom: String?
    /// Set for a subtask: the task it sits under (up to three levels).
    var parentID: UUID?
    /// How the title was written on the page: "b" bold, "i" italic, "u" underline, "s" strike, "#RRGGBB" color.
    var titleStyle: String?

    var schedule: PlanDate? {
        get {
            guard let year, let month else { return nil }
            return PlanDate(year: year, month: month, day: day, hour: hour, minute: minute)
        }
        set {
            year = newValue?.year
            month = newValue?.month
            day = newValue?.day
            hour = newValue?.hour
            minute = newValue?.minute
        }
    }

    init(id: UUID = UUID(), title: String, note: String = "", schedule: PlanDate?, importKey: String? = nil, endMinute: Int? = nil) {
        self.id = id
        self.title = title
        self.note = note
        self.importKey = importKey
        self.endMinute = endMinute
        self.schedule = schedule
    }
}

@Model
final class DayNote {
    var dayKey = ""
    var body = ""
    var updatedAt = Date.now

    init(dayKey: String, body: String) {
        self.dayKey = dayKey
        self.body = body
    }
}

@Model
final class ArchiveDocument {
    var digest = ""
    var title = ""
    var raw = ""
    var defaultYear = 2026
    var addedAt = Date.now

    init(digest: String, title: String, raw: String, defaultYear: Int) {
        self.digest = digest
        self.title = title
        self.raw = raw
        self.defaultYear = defaultYear
    }
}

@Model
final class JournalArchiveEdit {
    var recordKey = ""
    var body = ""
    var updatedAt = Date.now

    init(recordKey: String, body: String) {
        self.recordKey = recordKey
        self.body = body
    }
}

@Model
final class ImportReceipt {
    var key = ""

    init(key: String) {
        self.key = key
    }
}

@Model
final class ImportantDateRecord {
    var id: UUID = UUID()
    var title = ""
    var kindRaw = ImportantDateKind.birthday.rawValue
    var systemRaw = ImportantDateSystem.gregorian.rawValue
    var month = 1
    var day = 1
    var year: Int?
    var timeZoneID: String?
    var original = ""
    var importKey: String?
    var alternativeMonth: Int?
    var alternativeDay: Int?

    var kind: ImportantDateKind {
        get { ImportantDateKind(rawValue: kindRaw) ?? .birthday }
        set { kindRaw = newValue.rawValue }
    }

    var rule: ImportantDateRule {
        get {
            ImportantDateRule(month: month, day: day, year: year,
                              system: ImportantDateSystem(rawValue: systemRaw) ?? .gregorian, timeZoneID: timeZoneID)
                .withDefaultTimeZone(for: kind)
        }
        set {
            month = newValue.month
            day = newValue.day
            year = newValue.year
            systemRaw = newValue.system.rawValue
            timeZoneID = newValue.timeZoneID
        }
    }

    /// When this date begins on the local day `day` (nil when it doesn't): by its rule, or by the Gregorian date
    /// written next to a lunar one ("11.19 奶奶（农历七月三十）" is kept on both).
    func start(onLocal day: PlanDate, calendar: Calendar) -> ImportantDateStart? {
        guard let begins = ImportantDateRule.dayBeginning(onLocal: day, zoneID: rule.timeZoneID, localCalendar: calendar),
              falls(on: begins.there, calendar: calendar) else { return nil }
        return begins
    }

    /// Whether `there`, a day in this date's own time zone, is the date.
    func falls(on there: PlanDate, calendar: Calendar) -> Bool {
        let rule = self.rule
        if rule.matches(there, calendar: calendar) { return true }
        return rule.system == .lunar && alternativeMonth == there.month && alternativeDay == there.day && alternativeDay != nil
    }

    init(title: String, kind: ImportantDateKind, rule: ImportantDateRule, original: String = "",
         importKey: String? = nil, alternative: ImportantDateRule? = nil) {
        self.title = title
        self.original = original
        self.importKey = importKey
        self.alternativeMonth = alternative?.month
        self.alternativeDay = alternative?.day
        self.kind = kind
        self.rule = rule
    }
}

/// A day's free page: rich text (RTFD) with images and links — the brainstorm space under the day's items.
@Model
final class DayPage {
    var dayKey = ""
    @Attribute(.externalStorage) var rtfd: Data?
    /// Lines written on the page that haven't been organized yet (one per line), for organizing after leaving.
    var pendingRaw: String?
    var updatedAt = Date.now

    init(dayKey: String, rtfd: Data?) {
        self.dayKey = dayKey
        self.rtfd = rtfd
    }
}

/// A repeating to-do ("每天八点大眼操", "每周一四练胸和肩"). Shown on matching days from `startDay` until `endDay`.
@Model
final class RoutineRecord {
    var id: UUID = UUID()
    var title = ""
    /// Calendar weekdays as digits, 1 = Sunday … 7 = Saturday ("1234567" = every day).
    var weekdaysRaw = "1234567"
    var startMinute: Int?
    var endMinute: Int?
    var startDay = ""
    var endDay: String?
    var order = 0
    var createdAt = Date.now
    /// Monthly on this day of the month (a shorter month: its last day); nil = by `weekdays`.
    var monthDay: Int?

    /// "每天", "每周一三", "每月15日".
    var ruleLabel: String { RoutineParser.label(weekdays, monthDay: monthDay) }

    var weekdays: Set<Int> {
        get { Set(weekdaysRaw.compactMap { $0.wholeNumberValue }.filter { (1...7).contains($0) }) }
        set { weekdaysRaw = newValue.sorted().map(String.init).joined() }
    }

    init(title: String, weekdays: Set<Int>, monthDay: Int? = nil, startMinute: Int?, endMinute: Int?, startDay: String, order: Int) {
        self.title = title
        self.monthDay = monthDay
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.startDay = startDay
        self.order = order
        self.weekdays = weekdays
    }

    func applies(to day: PlanDate, calendar: Calendar) -> Bool {
        guard day.key >= startDay, endDay.map({ day.key < $0 }) ?? true,
              let date = day.dayOnly.date(in: calendar) else { return false }
        if let monthDay {
            let last = calendar.range(of: .day, in: .month, for: date)?.count ?? 31
            return day.day == min(monthDay, last)
        }
        return weekdays.contains(calendar.component(.weekday, from: date))
    }
}

/// What happened to a routine on one day: done, or skipped ("今天不做了").
@Model
final class RoutineMark {
    var routineID: UUID = UUID()
    var dayKey = ""
    var skipped = false
    var updatedAt = Date.now

    init(routineID: UUID, dayKey: String, skipped: Bool) {
        self.routineID = routineID
        self.dayKey = dayKey
        self.skipped = skipped
    }
}

enum ASMOStore {
    static let cloudID = (Bundle.main.object(forInfoDictionaryKey: "ASMOCloudContainer") as? String ?? "").trimmed
    static let schema = Schema([TaskRecord.self, DayNote.self, ArchiveDocument.self, ImportReceipt.self, ImportantDateRecord.self, JournalArchiveEdit.self,
                                  RoutineRecord.self, RoutineMark.self, DayPage.self])

    static func open() throws -> ModelContainer {
        let cloud: ModelConfiguration.CloudKitDatabase = cloudID.isEmpty ? .none : .private(cloudID)
        var name = "ASMO"
        #if DEBUG
        // Debug runs can use a separate store (ASMO_TEST_STORE=1) so testing never touches real data;
        // ASMO_TEST_STORE=demo is another one, kept for screenshots with made-up items.
        switch ProcessInfo.processInfo.environment["ASMO_TEST_STORE"] {
        case "1": name = "ASMO-Test"
        case "demo": name = "ASMO-Demo"
        case "sync": name = "ASMO-Sync"     // an empty store for checking what iCloud brings down
        case "fresh": name = "ASMO-Fresh"   // a first launch: nothing written yet (the onboarding is tried on it)
        default: break
        }
        #endif
        #if os(macOS)
        // Outside the sandbox the store lives in ~/Library/Application Support/ASMO (copied over once from the
        // sandbox container earlier versions used).
        AppPaths.moveOutOfSandbox(name)
        var synced = name == "ASMO"
        #if DEBUG
        // Testing iCloud sync on a test store (ASMO_CLOUD=1): Debug builds use Apple's development environment,
        // which is separate from the data release builds sync.
        if ProcessInfo.processInfo.environment["ASMO_CLOUD"] == "1" { synced = true }
        #endif
        let config = ModelConfiguration(name, schema: schema, url: AppPaths.support.appendingPathComponent(name + ".store"),
                                        cloudKitDatabase: synced ? cloud : .none)
        #else
        let config = ModelConfiguration(name, schema: schema, cloudKitDatabase: name == "ASMO" ? cloud : .none)
        #endif
        return try ModelContainer(for: schema, configurations: [config])
    }
}
