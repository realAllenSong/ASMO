#if os(macOS)
import AppKit
import CryptoKit
import EventKit
import SwiftData

/// Keeps 逐日's items in Apple Calendar and Reminders, both ways: items with a time are events in a calendar named
/// 逐日, items with only a day are reminders in a list named 逐日 (both on iCloud, so they reach the phone, the
/// watch and Google Calendar if that account is added to Calendar). Moving an event or checking off a reminder
/// there changes the item here. What to do is decided by MirrorPlan; this class only reads and writes EventKit.
///
/// It runs a few seconds after the store is saved (never while typing: the page saves after a pause in writing)
/// and when Calendar or Reminders change.
@MainActor
final class CalendarMirror {
    static let shared = CalendarMirror()

    private let store = EKEventStore()
    private var context: ModelContext?
    private var pending: DispatchWorkItem?
    private var running = false
    private var again = false
    /// Changes EventKit reports right after this mirror wrote are its own: not a reason to run again.
    private var quietUntil = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    /// What the last run did (for `asmo mirror`).
    private(set) var summary: [String: Any] = ["state": "not run yet"]

    static let enabledKey = "appleMirror"
    var enabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    private var test: Bool { ProcessInfo.processInfo.environment["ASMO_TEST_STORE"] != nil }
    private var name: String { test ? "逐日（测试）" : "逐日" }
    private var recordsURL: URL { AppPaths.support.appendingPathComponent(test ? "apple-mirror-test.json" : "apple-mirror.json") }

    func start(_ container: ModelContainer) {
        guard context == nil else { return }
        // The test store (a copy of real data) stays out of the real Calendar unless asked for.
        if test && ProcessInfo.processInfo.environment["ASMO_TEST_MIRROR"] == nil { return }
        context = container.mainContext
        observers.append(NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CalendarMirror.shared.schedule(after: 4) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated {
                let mirror = CalendarMirror.shared
                guard Date.now > mirror.quietUntil else { return }
                mirror.schedule(after: 1.5)
            }
        })
        // The Mac went to another time zone (New York to Beijing): the days are read in the new one, and the
        // yearly dates are put at the moment their day begins there.
        observers.append(NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                NSTimeZone.resetSystemTimeZone()
                CalendarMirror.shared.schedule(after: 1)
            }
        })
        schedule(after: 3)
        // A change on the phone reaches this Mac through iCloud and is announced; a check every two minutes
        // catches one that wasn't (the Mac asleep, the notice dropped).
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
            MainActor.assumeIsolated { CalendarMirror.shared.schedule(after: 0) }
        }
    }
    private var timer: Timer?

    func schedule(after delay: TimeInterval) {
        guard enabled else { return }
        pending?.cancel()
        let work = DispatchWorkItem { Task { @MainActor in await CalendarMirror.shared.run() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// One pass: read both sides, write the differences. Returns what it did.
    @discardableResult
    func run() async -> [String: Any] {
        guard enabled else { summary = ["state": "off"]; return summary }
        if running { again = true; return summary }
        running = true
        defer {
            running = false
            if again { again = false; schedule(after: 1) }
        }
        do {
            summary = try await pass()
        } catch {
            summary = ["state": "error", "error": error.localizedDescription, "while": stage]
        }
        return summary
    }

    // MARK: One pass

    private struct Problem: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// What the pass was doing (said with an error).
    private var stage = ""

    private func pass() async throws -> [String: Any] {
        guard let context else { throw Problem(message: "The store isn't open.") }
        stage = "asking for access"
        try await authorize()
        stage = "finding the 逐日 calendar and list"
        let calendar = try ensure(.event)
        let list = try ensure(.reminder)
        let clock = CaptureClock()
        let cal = clock.calendar
        let today = clock.today
        guard let todayDate = today.date(in: cal),
              // From today on: what's past stays where it is (nothing to keep in step there).
              let from = Optional(cal.startOfDay(for: todayDate)),
              let until = cal.date(byAdding: .day, value: 400, to: cal.startOfDay(for: todayDate)) else {
            throw Problem(message: "Couldn't work out the dates.")
        }
        func inWindow(_ item: MirrorItem) -> Bool {
            guard let date = cal.date(from: DateComponents(year: item.year, month: item.month, day: item.day)) else { return false }
            return date >= from && date < until
        }

        // Made there, in the 逐日 calendar or list (on the phone, by Siri): it becomes an item here first.
        stage = "taking in what was added in Calendar and Reminders"
        var records = loadRecords()
        let adopted = try await adopt(calendar: calendar, list: list, from: from, until: until, today: today, cal: cal,
                                      context: context, records: &records)

        // 逐日's side: top-level items with a day; their sub-items go in the notes.
        stage = "reading 逐日's items"
        let tasks = try context.fetch(FetchDescriptor<TaskRecord>())
        let children = Dictionary(grouping: tasks.filter { $0.parentID != nil }) { $0.parentID! }
        var wanted: [UUID: MirrorItem] = [:]
        var byID: [UUID: TaskRecord] = [:]
        for task in tasks where task.parentID == nil && !task.calendarLinked {
            guard let plan = task.schedule else { continue }
            let subs = (children[task.id] ?? []).sorted { $0.createdAt < $1.createdAt }
                .map { ($0.completed ? "✓ " : "· ") + $0.title }
            let notes = ([task.note.trimmed] + subs).filter { !$0.isEmpty }.joined(separator: "\n")
            guard let item = MirrorItem.from(title: task.title, year: plan.year, month: plan.month, day: plan.day,
                                             hour: plan.hour, minute: plan.minute, endMinute: task.endMinute,
                                             done: task.completed, notes: notes), inWindow(item) else { continue }
            wanted[task.id] = item
            byID[task.id] = task
        }

        // Repeating items, a week of them: each day it repeats is a reminder (or an event, with a time) of its own,
        // so today's is in "Today" on the phone. Checked off there, it is done here for that day. A day skipped
        // here isn't written; yesterday's, left undone, goes (the settling below removes it).
        var routineDays: [UUID: (routine: UUID, day: String)] = [:]
        let routines = try context.fetch(FetchDescriptor<RoutineRecord>())
        if !routines.isEmpty {
            let marks = Dictionary(try context.fetch(FetchDescriptor<RoutineMark>()).map { ($0.routineID.uuidString + "|" + $0.dayKey, $0) },
                                   uniquingKeysWith: { first, _ in first })
            for offset in 0..<7 {
                guard let date = cal.date(byAdding: .day, value: offset, to: todayDate) else { continue }
                let day = PlanDate.from(date, calendar: cal)
                for routine in routines where routine.applies(to: day, calendar: cal) {
                    let mark = marks[routine.id.uuidString + "|" + day.key]
                    if mark?.skipped == true { continue }
                    guard let item = MirrorItem.from(title: routine.title, year: day.year, month: day.month, day: day.day,
                                                     hour: routine.startMinute.map { $0 / 60 }, minute: routine.startMinute.map { $0 % 60 },
                                                     endMinute: routine.endMinute, done: mark != nil, notes: routine.ruleLabel) else { continue }
                    let id = Self.occurrence(of: routine.id, on: day)
                    wanted[id] = item
                    routineDays[id] = (routine.id, day.key)
                }
            }
        }

        // Birthdays and other yearly dates, written only: an event at the moment the day begins where it is kept
        // (a birthday in China on the 22nd is 11:00 on the 21st in New York), with an alert, so the phone says so.
        var oneWay = Set<UUID>()
        let dates = try context.fetch(FetchDescriptor<ImportantDateRecord>())
        if !dates.isEmpty {
            let zones = Dictionary(grouping: dates) { $0.rule.timeZoneID ?? ImportantDateTimeZone.deviceID }
            for offset in 0..<400 {
                guard let date = cal.date(byAdding: .day, value: offset, to: todayDate) else { continue }
                let day = PlanDate.from(date, calendar: cal)
                for (zoneID, kept) in zones {
                    guard let begins = ImportantDateRule.dayBeginning(onLocal: day, zoneID: zoneID, localCalendar: cal) else { continue }
                    for record in kept where record.falls(on: begins.there, calendar: cal) && !record.title.trimmed.isEmpty {
                        let id = Self.occurrence(of: record.id, on: begins.there)
                        let elsewhere = begins.minute != 0 || begins.there != day
                        let zone = ImportantDateTimeZone.label(for: record.rule.timeZoneID)
                        let notes = elsewhere
                            ? String(localized: "\(zone) \(begins.there.month)月\(begins.there.day ?? 1)日") : ""
                        wanted[id] = MirrorItem(kind: .event, title: record.title.trimmed, year: day.year, month: day.month,
                                                day: day.day ?? 1, start: begins.minute != 0 ? begins.minute : nil,
                                                end: begins.minute != 0 ? min(begins.minute + 30, 24 * 60 - 1) : nil,
                                                notes: notes)
                        oneWay.insert(id)
                    }
                }
            }
        }

        // Apple's side: every copy that carries a 逐日 marker — all the reminders in the list, and events from two
        // months back (a to-do rolled over to today must find yesterday's reminder, not make another).
        stage = "reading Calendar and Reminders"
        var copies: [UUID: [MirrorCopy]] = [:]
        var objects: [String: EKCalendarItem] = [:]
        let back = cal.date(byAdding: .day, value: -60, to: from) ?? from
        var floated = false
        for event in store.events(matching: store.predicateForEvents(withStart: back, end: until, calendars: [calendar])) {
            guard let id = Self.marker(event), objects[event.calendarItemIdentifier] == nil else { continue }
            // Events written before items' times floated: made floating once, at the same time on the clock.
            if !oneWay.contains(id), !event.isAllDay, event.timeZone != nil {
                let (start, end) = (event.startDate, event.endDate)
                event.timeZone = nil
                event.startDate = start
                event.endDate = end
                if (try? store.save(event, span: .thisEvent, commit: false)) != nil { floated = true }
            }
            copies[id, default: []].append(MirrorCopy(item: Self.item(event, calendar: cal), identifier: event.calendarItemIdentifier))
            objects[event.calendarItemIdentifier] = event
        }
        if floated { try store.commit() }
        for reminder in await reminders(in: list) {
            guard let id = Self.marker(reminder), let item = Self.item(reminder) else { continue }
            copies[id, default: []].append(MirrorCopy(item: item, identifier: reminder.calendarItemIdentifier))
            objects[reminder.calendarItemIdentifier] = reminder
        }
        let settled = MirrorPlan.settle(copies: copies, wanted: wanted, today: (today.year, today.month, today.day ?? 1))
        let present = settled.present
        let extras = settled.stale.compactMap { objects[$0] }

        let actions = MirrorPlan.actions(wanted: wanted, present: present, written: records, oneWay: oneWay,
                                         checkOnly: Set(routineDays.keys))
        var counts = ["created": 0, "updated": 0, "removed": 0, "pulled": 0, "released": 0, "deleted": 0, "adopted": adopted,
                      "tidied": extras.count]
        var deletedAny = false
        var pulledAny = false
        for action in actions {
            stage = "writing: \(action)"
            switch action {
            case .create(let id, let item):
                let made: EKCalendarItem = item.kind == .event ? EKEvent(eventStore: store) : EKReminder(eventStore: store)
                made.calendar = item.kind == .event ? calendar : list
                made.url = URL(string: "asmo://mirror/\(id.uuidString)")
                write(item, to: made, calendar: cal, new: true, occasion: oneWay.contains(id))
                try save(made)
                records[id] = MirrorRecord(item: item, identifier: made.calendarItemIdentifier)
                counts["created", default: 0] += 1
            case .update(let id, let item, let identifier):
                guard let existing = objects[identifier] else { continue }
                write(item, to: existing, calendar: cal, new: false, occasion: oneWay.contains(id))
                try save(existing)
                records[id] = MirrorRecord(item: item, identifier: existing.calendarItemIdentifier)
                counts["updated", default: 0] += 1
            case .remove(let id, let identifier, _):
                if let existing = objects[identifier] { try remove(existing) }
                if wanted[id] == nil { records[id] = nil }
                counts["removed", default: 0] += 1
            case .pull(let id, let item):
                if let occurrence = routineDays[id] {
                    // One day of a repeating item checked (or unchecked) there: that day's mark here.
                    let routineID = occurrence.routine, dayKey = occurrence.day
                    let existing = try context.fetch(FetchDescriptor<RoutineMark>(
                        predicate: #Predicate { $0.routineID == routineID && $0.dayKey == dayKey }))
                    if item.done {
                        if existing.isEmpty { context.insert(RoutineMark(routineID: routineID, dayKey: dayKey, skipped: false)) }
                        else { existing.forEach { $0.skipped = false } }
                    } else {
                        existing.filter { !$0.skipped }.forEach { context.delete($0) }
                    }
                    records[id] = MirrorRecord(item: item, identifier: present[id]?.identifier ?? "")
                    pulledAny = true
                    counts["pulled", default: 0] += 1
                    continue
                }
                guard let task = byID[id] else { continue }
                apply(item, to: task)
                records[id] = MirrorRecord(item: item, identifier: present[id]?.identifier ?? "")
                pulledAny = true
                counts["pulled", default: 0] += 1
            case .release(let id):
                records[id]?.released = true
                counts["released", default: 0] += 1
            case .deleteHere(let id, let identifier):
                // Only if it's really gone (not moved to another calendar or list, or far out of the window).
                if store.calendarItem(withIdentifier: identifier) != nil {
                    records[id]?.released = true
                    counts["released", default: 0] += 1
                    continue
                }
                guard let task = byID[id] else { continue }
                for child in children[id] ?? [] { context.delete(child) }
                context.delete(task)
                records[id] = nil
                deletedAny = true
                counts["deleted", default: 0] += 1
            }
        }
        stage = "removing old copies"
        for extra in extras { try remove(extra) }
        stage = "saving"
        let wroteThere = actions.contains { action in
            switch action {
            case .create, .update, .remove: return true
            case .pull, .release, .deleteHere: return false
            }
        }
        if wroteThere || !extras.isEmpty {
            quietUntil = .now.addingTimeInterval(3)
            try store.commit()
        }
        if pulledAny || deletedAny { try context.save() }
        saveRecords(records)
        return ["state": "ok", "calendar": calendar.title, "list": list.title,
                "items": wanted.count - oneWay.count - routineDays.count,
                "dates": oneWay.count, "routineDays": routineDays.count,
                "events": wanted.filter { $0.value.kind == .event && !oneWay.contains($0.key) }.count,
                "reminders": wanted.values.filter { $0.kind == .reminder }.count]
            .merging(counts.mapValues { $0 as Any }) { $1 }
    }

    /// Reminders and events put straight into the 逐日 list or calendar (no 逐日 marker yet) become items: a
    /// reminder on its due day (no day: today, and it gets today as its day there too), an event at its time.
    /// Repeating events stay Calendar's own.
    private func adopt(calendar: EKCalendar, list: EKCalendar, from: Date, until: Date, today: PlanDate, cal: Calendar,
                       context: ModelContext, records: inout [UUID: MirrorRecord]) async throws -> Int {
        var made: [(EKCalendarItem, MirrorItem)] = []
        for reminder in await reminders(in: list) where Self.marker(reminder) == nil && !reminder.isCompleted {
            if (reminder.title ?? "").trimmed.isEmpty { continue }
            if reminder.dueDateComponents == nil && reminder.startDateComponents == nil {
                let due = DateComponents(calendar: cal, year: today.year, month: today.month, day: today.day)
                reminder.startDateComponents = due
                reminder.dueDateComponents = due
            }
            guard let item = Self.item(reminder) else { continue }
            made.append((reminder, item))
        }
        let events = store.events(matching: store.predicateForEvents(withStart: from, end: until, calendars: [calendar]))
        for event in events where Self.marker(event) == nil && !event.hasRecurrenceRules {
            if (event.title ?? "").trimmed.isEmpty { continue }
            made.append((event, Self.item(event, calendar: cal)))
        }
        guard !made.isEmpty else { return 0 }
        for (object, item) in made {
            let task = TaskRecord(title: item.plainTitle.trimmed, note: item.notes.trimmed,
                                  schedule: PlanDate(year: item.year, month: item.month, day: item.day))
            apply(item, to: task)
            context.insert(task)
            object.url = URL(string: "asmo://mirror/\(task.id.uuidString)")
            try save(object)
            records[task.id] = MirrorRecord(item: item, identifier: object.calendarItemIdentifier)
        }
        quietUntil = .now.addingTimeInterval(3)
        try store.commit()
        try context.save()
        saveRecords(records)
        return made.count
    }

    // MARK: EventKit

    private func authorize() async throws {
        if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
            guard try await store.requestFullAccessToEvents() else { throw Problem(message: "No access to Calendar.") }
        }
        if EKEventStore.authorizationStatus(for: .reminder) != .fullAccess {
            guard try await store.requestFullAccessToReminders() else { throw Problem(message: "No access to Reminders.") }
        }
    }

    /// The 逐日 calendar or list, made once (on iCloud when there is one, so it reaches the other devices).
    private func ensure(_ type: EKEntityType) throws -> EKCalendar {
        let key = "appleMirror.\(type == .event ? "calendar" : "list").\(test ? "test" : "main")"
        if let id = UserDefaults.standard.string(forKey: key), let existing = store.calendar(withIdentifier: id) { return existing }
        if let existing = store.calendars(for: type).first(where: { $0.title == name && $0.allowsContentModifications }) {
            UserDefaults.standard.set(existing.calendarIdentifier, forKey: key)
            return existing
        }
        let made = EKCalendar(for: type, eventStore: store)
        made.title = name
        // An account that already holds this kind of list (an iCloud account may hold calendars but not reminders,
        // or the other way round), iCloud first, then wherever new items go by default.
        let fallback = type == .event ? store.defaultCalendarForNewEvents?.source : store.defaultCalendarForNewReminders()?.source
        let able = store.sources.filter { !$0.calendars(for: type).isEmpty }
        let iCloud = able.first { $0.sourceType == .calDAV && $0.title.compare("iCloud", options: .caseInsensitive) == .orderedSame }
        var candidates = [iCloud, fallback].compactMap { $0 } + able
        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0.sourceIdentifier).inserted }
        var lastError: Error = Problem(message: "No account for a \(type == .event ? "calendar" : "reminders list").")
        made.cgColor = NSColor(srgbRed: 0.55, green: 0.42, blue: 0.95, alpha: 1).cgColor
        var saved = false
        for source in candidates {
            made.source = source
            do { try store.saveCalendar(made, commit: true); saved = true; break } catch { lastError = error }
        }
        guard saved else { throw lastError }
        UserDefaults.standard.set(made.calendarIdentifier, forKey: key)
        return made
    }

    private func reminders(in list: EKCalendar) async -> [EKReminder] {
        let predicate = store.predicateForReminders(in: [list])
        return await withCheckedContinuation { continuation in
            _ = store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
        }
    }

    private func save(_ item: EKCalendarItem) throws {
        if let event = item as? EKEvent { try store.save(event, span: .thisEvent, commit: false) }
        else if let reminder = item as? EKReminder { try store.save(reminder, commit: false) }
    }

    private func remove(_ item: EKCalendarItem) throws {
        if let event = item as? EKEvent { try store.remove(event, span: .thisEvent, commit: false) }
        else if let reminder = item as? EKReminder { try store.remove(reminder, commit: false) }
    }

    /// One id for each time a yearly date comes round (the date's id and the day it falls on, mixed).
    private static func occurrence(of id: UUID, on day: PlanDate) -> UUID {
        let digest = SHA256.hash(data: Data((id.uuidString + "|" + day.key).utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private func write(_ item: MirrorItem, to target: EKCalendarItem, calendar cal: Calendar, new: Bool, occasion: Bool = false) {
        target.title = item.title
        target.notes = item.notes.isEmpty ? nil : item.notes
        if let event = target as? EKEvent {
            let day = DateComponents(year: item.year, month: item.month, day: item.day)
            let start = item.start ?? 0
            let end = item.end ?? start + 60
            // An item's time is the time on the clock wherever the Mac and the phone are (14:00 is 14:00 in New
            // York and in Beijing): a floating event. A yearly date begins at a moment in its own zone: fixed.
            event.timeZone = occasion ? cal.timeZone : nil
            event.isAllDay = item.start == nil
            event.startDate = cal.date(from: day).flatMap { cal.date(byAdding: .minute, value: start, to: $0) }
            event.endDate = cal.date(from: day).flatMap { cal.date(byAdding: .minute, value: end, to: $0) }
            // A new event alerts at its time, like one made in Calendar would by default.
            if new, item.start != nil, !item.done { event.alarms = [EKAlarm(relativeOffset: 0)] }
            // A birthday that begins with the local day: said at nine that morning.
            if new, occasion, item.start == nil { event.alarms = [EKAlarm(relativeOffset: 9 * 3600)] }
        } else if let reminder = target as? EKReminder {
            let due = DateComponents(calendar: cal, year: item.year, month: item.month, day: item.day)
            reminder.startDateComponents = due
            reminder.dueDateComponents = due
            reminder.isCompleted = item.done
        }
    }

    /// A change made in Calendar or Reminders, applied to the item: its title, day and time, and done.
    private func apply(_ item: MirrorItem, to task: TaskRecord) {
        let title = item.plainTitle.trimmed
        // The phone shows a title without its [[note]] links: the same words back keep the links.
        if !title.isEmpty, title != MirrorItem.phoneTitle(task.title) { task.title = title }
        var plan = PlanDate(year: item.year, month: item.month, day: item.day)
        if item.kind == .event, let start = item.start {
            plan.hour = start / 60
            plan.minute = start % 60
            let hourLong = item.end == start + 60
            task.endMinute = hourLong && task.endMinute == nil ? nil : item.end
        } else if item.kind == .reminder, let old = task.schedule, old.hour != nil {
            plan.hour = old.hour
            plan.minute = old.minute
        }
        task.schedule = plan
        task.completed = item.done
    }

    private static func marker(_ item: EKCalendarItem) -> UUID? {
        guard let url = item.url, url.scheme == "asmo", url.host == "mirror" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    private static func item(_ event: EKEvent, calendar cal: Calendar) -> MirrorItem {
        let start = cal.dateComponents([.year, .month, .day, .hour, .minute], from: event.startDate)
        let minutes = (start.hour ?? 0) * 60 + (start.minute ?? 0)
        var end: Int?
        if !event.isAllDay, let endDate = event.endDate {
            let dayStart = cal.startOfDay(for: event.startDate)
            end = min(Int(endDate.timeIntervalSince(dayStart) / 60), 24 * 60 - 1)
        }
        let title = event.title ?? ""
        return MirrorItem(kind: .event, title: title, year: start.year ?? 2000, month: start.month ?? 1, day: start.day ?? 1,
                          start: event.isAllDay ? nil : minutes, end: end, done: title.hasPrefix("✓ "), notes: event.notes ?? "")
    }

    private static func item(_ reminder: EKReminder) -> MirrorItem? {
        guard let due = reminder.dueDateComponents ?? reminder.startDateComponents,
              let year = due.year, let month = due.month, let day = due.day else { return nil }
        return MirrorItem(kind: .reminder, title: reminder.title ?? "", year: year, month: month, day: day,
                          done: reminder.isCompleted, notes: reminder.notes ?? "")
    }

    // MARK: What was written

    private func loadRecords() -> [UUID: MirrorRecord] {
        guard let data = try? Data(contentsOf: recordsURL),
              let decoded = try? JSONDecoder().decode([String: MirrorRecord].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    private func saveRecords(_ records: [UUID: MirrorRecord]) {
        let plain = Dictionary(uniqueKeysWithValues: records.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(plain) { try? data.write(to: recordsURL, options: .atomic) }
    }
}
#endif
