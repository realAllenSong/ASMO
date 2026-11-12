import CloudKit
import EventKit
import Foundation
import Observation

struct SystemTask: Identifiable {
    let id: String
    let asmoID: UUID?
    let title: String
    let note: String
    let schedule: PlanDate?
    let endMinute: Int?
    let alertAt: Date?
    let completed: Bool
}

struct SystemEvent: Identifiable, Sendable {
    let id: String
    let asmoID: UUID?
    let title: String
    let note: String
    let calendarID: String
    let calendarTitle: String
    let writable: Bool
    let start: Date
    let end: Date
    let allDay: Bool
    let alertLead: Int?
    let importantKind: ImportantDateKind?
}

struct SystemCalendar: Identifiable {
    let id: String
    let title: String
    let writable: Bool
    let suggestedImportant: Bool
}

enum SystemPlannerError: LocalizedError {
    case permission, iCloudReminders, otherDevice, missingCalendar, missingReminder, missingEvent, pastAlert, busy
    var errorDescription: String? {
        switch self {
        case .permission: String(localized: "请先在系统设置中授予「逐日」完整访问权限。")
        case .iCloudReminders: String(localized: "请先在系统设置中开启 iCloud「提醒事项」。")
        case .otherDevice: String(localized: "另一台设备正在处理这条提醒。同步后可在「ASMO」提醒列表中查看。")
        case .missingCalendar: String(localized: "请先在设置中选一个可写的 Apple 日历。")
        case .missingReminder: String(localized: "这条提醒已移动或删除。")
        case .missingEvent: String(localized: "找不到原日历事件。请先检查 Apple 日历同步。")
        case .pastAlert: String(localized: "请选择未来的提醒时间。")
        case .busy: String(localized: "正在保存这条记录，请稍等。")
        }
    }
}

@MainActor
@Observable
final class SystemPlanner {
    private let store = EKEventStore()
    private let defaults = UserDefaults.standard
    private var inFlight = Set<UUID>()
    private var refreshID = UUID()
    @ObservationIgnored private var linkedLookup = [UUID: Bool]()
    var reminders: [SystemTask] = []
    var calendars: [SystemCalendar] = []
    private(set) var calendarRevision = 0

    var canReadEvents: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    var canReadReminders: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    var visibleCalendars: Set<String> {
        get { Set(defaults.stringArray(forKey: "eventSources") ?? calendars.map(\.id)) }
        set {
            defaults.set(Array(newValue), forKey: "eventSources")
            calendarRevision += 1
        }
    }

    var destinationID: String {
        get { defaults.string(forKey: "eventDestination") ?? "" }
        set { defaults.set(newValue, forKey: "eventDestination") }
    }

    var importantCalendars: Set<String> {
        get { Set(defaults.stringArray(forKey: "importantSources") ?? calendars.filter(\.suggestedImportant).map(\.id)) }
        set {
            defaults.set(Array(newValue), forKey: "importantSources")
            calendarRevision += 1
        }
    }

    func authorizeEvents() async throws {
        if !canReadEvents, try await !store.requestFullAccessToEvents() { throw SystemPlannerError.permission }
        refreshCalendars()
    }

    func authorizeReminders() async throws {
        if !canReadReminders, try await !store.requestFullAccessToReminders() { throw SystemPlannerError.permission }
        await refreshReminders()
    }

    func refreshCalendars() {
        linkedLookup.removeAll()
        calendars = canReadEvents ? store.calendars(for: .event).map {
            SystemCalendar(id: $0.calendarIdentifier, title: "\($0.title) · \($0.source.title)",
                           writable: $0.allowsContentModifications, suggestedImportant: suggestedImportant($0))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } : []
        calendarRevision += 1
    }

    func events(on day: PlanDate, clock: CaptureClock) -> [SystemEvent] {
        events(from: day, through: day, clock: clock)
    }

    func events(from first: PlanDate, through last: PlanDate, clock: CaptureClock) -> [SystemEvent] {
        guard canReadEvents else { return [] }
        return Self.readEvents(from: first, through: last, calendar: clock.calendar, store: store,
                               visible: visibleCalendars, important: importantCalendars)
    }

    func agendaEvents(on days: [PlanDate], calendar: Calendar,
                      linkedAnchors: [UUID: Date]) async -> (days: [PlanDate: [SystemEvent]], linked: Set<UUID>) {
        guard canReadEvents, let first = days.first, let last = days.last else { return ([:], []) }
        let visible = visibleCalendars
        let important = importantCalendars
        let read = Task.detached(priority: .userInitiated) {
            // Keep EventKit objects on the worker. The view only receives value snapshots.
            guard !Task.isCancelled else { return ([PlanDate: [SystemEvent]](), Set<UUID>()) }
            let store = EKEventStore()
            let events = Self.readEvents(from: first, through: last, calendar: calendar, store: store,
                                         visible: visible, important: important)
            var linked = Set(events.compactMap(\.asmoID))
            for (id, anchor) in linkedAnchors where !linked.contains(id) {
                if Task.isCancelled { break }
                if Self.linkedEvent(id, anchor: anchor, in: store) != nil { linked.insert(id) }
            }
            var byDay: [PlanDate: [SystemEvent]] = [:]
            for day in days {
                if Task.isCancelled { break }
                guard let date = day.date(in: calendar),
                      let interval = calendar.dateInterval(of: .day, for: date) else { continue }
                let matches = events.filter {
                    $0.start < interval.end && ($0.end > interval.start || $0.start >= interval.start)
                }
                if !matches.isEmpty { byDay[day] = matches }
            }
            return (byDay, linked)
        }
        return await withTaskCancellationHandler { await read.value } onCancel: { read.cancel() }
    }

    nonisolated private static func readEvents(from first: PlanDate, through last: PlanDate, calendar: Calendar,
                                               store: EKEventStore, visible: Set<String>,
                                               important: Set<String>) -> [SystemEvent] {
        guard let from = first.date(in: calendar), let to = last.date(in: calendar),
              let lastDay = calendar.dateInterval(of: .day, for: to) else { return [] }
        let start = calendar.startOfDay(for: from)
        guard start < lastDay.end else { return [] }
        let sources = store.calendars(for: .event)
        guard !sources.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: lastDay.end, calendars: sources)
        return store.events(matching: predicate).filter {
            visible.contains($0.calendar.calendarIdentifier) || Self.markerID($0) != nil
        }.sorted { $0.startDate < $1.startDate }.map { Self.snapshot($0, important: important) }
    }

    func refreshReminders() async {
        let generation = UUID()
        refreshID = generation
        guard canReadReminders else { reminders = []; return }
        let items = await fetchReminders(in: asmoLists)
        guard refreshID == generation else { return }
        var seen = Set<String>()
        reminders = items.map(snapshot).sorted {
            if $0.completed != $1.completed { return $0.completed }
            return $0.id < $1.id
        }.filter { seen.insert($0.asmoID?.uuidString ?? $0.id).inserted }
    }

    func putReminder(id: UUID, title: String, note: String, schedule: PlanDate?, endMinute: Int?, at time: Date,
                     completed: Bool) async throws {
        guard inFlight.insert(id).inserted else { throw SystemPlannerError.busy }
        defer { inFlight.remove(id) }
        guard canReadReminders else { throw SystemPlannerError.permission }
        if await fetchReminders(in: asmoLists).contains(where: { Self.markerID($0) == id }) { return }
        guard time > .now else { throw SystemPlannerError.pastAlert }
        let list = try dedicatedList()
        try await reserve(id)
        // A retry after a crash must check EventKit again after it obtains the reservation.
        if await fetchReminders(in: asmoLists).contains(where: { Self.markerID($0) == id }) { return }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = note.isEmpty ? nil : note
        reminder.calendar = list
        reminder.url = marker(id, endMinute: endMinute)
        applyDates(reminder, schedule: schedule, alert: time)
        reminder.isCompleted = completed
        try store.save(reminder, commit: true)
        await refreshReminders()
    }

    func editReminder(_ item: SystemTask, title: String, note: String, schedule: PlanDate?, endMinute: Int?, alert: Date?) async throws {
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else {
            throw SystemPlannerError.missingReminder
        }
        if let alert, alert != item.alertAt, alert <= .now { throw SystemPlannerError.pastAlert }
        reminder.title = title
        reminder.notes = note.isEmpty ? nil : note
        if let id = item.asmoID { reminder.url = marker(id, endMinute: endMinute) }
        applyDates(reminder, schedule: schedule, alert: alert)
        try store.save(reminder, commit: true)
        await refreshReminders()
    }

    func toggle(_ item: SystemTask) async throws {
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else {
            throw SystemPlannerError.missingReminder
        }
        reminder.isCompleted = !item.completed
        try store.save(reminder, commit: true)
        await refreshReminders()
    }

    func delete(_ item: SystemTask) async throws {
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else {
            throw SystemPlannerError.missingReminder
        }
        try store.remove(reminder, commit: true)
        await refreshReminders()
    }

    func saveEvent(id: UUID, title: String, start: Date, end: Date, allDay: Bool, note: String,
                   alertLead: Int?, calendarID: String? = nil, existing: SystemEvent? = nil,
                   previousStart: Date? = nil, linkTask: Bool = false) async throws {
        guard canReadEvents else { throw SystemPlannerError.permission }
        guard inFlight.insert(id).inserted else { throw SystemPlannerError.busy }
        defer { inFlight.remove(id) }
        let calendars = store.calendars(for: .event).filter(\.allowsContentModifications)
        guard let destination = calendars.first(where: { $0.calendarIdentifier == (calendarID ?? existing?.calendarID ?? destinationID) }) else {
            throw SystemPlannerError.missingCalendar
        }
        let event: EKEvent
        let new: Bool
        if let existing {
            guard let match = Self.eventNear(existing.start, in: store, matching: { Self.snapshotID($0) == existing.id }) else {
                throw SystemPlannerError.missingEvent
            }
            event = match
            new = false
        } else if let previousStart {
            guard let match = Self.linkedEvent(id, anchor: previousStart, in: store) else {
                throw SystemPlannerError.missingEvent
            }
            event = match
            new = false
        } else {
            if linkTask { try await reserve(id, category: "event") }
            let match = Self.eventNear(start, in: store, matching: { Self.markerID($0) == id })
            event = match ?? EKEvent(eventStore: store)
            new = match == nil
        }
        event.title = title
        event.calendar = destination
        event.startDate = start
        event.endDate = end
        event.isAllDay = allDay
        event.notes = note.isEmpty ? nil : note
        if new { event.url = marker(id) }
        if new || Self.snapshotAlert(event) != alertLead {
            if let old = event.alarms?.first(where: { $0.absoluteDate == nil && $0.structuredLocation == nil }) {
                event.removeAlarm(old)
            }
            if let alertLead {
                event.addAlarm(EKAlarm(relativeOffset: -Double(alertLead * 60)))
            }
        }
        try store.save(event, span: .thisEvent, commit: true)
        linkedLookup[id] = true
        calendarRevision += 1
    }

    func deleteEvent(_ existing: SystemEvent?, id: UUID, previousStart: Date?) throws {
        guard canReadEvents else { throw SystemPlannerError.permission }
        let match: EKEvent?
        if let existing {
            match = Self.eventNear(existing.start, in: store, matching: { Self.snapshotID($0) == existing.id })
        } else if let previousStart {
            match = Self.linkedEvent(id, anchor: previousStart, in: store)
        } else {
            match = nil
        }
        guard let event = match else { throw SystemPlannerError.missingEvent }
        try store.remove(event, span: .thisEvent, commit: true)
        linkedLookup[id] = false
        calendarRevision += 1
    }

    func hasLinkedEvent(_ id: UUID, anchor: Date) -> Bool {
        guard canReadEvents else { return false }
        if let cached = linkedLookup[id] { return cached }
        let exists = Self.linkedEvent(id, anchor: anchor, in: store) != nil
        linkedLookup[id] = exists
        return exists
    }

    nonisolated private static func linkedEvent(_ id: UUID, anchor: Date, in store: EKEventStore) -> EKEvent? {
        if let exact = eventNear(anchor, in: store, matching: { markerID($0) == id }) { return exact }
        let year: TimeInterval = 370 * 86_400
        let predicate = store.predicateForEvents(withStart: anchor.addingTimeInterval(-year),
                                                 end: anchor.addingTimeInterval(year), calendars: nil)
        return store.events(matching: predicate).first { markerID($0) == id }
    }

    nonisolated private static func eventNear(_ anchor: Date, in store: EKEventStore, matching match: (EKEvent) -> Bool) -> EKEvent? {
        let predicate = store.predicateForEvents(withStart: anchor.addingTimeInterval(-86_400),
                                                 end: anchor.addingTimeInterval(86_400), calendars: nil)
        return store.events(matching: predicate).first(where: match)
    }

    nonisolated private static func snapshotID(_ event: EKEvent) -> String {
        "\(event.calendarItemIdentifier)-\(event.startDate.timeIntervalSinceReferenceDate)"
    }

    nonisolated private static func snapshot(_ event: EKEvent, important: Set<String>) -> SystemEvent {
        let calendar = event.calendar!
        let kind: ImportantDateKind? = event.isAllDay && important.contains(calendar.calendarIdentifier) ?
            (isBirthdayCalendar(calendar) ? .birthday : .holiday) : nil
        return SystemEvent(id: snapshotID(event), asmoID: markerID(event), title: event.title ?? String(localized: "日程"),
                           note: event.notes ?? "", calendarID: calendar.calendarIdentifier, calendarTitle: calendar.title,
                           writable: calendar.allowsContentModifications, start: event.startDate, end: event.endDate,
                           allDay: event.isAllDay, alertLead: snapshotAlert(event), importantKind: kind)
    }

    nonisolated private static func snapshotAlert(_ event: EKEvent) -> Int? {
        event.alarms?.first(where: { $0.absoluteDate == nil && $0.structuredLocation == nil && $0.relativeOffset <= 0 })
            .map { Int(-$0.relativeOffset / 60) }
    }

    nonisolated private static func isBirthdayCalendar(_ calendar: EKCalendar) -> Bool {
        calendar.type == .birthday || calendar.title.match(#"birthdays?|生日"#) != nil
    }

    private func suggestedImportant(_ calendar: EKCalendar) -> Bool {
        Self.isBirthdayCalendar(calendar) || calendar.title.match(#"holidays?|节假日|節假日|节日|節日|假日"#) != nil
    }

    private var asmoLists: [EKCalendar] {
        store.calendars(for: .reminder).filter {
            $0.title == "ASMO" && isICloud($0.source)
        }
    }

    private func isICloud(_ source: EKSource) -> Bool {
        source.sourceType == .calDAV && source.title.compare("iCloud", options: [.caseInsensitive]) == .orderedSame
    }

    private func dedicatedList() throws -> EKCalendar {
        if let existing = asmoLists.first(where: \.allowsContentModifications) { return existing }
        let sources = store.calendars(for: .reminder).compactMap { $0.source } + store.sources
        guard let iCloud = sources.first(where: { isICloud($0) }) else { throw SystemPlannerError.iCloudReminders }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = "ASMO"
        list.source = iCloud
        try store.saveCalendar(list, commit: true)
        return list
    }

    private func fetchReminders(in lists: [EKCalendar]) async -> [EKReminder] {
        guard !lists.isEmpty else { return [] }
        let predicate = store.predicateForReminders(in: lists)
        return await withCheckedContinuation { continuation in
            _ = store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    private func snapshot(_ reminder: EKReminder) -> SystemTask {
        let components = reminder.dueDateComponents
        let schedule = components.flatMap { parts -> PlanDate? in
            guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
            return PlanDate(year: year, month: month, day: day, hour: parts.hour, minute: parts.minute)
        }
        return SystemTask(id: reminder.calendarItemIdentifier, asmoID: Self.markerID(reminder),
                          title: reminder.title ?? String(localized: "提醒"), note: reminder.notes ?? "", schedule: schedule,
                          endMinute: reminder.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                            .queryItems?.first(where: { $0.name == "end" })?.value.flatMap(Int.init),
                          alertAt: reminder.alarms?.compactMap(\.absoluteDate).first, completed: reminder.isCompleted)
    }

    private func applyDates(_ reminder: EKReminder, schedule: PlanDate?, alert: Date?) {
        let clock = CaptureClock()
        let due = schedule?.day == nil ? alert.map { PlanDate.from($0, calendar: clock.calendar, includeTime: true) } : schedule
        let components = due.map {
            DateComponents(calendar: clock.calendar, timeZone: $0.hour == nil ? nil : clock.calendar.timeZone,
                           year: $0.year, month: $0.month, day: $0.day, hour: $0.hour, minute: $0.minute)
        }
        reminder.startDateComponents = components
        reminder.dueDateComponents = components
        reminder.alarms = alert.map { [EKAlarm(absoluteDate: $0)] }
    }

    private func marker(_ id: UUID, endMinute: Int? = nil) -> URL? {
        URL(string: "asmo://item/\(id.uuidString)" + (endMinute.map { "?end=\($0)" } ?? ""))
    }

    nonisolated private static func markerID(_ item: EKCalendarItem) -> UUID? {
        guard let url = item.url, url.scheme == "asmo", url.host == "item" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    private func reserve(_ id: UUID, category: String = "reminder") async throws {
        guard !ASMOStore.cloudID.isEmpty else { return }
        let database = CKContainer(identifier: ASMOStore.cloudID).privateCloudDatabase
        let writer = defaults.string(forKey: "asmoDeviceID") ?? UUID().uuidString
        defaults.set(writer, forKey: "asmoDeviceID")
        let key = CKRecord.ID(recordName: "\(category)-\(id.uuidString)")
        let record = CKRecord(recordType: "ASMOSystemWrite", recordID: key)
        record["writer"] = writer
        do {
            _ = try await database.save(record)
        } catch let error as CKError where error.code == .serverRecordChanged {
            let current = try await database.record(for: key)
            guard current["writer"] as? String == writer else { throw SystemPlannerError.otherDevice }
        }
    }
}
