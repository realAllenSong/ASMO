#if os(macOS)
import AppKit
#endif
import Foundation
import SwiftData

#if os(macOS)

/// The door for coding agents: the `asmo` command (see CLI/) connects to a socket in the app's container, sends one
/// JSON request and reads one JSON answer. The app stays the only writer of the store, so open windows update live.
enum AgentBridge {
    private static var listener: DispatchSourceRead?
    private static let queue = DispatchQueue(label: "asmo.agent", attributes: .concurrent)

    /// The socket's file name: the test store has its own, so an agent never mixes test and real data.
    static var socketName: String {
        #if DEBUG
        if ProcessInfo.processInfo.environment["ASMO_TEST_STORE"] != nil { return "asmo-test.sock" }
        #endif
        return "asmo.sock"
    }

    @MainActor
    static func start(_ container: ModelContainer) {
        guard listener == nil else { return }
        let commands = AgentCommands(context: container.mainContext)
        let path = AppPaths.support.appendingPathComponent(socketName).path
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); return }
        chmod(path, 0o600)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            queue.async {
                let request = readAll(client)
                Task { @MainActor in
                    let answer = await commands.runInTurn(request)
                    queue.async { writeAll(client, answer); close(client) }
                }
            }
        }
        source.resume()
        listener = source
    }

    /// The request ends when the client closes its writing side.
    private static func readAll(_ fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while data.count < 64 << 20 {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let count = write(fd, raw.baseAddress! + sent, raw.count - sent)
                if count <= 0 { break }
                sent += count
            }
        }
    }
}

#endif

/// What an agent can ask for. Requests and answers are JSON objects; every answer has "ok". The same commands serve
/// the `asmo` command on the Mac and the Apple Intelligence assistant on iPhone (pages are Mac-only for now).
@MainActor
final class AgentCommands {
    struct Failure: Error { let message: String }

    private let context: ModelContext
    private var clock: CaptureClock { CaptureClock() }
    private var turn: Task<Void, Never>?
    /// What `asmo undo` takes back, newest last (changes made through this door since the app started).
    private var undos: [(what: String, revert: () throws -> Void)] = []
    private var pendingUndo: (what: String, revert: () throws -> Void)?
    private var changedPages: [String] = []

    init(context: ModelContext) { self.context = context }

    /// One request at a time, in the order they came (drawing a diagram waits; nothing else may slip in between).
    func runInTurn(_ request: Data) async -> Data {
        let previous = turn
        let mine = Task { @MainActor () -> Data in
            await previous?.value
            return await self.run(request)
        }
        turn = Task { _ = await mine.value }
        return await mine.value
    }

    private func remember(_ what: String, _ revert: @escaping () throws -> Void) { pendingUndo = (what, revert) }

    func run(_ request: Data) async -> Data {
        var answer: [String: Any]
        pendingUndo = nil
        changedPages = []
        do {
            guard let body = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
                  let command = body["cmd"] as? String else { throw Failure(message: "The request is not a JSON object with \"cmd\".") }
            answer = try await handle(command, body)
            if context.hasChanges { try context.save() }
            if let pendingUndo {
                undos.append(pendingUndo)
                if undos.count > 100 { undos.removeFirst() }
            }
            // An open page shows what was just written.
            // (Many at once: one redraw.)
            if changedPages.count > 20 { NotificationCenter.default.post(name: .asmoPageChanged, object: nil) }
            else { for key in changedPages { NotificationCenter.default.post(name: .asmoPageChanged, object: key) } }
            answer["ok"] = true
        } catch {
            context.rollback()
            answer = ["ok": false, "error": Self.message(error)]
        }
        return (try? JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{\"ok\":false}".utf8)
    }

    private static func message(_ error: Error) -> String {
        if let failure = error as? Failure { return failure.message }
        #if os(macOS)
        if let failure = error as? PageMarkdown.Failure { return failure.message }
        #endif
        return error.localizedDescription
    }

    private func handle(_ command: String, _ body: [String: Any]) async throws -> [String: Any] {
        switch command {
        case "ping":
            #if os(macOS)
            let store = AgentBridge.socketName == "asmo.sock" ? "real" : "test"
            #else
            let store = "real"
            #endif
            return ["app": AppName.display, "today": clock.today.key, "store": store]
        case "day": return try day(body)
        case "list": return try list(body)
        case "search": return try search(body)
        case "add": return try add(body)
        case "update": return try update(body)
        case "done": return try done(body)
        case "delete": return try delete(body)
        case "routines": return ["routines": try routines().map(json)]
        case "routine-add": return try addRoutine(body)
        case "routine-stop": return try stopRoutine(body)
        case "routine-mark": return try markRoutine(body)
        #if os(macOS)
        case "show": return try show(body)
        case "page": return try page(body)
        case "page-write": return try await writePage(body)
        case "page-set": return try await setBlock(body)
        case "page-remove": return try removeBlocks(body)
        case "pages": return try listPages(body)
        case "page-import": return try await importPages(body)
        case "mirror":
            // Keep Apple Calendar and Reminders in step now, and say what that did.
            if let on = body["on"] as? Bool { UserDefaults.standard.set(on, forKey: CalendarMirror.enabledKey) }
            return await CalendarMirror.shared.run()
        #endif
        case "dates": return ["dates": try dates().map(json)]
        case "date-add": return try addDate(body)
        case "date-set": return try setDate(body)
        case "date-remove": return try removeDate(body)
        case "undo": return try undo()
        default: throw Failure(message: "Unknown command \"\(command)\".")
        }
    }

    // MARK: Reading

    private func tasks() throws -> [TaskRecord] { try context.fetch(FetchDescriptor<TaskRecord>(sortBy: [SortDescriptor(\.createdAt)])) }
    private func routines() throws -> [RoutineRecord] { try context.fetch(FetchDescriptor<RoutineRecord>(sortBy: [SortDescriptor(\.order)])) }

    private func day(_ body: [String: Any]) throws -> [String: Any] {
        let day = try planDay(body["day"] ?? "today")
        guard day.day != nil else { throw Failure(message: "\"day\" needs a full date (YYYY-MM-DD).") }
        let all = try tasks()
        let onDay = all.filter { $0.schedule?.dayOnly == day }
        let ids = Set(onDay.map(\.id))
        let top = onDay.filter { $0.parentID.map { !ids.contains($0) } ?? true }.sorted(by: inDayOrder)
        let marks = try context.fetch(FetchDescriptor<RoutineMark>()).filter { $0.dayKey == day.key }
        let daily: [[String: Any]] = try routines().filter { $0.applies(to: day, calendar: clock.calendar) }.compactMap { routine in
            let mark = marks.first { $0.routineID == routine.id }
            if mark?.skipped == true { return nil }
            var row = json(routine)
            row["done"] = mark != nil
            return row
        }
        var answer: [String: Any] = ["day": day.key, "weekday": weekday(day), "tasks": top.map { tree($0, in: all) }, "routines": daily]
        #if os(macOS)
        let key = day.key
        if let page = try context.fetch(FetchDescriptor<DayPage>(predicate: #Predicate { $0.dayKey == key })).first,
           let data = page.rtfd, let text = NSAttributedString(rtfd: data, documentAttributes: nil) {
            let written = PageMarkdown.markdown(text)
            if !written.isEmpty { answer["page"] = written }
        }
        #endif
        // A date kept in another time zone is on the local day it begins there ("begins": the local time).
        let occasions: [[String: Any]] = try dates().compactMap { record in
            guard let start = record.start(onLocal: day, calendar: clock.calendar) else { return nil }
            var row = json(record)
            if start.minute != 0 || start.there != day {
                row["begins"] = String(format: "%02d:%02d", start.minute / 60, start.minute % 60)
                row["dayThere"] = start.there.key
            }
            return row
        }
        if !occasions.isEmpty { answer["dates"] = occasions }
        let month = PlanDate(year: day.year, month: day.month)
        let monthPlans = all.filter { $0.schedule == month }
        if !monthPlans.isEmpty { answer["monthPlans"] = monthPlans.map { json($0) } }
        return answer
    }

    private func list(_ body: [String: Any]) throws -> [String: Any] {
        let from = try planDay(body["from"] ?? "today"), to = try planDay(body["to"] ?? body["from"] ?? "today")
        let includeDone = body["done"] as? Bool ?? true
        let found = try tasks().filter { task in
            guard let key = task.schedule?.key else { return false }
            return key >= from.key && key <= to.key + "~" && (includeDone || !task.completed)
        }.sorted { ($0.schedule ?? from, $0.createdAt) < ($1.schedule ?? from, $1.createdAt) }
        return ["tasks": found.map { json($0) }]
    }

    private func search(_ body: [String: Any]) throws -> [String: Any] {
        let query = (body["query"] as? String ?? "").trimmed
        guard !query.isEmpty else { throw Failure(message: "\"query\" is empty.") }
        let found = try tasks().filter { $0.title.localizedCaseInsensitiveContains(query) || $0.note.localizedCaseInsensitiveContains(query) }
            .sorted { ($0.schedule?.key ?? "") > ($1.schedule?.key ?? "") }
        return ["tasks": found.prefix(body["limit"] as? Int ?? 50).map { json($0) }]
    }

    // MARK: Writing

    private func add(_ body: [String: Any]) throws -> [String: Any] {
        let items = body["items"] as? [[String: Any]] ?? [body]
        let fallback = try planDay(body["day"] ?? "today")
        var created: [TaskRecord] = []
        func insert(_ item: [String: Any], parent: TaskRecord?, depth: Int) throws {
            let title = (item["title"] as? String ?? "").trimmed
            guard !title.isEmpty else { throw Failure(message: "Every item needs a \"title\".") }
            guard depth < 3 else { throw Failure(message: "Subtasks go three levels deep at most.") }
            var schedule = try item["day"].map(planDay) ?? parent?.schedule?.dayOnly ?? fallback
            let task = TaskRecord(title: title, note: item["note"] as? String ?? "", schedule: schedule)
            if let words = spoken(item["when"], around: schedule) {
                schedule = words.day
                try setTime(task, from: words.start, to: words.end, schedule: &schedule)
            } else {
                try setTime(task, from: item["time"].flatMap(minutes), to: item["end"].flatMap(minutes), schedule: &schedule)
            }
            task.completed = item["done"] as? Bool ?? false
            task.parentID = parent?.id
            // Keeps the order they were given in (items are listed by creation time).
            task.createdAt = Date.now.addingTimeInterval(Double(created.count) * 0.001)
            context.insert(task)
            created.append(task)
            for child in item["subtasks"] as? [[String: Any]] ?? [] { try insert(child, parent: task, depth: depth + 1) }
        }
        if let parentID = body["parent"] as? String {
            guard let parent = try find(parentID) else { throw Failure(message: "No task with id \(parentID).") }
            for item in items { try insert(item, parent: parent, depth: 1) }
        } else {
            for item in items { try insert(item, parent: nil, depth: 0) }
        }
        let ids = created.map(\.id)
        remember("added " + summary(created.map(\.title))) { [self] in
            for task in try tasks() where ids.contains(task.id) { context.delete(task) }
        }
        return ["added": created.map { json($0) }]
    }

    private func update(_ body: [String: Any]) throws -> [String: Any] {
        let task = try required(body["id"])
        guard !task.calendarLinked else { throw Failure(message: "This item mirrors an Apple Calendar event; change it in Calendar.") }
        let before = try family(of: task).map(Saved.init)
        remember("changed 「\(task.title)」") { [self] in try restore(before) }
        if let title = body["title"] as? String {
            guard !title.trimmed.isEmpty else { throw Failure(message: "\"title\" is empty.") }
            task.title = title.trimmed
        }
        if let note = body["note"] as? String { task.note = note }
        if let done = body["done"] as? Bool { task.completed = done }
        if let words = spoken(body["when"], around: task.schedule?.dayOnly ?? clock.today) {
            var schedule = words.day
            for child in try family(of: task).dropFirst() {
                child.schedule = PlanDate(year: schedule.year, month: schedule.month, day: schedule.day, hour: child.hour, minute: child.minute)
            }
            task.carriedFrom = nil
            if let start = words.start { try setTime(task, from: start, to: words.end, schedule: &schedule) }
            else { schedule.hour = task.schedule?.hour; schedule.minute = task.schedule?.minute; task.schedule = schedule }
        } else if let day = body["day"] {
            let target = try planDay(day)
            let old = task.schedule
            task.schedule = PlanDate(year: target.year, month: target.month, day: target.day,
                                     hour: target.day == nil ? nil : old?.hour, minute: target.day == nil ? nil : old?.minute)
            if target.day == nil { task.endMinute = nil }
            task.carriedFrom = nil
            // Subtasks travel with their parent.
            for child in try family(of: task).dropFirst() {
                child.schedule = PlanDate(year: target.year, month: target.month, day: target.day,
                                          hour: target.day == nil ? nil : child.hour, minute: target.day == nil ? nil : child.minute)
            }
        }
        if body["time"] != nil || body["end"] != nil {
            var schedule = task.schedule ?? clock.today
            let oldStart = schedule.minuteOfDay, oldEnd = task.endMinute
            var from = oldStart
            if let value = body["time"] { from = try minutes(value) }
            var to: Int?
            if let value = body["end"] { to = try minutes(value) }
            // A new start keeps the length ("14:00–15:00" moved to 16:00 ends at 17:00).
            else if let from, let oldStart, let oldEnd { to = from + oldEnd - oldStart }
            try setTime(task, from: from, to: to, schedule: &schedule)
        }
        if let parent = body["parent"] {
            if let id = parent as? String, !id.isEmpty {
                guard let above = try find(id), above.id != task.id, try !family(of: task).contains(where: { $0.id == above.id })
                else { throw Failure(message: "\"parent\" has to be another task that is not under this one.") }
                task.parentID = above.id
            } else {
                task.parentID = nil
            }
        }
        return ["task": json(task)]
    }

    private func done(_ body: [String: Any]) throws -> [String: Any] {
        let state = body["done"] as? Bool ?? true
        let found = try ids(body).map(required)
        let before = found.map(Saved.init)
        remember((state ? "checked off " : "unchecked ") + summary(found.map(\.title))) { [self] in try restore(before) }
        found.forEach { $0.completed = state }
        return ["tasks": found.map { json($0) }]
    }

    private func delete(_ body: [String: Any]) throws -> [String: Any] {
        var removed: [TaskRecord] = []
        for task in try ids(body).map(required) {
            guard !task.calendarLinked else { throw Failure(message: "「\(task.title)」 mirrors an Apple Calendar event; delete it in Calendar.") }
            for item in try family(of: task) where !removed.contains(where: { $0.id == item.id }) { removed.append(item) }
        }
        let rows = removed.map { json($0) }
        let before = removed.map(Saved.init)
        remember("deleted " + summary(removed.map(\.title))) { [self] in try restore(before) }
        removed.forEach(context.delete)
        return ["deleted": rows]
    }

    // MARK: Routines

    private func addRoutine(_ body: [String: Any]) throws -> [String: Any] {
        let title = (body["title"] as? String ?? "").trimmed
        guard !title.isEmpty else { throw Failure(message: "A routine needs a \"title\".") }
        // "monthly" (on the day it starts) or "monthly:15".
        var monthDay: Int?
        var days = Set(1...7)
        if let rule = (body["weekdays"] as? String)?.lowercased(), rule.hasPrefix("monthly") {
            let from = try planDay(body["from"] ?? "today")
            monthDay = rule.split(separator: ":").dropFirst().first.flatMap { Int($0) } ?? from.day
            guard let day = monthDay, (1...31).contains(day) else { throw Failure(message: "monthly:N needs a day 1–31.") }
        } else {
            days = try weekdays(body["weekdays"])
        }
        let start = try body["time"].flatMap(minutes), end = try body["end"].flatMap(minutes)
        let routine = RoutineRecord(title: title, weekdays: days, monthDay: monthDay, startMinute: start, endMinute: start == nil ? nil : end,
                                    startDay: try planDay(body["from"] ?? "today").key,
                                    order: (try routines().map(\.order).max() ?? 0) + 1)
        context.insert(routine)
        let id = routine.id
        remember("added the routine 「\(title)」") { [self] in
            for routine in try routines() where routine.id == id { context.delete(routine) }
        }
        return ["routine": json(routine)]
    }

    /// Ends a routine from today on (earlier days keep it); one that never ran is removed.
    private func stopRoutine(_ body: [String: Any]) throws -> [String: Any] {
        let routine = try requiredRoutine(body["id"])
        let row = json(routine)
        let saved = (id: routine.id, title: routine.title, weekdays: routine.weekdays, monthDay: routine.monthDay, start: routine.startMinute, end: routine.endMinute,
                     from: routine.startDay, until: routine.endDay, order: routine.order, created: routine.createdAt)
        remember("stopped the routine 「\(routine.title)」") { [self] in
            if let existing = try routines().first(where: { $0.id == saved.id }) { existing.endDay = saved.until; return }
            let back = RoutineRecord(title: saved.title, weekdays: saved.weekdays, monthDay: saved.monthDay, startMinute: saved.start, endMinute: saved.end,
                                     startDay: saved.from, order: saved.order)
            back.id = saved.id
            back.endDay = saved.until
            back.createdAt = saved.created
            context.insert(back)
        }
        if routine.startDay >= clock.today.key { context.delete(routine) } else { routine.endDay = clock.today.key }
        return ["stopped": row]
    }

    private func markRoutine(_ body: [String: Any]) throws -> [String: Any] {
        let routine = try requiredRoutine(body["id"])
        let day = try planDay(body["day"] ?? "today")
        let state = body["state"] as? String ?? "done"
        guard ["done", "skip", "clear"].contains(state) else { throw Failure(message: "\"state\" is done, skip or clear.") }
        guard routine.applies(to: day, calendar: clock.calendar) else { throw Failure(message: "「\(routine.title)」 does not run on \(day.key).") }
        let id = routine.id, key = day.key
        let marks = FetchDescriptor<RoutineMark>(predicate: #Predicate { $0.routineID == id && $0.dayKey == key })
        let before = try context.fetch(marks).map(\.skipped)
        remember("marked 「\(routine.title)」 on \(key)") { [self] in
            try context.fetch(marks).forEach(context.delete)
            for skipped in before { context.insert(RoutineMark(routineID: id, dayKey: key, skipped: skipped)) }
        }
        try context.fetch(marks).forEach(context.delete)
        if state != "clear" { context.insert(RoutineMark(routineID: id, dayKey: key, skipped: state == "skip")) }
        return ["routine": routine.id.uuidString.lowercased(), "day": key, "state": state]
    }

    #if os(macOS)
    // MARK: The window

    /// Brings the app's window to a month (only when asked: agents normally work in the background).
    private func show(_ body: [String: Any]) throws -> [String: Any] {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.title == AppName.window }?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .asmoToday, object: nil)
        return [:]
    }

    // MARK: The day's page

    private func pageRecord(_ key: String) throws -> DayPage? {
        try context.fetch(FetchDescriptor<DayPage>(predicate: #Predicate { $0.dayKey == key })).first
    }

    /// The page as it is now. A page open in the app saves what is being typed first, so nothing typed is lost.
    private func currentPage(_ body: [String: Any]) throws -> (key: String, text: NSMutableAttributedString) {
        let day = try planDay(body["day"] ?? "today")
        guard day.day != nil else { throw Failure(message: "A page belongs to a full date (YYYY-MM-DD).") }
        NotificationCenter.default.post(name: .asmoPageWillChange, object: day.key)
        let saved = try pageRecord(day.key)?.rtfd.flatMap { NSAttributedString(rtfd: $0, documentAttributes: nil) }
        return (day.key, NSMutableAttributedString(attributedString: saved ?? NSAttributedString()))
    }

    private func store(_ text: NSAttributedString, key: String, what: String) throws {
        let record = try pageRecord(key)
        let before = record?.rtfd
        let empty = text.string.trimmed.isEmpty
        let data = empty ? nil : try text.data(from: NSRange(location: 0, length: text.length),
                                               documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        func put(_ data: Data?) throws {
            let record = try pageRecord(key)
            if let data {
                if let record { record.rtfd = data; record.updatedAt = .now } else { context.insert(DayPage(dayKey: key, rtfd: data)) }
            } else if let record {
                context.delete(record)
            }
            changedPages.append(key)
        }
        try put(data)
        remember(what) { [self] in
            NotificationCenter.default.post(name: .asmoPageWillChange, object: key)
            try put(before)
            try context.save()
            NotificationCenter.default.post(name: .asmoPageChanged, object: key)
        }
    }

    private func blockRows(_ text: NSAttributedString) -> [[String: Any]] {
        PageMarkdown.blocks(text).map { ["id": $0.id, "markdown": $0.markdown] }
    }

    private func page(_ body: [String: Any]) throws -> [String: Any] {
        let (key, text) = try currentPage(body)
        return ["day": key, "blocks": blockRows(text)]
    }

    /// Markdown as page text: pictures come with the request (or are already on the page), diagrams are drawn here.
    private func rendered(_ body: [String: Any], on page: NSAttributedString) async throws -> NSAttributedString {
        guard let markdown = body["markdown"] as? String, !markdown.trimmed.isEmpty else { throw Failure(message: "\"markdown\" is empty.") }
        var sources = PageMarkdown.Sources(images: PageMarkdown.pictures(on: page))
        for (target, encoded) in body["images"] as? [String: String] ?? [:] {
            guard let data = Data(base64Encoded: encoded) else { throw Failure(message: "The picture \"\(target)\" did not arrive whole.") }
            sources.images[target] = data
        }
        for source in try PageMarkdown.diagrams(in: markdown) where sources.diagrams[source] == nil {
            sources.diagrams[source] = try await DiagramRenderer.shared.render(source)
        }
        return try PageMarkdown.render(markdown, sources: sources)
    }

    private func block(_ id: Any?, in text: NSAttributedString) throws -> PageMarkdown.Block {
        guard let id = id as? String, let found = PageMarkdown.blocks(text).first(where: { $0.id == id }) else {
            throw Failure(message: "No block \(id ?? "(missing)") on this page; read the page again for the current ids.")
        }
        return found
    }

    private func writePage(_ body: [String: Any]) async throws -> [String: Any] {
        let (key, text) = try currentPage(body)
        let addition = try await rendered(body, on: text)
        let mode = body["mode"] as? String ?? "append"
        if mode == "replace" {
            text.setAttributedString(addition)
        } else {
            var at = text.length
            if let after = body["after"] as? String { at = after == "top" ? 0 : NSMaxRange(try block(after, in: text).range) }
            if at > 0, !text.string.hasSuffix("\n"), at == text.length {
                text.append(NSAttributedString(string: "\n", attributes: PageMarkdown.body))
                at = text.length
            }
            text.insert(addition, at: at)
        }
        try store(text, key: key, what: mode == "replace" ? "rewrote the page of \(key)" : "wrote on the page of \(key)")
        return ["day": key, "blocks": blockRows(text)]
    }

    private func setBlock(_ body: [String: Any]) async throws -> [String: Any] {
        let (key, text) = try currentPage(body)
        let target = try block(body["block"], in: text)
        let replacement = try await rendered(body, on: text)
        text.replaceCharacters(in: target.range, with: replacement)
        try store(text, key: key, what: "changed a part of the page of \(key)")
        return ["day": key, "blocks": blockRows(text)]
    }

    /// The days in a range that have a page, each with its length and first line (to see what's written where
    /// without reading every page).
    private func listPages(_ body: [String: Any]) throws -> [String: Any] {
        let from = try body["from"].map(planDay)?.key ?? "0000-00-00"
        let to = try body["to"].map(planDay)?.key ?? "9999-99-99"
        let pages = try context.fetch(FetchDescriptor<DayPage>(predicate: #Predicate { $0.dayKey >= from && $0.dayKey <= to },
                                                               sortBy: [SortDescriptor(\.dayKey)]))
        let rows: [[String: Any]] = pages.compactMap { page in
            guard let data = page.rtfd, let text = NSAttributedString(rtfd: data, documentAttributes: nil)?.string else { return nil }
            let first = text.split(separator: "\n").first.map { String($0.prefix(60)) } ?? ""
            return ["day": page.dayKey, "chars": text.count, "first": first]
        }
        return ["count": rows.count, "pages": rows]
    }

    /// Many days' pages in one go (an imported journal): {"YYYY-MM-DD": Markdown, …}. "replace" rewrites each
    /// page, "append" adds below what's there, "missing" writes only days that have no page yet. One change for
    /// `undo`, one save.
    private func importPages(_ body: [String: Any]) async throws -> [String: Any] {
        guard let pages = body["pages"] as? [String: String], !pages.isEmpty else {
            throw Failure(message: "\"pages\" is an object of day → Markdown.")
        }
        let mode = body["mode"] as? String ?? "missing"
        guard ["replace", "append", "missing"].contains(mode) else { throw Failure(message: "mode is replace, append or missing.") }
        var befores: [(String, Data?)] = []
        var written = 0, skipped = 0
        for (raw, markdown) in pages.sorted(by: { $0.key < $1.key }) {
            let day = try planDay(raw)
            guard day.day != nil else { throw Failure(message: "\(raw): a page belongs to a full date (YYYY-MM-DD).") }
            let record = try pageRecord(day.key)
            let saved = record?.rtfd.flatMap { NSAttributedString(rtfd: $0, documentAttributes: nil) }
            if mode == "missing", let saved, !saved.string.trimmed.isEmpty { skipped += 1; continue }
            NotificationCenter.default.post(name: .asmoPageWillChange, object: day.key)
            let text = NSMutableAttributedString(attributedString: mode == "append" ? (saved ?? NSAttributedString()) : NSAttributedString())
            let addition = try await rendered(["markdown": markdown], on: text)
            if text.length > 0, !text.string.hasSuffix("\n") { text.append(NSAttributedString(string: "\n", attributes: PageMarkdown.body)) }
            text.append(addition)
            befores.append((day.key, record?.rtfd))
            let data = text.string.trimmed.isEmpty ? nil : try text.data(from: NSRange(location: 0, length: text.length),
                                                                          documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            try putPage(data, key: day.key)
            written += 1
        }
        let restore = befores
        remember("imported \(written) page\(written == 1 ? "" : "s")") { [self] in
            for (key, data) in restore { try putPage(data, key: key) }
            try context.save()
            NotificationCenter.default.post(name: .asmoPageChanged, object: nil)
        }
        return ["written": written, "skipped": skipped]
    }

    private func putPage(_ data: Data?, key: String) throws {
        let record = try pageRecord(key)
        if let data {
            if let record { record.rtfd = data; record.updatedAt = .now } else { context.insert(DayPage(dayKey: key, rtfd: data)) }
        } else if let record {
            context.delete(record)
        }
        changedPages.append(key)
    }

    private func removeBlocks(_ body: [String: Any]) throws -> [String: Any] {
        let (key, text) = try currentPage(body)
        let wanted = body["blocks"] as? [String] ?? []
        guard !wanted.isEmpty else { throw Failure(message: "Say which blocks (\"blocks\": [\"b2\"]).") }
        let targets = try wanted.map { try block($0, in: text) }.sorted { $0.range.location > $1.range.location }
        for target in targets { text.deleteCharacters(in: target.range) }
        try store(text, key: key, what: "removed \(targets.count) part\(targets.count == 1 ? "" : "s") of the page of \(key)")
        return ["day": key, "blocks": blockRows(text)]
    }

    #endif

    // MARK: Important dates

    private func dates() throws -> [ImportantDateRecord] {
        try context.fetch(FetchDescriptor<ImportantDateRecord>()).sorted { ($0.month, $0.day, $0.title) < ($1.month, $1.day, $1.title) }
    }

    private func json(_ date: ImportantDateRecord) -> [String: Any] {
        var row: [String: Any] = ["id": date.id.uuidString.lowercased(), "title": date.title, "kind": date.kind.rawValue,
                                  "on": String(format: "%02d-%02d", date.month, date.day),
                                  "calendar": date.systemRaw]
        if let year = date.year { row["year"] = year }
        // Where the day is counted: a birthday is in China time unless set otherwise; "device" follows this Mac.
        row["zone"] = date.rule.timeZoneID ?? ImportantDateTimeZone.deviceID
        if date.rule.system == .lunar, let month = date.alternativeMonth, let day = date.alternativeDay {
            row["also"] = String(format: "%02d-%02d", month, day)
        }
        return row
    }

    /// "Asia/Shanghai", "America/New_York", … or "device" (wherever this Mac is).
    private func zone(_ body: [String: Any]) throws -> String?? {
        guard let text = (body["zone"] as? String)?.trimmed, !text.isEmpty else { return nil }
        if text == ImportantDateTimeZone.deviceID { return .some(ImportantDateTimeZone.deviceID) }
        guard TimeZone(identifier: text) != nil else {
            throw Failure(message: "\"zone\" is a time zone name like Asia/Shanghai or America/New_York, or \"device\".")
        }
        return .some(text)
    }

    private func setDate(_ body: [String: Any]) throws -> [String: Any] {
        guard let text = (body["id"] as? String)?.lowercased(), text.count >= 4 else { throw Failure(message: "A date \"id\" is needed.") }
        let matches = try dates().filter { $0.id.uuidString.lowercased().hasPrefix(text) }
        guard matches.count == 1 else { throw Failure(message: matches.isEmpty ? "No date with id \(text)." : "Several dates start with \(text).") }
        let date = matches[0]
        let before = (title: date.title, rule: date.rule, zone: date.timeZoneID, kind: date.kind)
        if let title = (body["title"] as? String)?.trimmed, !title.isEmpty { date.title = title }
        if let on = body["on"] as? String {
            let parts = on.split(separator: "-").map { Int($0) }
            guard parts.count == 2, let month = parts[0], let day = parts[1], (1...12).contains(month), (1...31).contains(day) else {
                throw Failure(message: "\"on\" is the month and day, MM-DD.")
            }
            date.month = month
            date.day = day
        }
        if let lunar = body["lunar"] as? Bool { date.systemRaw = (lunar ? ImportantDateSystem.lunar : .gregorian).rawValue }
        if let raw = body["kind"] as? String {
            guard let kind = ImportantDateKind(rawValue: raw) else { throw Failure(message: "\"kind\" is birthday, anniversary or holiday.") }
            date.kind = kind
        }
        if let zone = try zone(body) { date.timeZoneID = zone }
        let id = date.id
        remember("changed the date 「\(date.title)」") { [self] in
            for date in try dates() where date.id == id {
                date.title = before.title
                date.kind = before.kind
                date.rule = before.rule
                date.timeZoneID = before.zone
            }
        }
        return ["date": json(date)]
    }

    private func addDate(_ body: [String: Any]) throws -> [String: Any] {
        let title = (body["title"] as? String ?? "").trimmed
        guard !title.isEmpty else { throw Failure(message: "A date needs a \"title\".") }
        let parts = (body["on"] as? String ?? "").split(separator: "-").map { Int($0) }
        guard parts.count == 2, let month = parts[0], let day = parts[1], (1...12).contains(month), (1...31).contains(day) else {
            throw Failure(message: "\"on\" is the month and day, MM-DD.")
        }
        guard let kind = ImportantDateKind(rawValue: body["kind"] as? String ?? "birthday") else {
            throw Failure(message: "\"kind\" is birthday, anniversary or holiday.")
        }
        let system: ImportantDateSystem = body["lunar"] as? Bool == true ? .lunar : .gregorian
        let year = body["year"] as? Int ?? (body["year"] as? String).flatMap { Int($0) }
        let record = ImportantDateRecord(title: title, kind: kind, rule: ImportantDateRule(month: month, day: day, year: year, system: system))
        if let zone = try zone(body) { record.timeZoneID = zone }
        context.insert(record)
        let id = record.id
        remember("added the date 「\(title)」") { [self] in
            for date in try dates() where date.id == id { context.delete(date) }
        }
        return ["date": json(record)]
    }

    private func removeDate(_ body: [String: Any]) throws -> [String: Any] {
        guard let text = (body["id"] as? String)?.lowercased(), text.count >= 4 else { throw Failure(message: "A date \"id\" is needed.") }
        let matches = try dates().filter { $0.id.uuidString.lowercased().hasPrefix(text) }
        guard matches.count == 1 else { throw Failure(message: matches.isEmpty ? "No date with id \(text)." : "Several dates start with \(text).") }
        let date = matches[0]
        let row = json(date)
        let saved = (id: date.id, title: date.title, kind: date.kind, rule: date.rule, original: date.original, key: date.importKey,
                     month: date.alternativeMonth, day: date.alternativeDay)
        remember("removed the date 「\(date.title)」") { [self] in
            let back = ImportantDateRecord(title: saved.title, kind: saved.kind, rule: saved.rule, original: saved.original, importKey: saved.key)
            back.id = saved.id
            back.alternativeMonth = saved.month
            back.alternativeDay = saved.day
            context.insert(back)
        }
        context.delete(date)
        return ["removed": row]
    }

    // MARK: Undo

    /// A task as it was, to put back.
    private struct Saved {
        let id: UUID, title: String, note: String, schedule: PlanDate?, endMinute: Int?, completed: Bool, createdAt: Date
        let parentID: UUID?, carriedFrom: String?, sourceText: String?, titleStyle: String?, importKey: String?

        init(_ task: TaskRecord) {
            id = task.id; title = task.title; note = task.note; schedule = task.schedule; endMinute = task.endMinute
            completed = task.completed; createdAt = task.createdAt; parentID = task.parentID; carriedFrom = task.carriedFrom
            sourceText = task.sourceText; titleStyle = task.titleStyle; importKey = task.importKey
        }

        func apply(to task: TaskRecord) {
            task.title = title; task.note = note; task.schedule = schedule; task.endMinute = endMinute
            task.completed = completed; task.createdAt = createdAt; task.parentID = parentID; task.carriedFrom = carriedFrom
            task.sourceText = sourceText; task.titleStyle = titleStyle; task.importKey = importKey
        }
    }

    private func restore(_ saved: [Saved]) throws {
        let all = try tasks()
        for item in saved {
            if let task = all.first(where: { $0.id == item.id }) { item.apply(to: task); continue }
            let task = TaskRecord(id: item.id, title: item.title, schedule: item.schedule)
            item.apply(to: task)
            context.insert(task)
        }
    }

    private func summary(_ titles: [String]) -> String {
        titles.count == 1 ? "「\(titles[0])」" : "\(titles.count) items (「\(titles[0])」…)"
    }

    /// For the in-app assistant: one request as a JSON string in, the JSON answer out.
    func perform(_ request: [String: Any]) async -> String {
        let data = (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
        return String(decoding: await runInTurn(data), as: UTF8.self)
    }

    /// How many changes can be taken back now (to undo exactly what one assistant reply did).
    var undoDepth: Int { undos.count }

    /// Takes back changes until only `depth` remain.
    func undo(to depth: Int) {
        while undos.count > depth, let last = undos.popLast() { try? last.revert() }
        try? context.save()
    }

    /// Takes back the last change made through `asmo`.
    private func undo() throws -> [String: Any] {
        guard let last = undos.popLast() else {
            throw Failure(message: "Nothing to undo: only changes made with asmo since the app last started can be taken back.")
        }
        try last.revert()
        return ["undone": last.what, "left": undos.count]
    }

    // MARK: Pieces

    private func find(_ id: String) throws -> TaskRecord? {
        // A full id, or the first characters of one (as printed by the command) when they point at one task.
        let wanted = id.lowercased()
        let matches = try tasks().filter { $0.id.uuidString.lowercased().hasPrefix(wanted) }
        if matches.count > 1 { throw Failure(message: "Several tasks start with \(id); give more characters.") }
        return wanted.count >= 4 ? matches.first : nil
    }

    private func required(_ id: Any?) throws -> TaskRecord {
        guard let text = id as? String, let task = try find(text) else { throw Failure(message: "No task with id \(id ?? "(missing)").") }
        return task
    }

    private func requiredRoutine(_ id: Any?) throws -> RoutineRecord {
        guard let text = (id as? String)?.lowercased(), text.count >= 4 else { throw Failure(message: "A routine \"id\" is needed.") }
        let matches = try routines().filter { $0.id.uuidString.lowercased().hasPrefix(text) }
        guard matches.count == 1 else { throw Failure(message: matches.isEmpty ? "No routine with id \(text)." : "Several routines start with \(text).") }
        return matches[0]
    }

    private func ids(_ body: [String: Any]) throws -> [Any?] {
        let list = body["ids"] as? [String] ?? (body["id"] as? String).map { [$0] } ?? []
        guard !list.isEmpty else { throw Failure(message: "Give \"id\" or \"ids\".") }
        return list
    }

    private func family(of task: TaskRecord) throws -> [TaskRecord] {
        let all = try tasks()
        var result = [task]
        var index = 0
        while index < result.count, result.count < 200 {
            let parent = result[index].id
            result += all.filter { $0.parentID == parent && !result.contains($0) }
            index += 1
        }
        return result
    }

    /// Timed items by time, then the untimed in the order they were written.
    private func inDayOrder(_ a: TaskRecord, _ b: TaskRecord) -> Bool {
        (a.schedule?.minuteOfDay ?? 10_000, a.createdAt) < (b.schedule?.minuteOfDay ?? 10_000, b.createdAt)
    }

    private func tree(_ task: TaskRecord, in all: [TaskRecord], depth: Int = 0) -> [String: Any] {
        var row = json(task)
        let children = depth < 3 ? all.filter { $0.parentID == task.id }.sorted(by: inDayOrder) : []
        if !children.isEmpty { row["subtasks"] = children.map { tree($0, in: all, depth: depth + 1) } }
        row["parent"] = nil
        return row
    }

    private func json(_ task: TaskRecord) -> [String: Any] {
        var row: [String: Any] = ["id": task.id.uuidString.lowercased(), "title": task.title, "done": task.completed]
        if let schedule = task.schedule {
            row["day"] = schedule.key
            if let minute = schedule.minuteOfDay { row["time"] = clockText(minute) }
        }
        if let end = task.endMinute { row["end"] = clockText(end) }
        if !task.note.isEmpty { row["note"] = task.note }
        if let parent = task.parentID { row["parent"] = parent.uuidString.lowercased() }
        if let carried = task.carriedFrom { row["carriedFrom"] = carried }
        if task.calendarLinked { row["appleCalendar"] = true }
        return row
    }

    private func json(_ routine: RoutineRecord) -> [String: Any] {
        var row: [String: Any] = ["id": routine.id.uuidString.lowercased(), "title": routine.title,
                                  "weekdays": routine.weekdays.sorted(), "repeats": routine.ruleLabel,
                                  "from": routine.startDay]
        if let day = routine.monthDay { row["monthDay"] = day }
        if let start = routine.startMinute { row["time"] = clockText(start) }
        if let end = routine.endMinute { row["end"] = clockText(end) }
        if let until = routine.endDay { row["until"] = until }
        return row
    }

    private func clockText(_ minute: Int) -> String { String(format: "%02d:%02d", (minute / 60) % 24, minute % 60) }

    private func weekday(_ day: PlanDate) -> String {
        guard let date = day.date(in: clock.calendar) else { return "" }
        return ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][clock.calendar.component(.weekday, from: date) - 1]
    }

    /// The person's own words for when ("明天下午三点到四点", "next Friday 9am"), read by the date rules the app uses
    /// for typing, so an assistant never has to work out dates itself. Nil when there are none or they aren't a date.
    private func spoken(_ value: Any?, around day: PlanDate) -> (day: PlanDate, start: Int?, end: Int?)? {
        guard let words = (value as? String)?.trimmed, !words.isEmpty,
              let (plan, end) = CaptureParser.explicitSchedule(words, clock: clock, selectedDay: day) else { return nil }
        let date = plan.day == nil ? PlanDate(year: plan.year, month: plan.month) : plan.dayOnly
        return (date, plan.minuteOfDay, plan.minuteOfDay == nil ? nil : end)
    }

    /// "HH:MM" → minutes; null or "" → nil (no time).
    private func minutes(_ value: Any) throws -> Int? {
        if value is NSNull { return nil }
        guard let text = value as? String else { throw Failure(message: "Times are written \"HH:MM\".") }
        if text.trimmed.isEmpty { return nil }
        guard let minute = PlannerClockTime.parse(text.trimmed) else { throw Failure(message: "\"\(text)\" is not a time (HH:MM, 24-hour).") }
        return minute
    }

    private func setTime(_ task: TaskRecord, from: Int?, to: Int?, schedule: inout PlanDate) throws {
        guard from != nil || to == nil else { throw Failure(message: "An \"end\" needs a start \"time\".") }
        guard from == nil || schedule.day != nil else { throw Failure(message: "A time needs a full date, not just a month.") }
        schedule.hour = from.map { $0 / 60 }
        schedule.minute = from.map { $0 % 60 }
        task.schedule = schedule
        // An end before the start is the next day ("23:00–01:00").
        task.endMinute = to.map { end in from.map { end <= $0 ? end + 1440 : end } ?? end }
    }

    /// "YYYY-MM-DD", "YYYY-MM" (a plan for the month), today / tomorrow / yesterday, or "+3" / "-1" days from today.
    private func planDay(_ value: Any) throws -> PlanDate {
        guard let raw = value as? String else { throw Failure(message: "Days are written YYYY-MM-DD.") }
        let text = raw.trimmed.lowercased()
        let offsets = ["today": 0, "tomorrow": 1, "yesterday": -1]
        if let days = offsets[text] ?? ((text.hasPrefix("+") || text.hasPrefix("-")) ? Int(text) : nil),
           let day = clock.offset(days: days) { return day }
        let parts = text.split(separator: "-").map { Int($0) }
        if parts.count == 3, let year = parts[0], let month = parts[1], let day = parts[2] {
            let plan = PlanDate(year: year, month: month, day: day)
            if plan.date(in: clock.calendar) != nil { return plan }
        }
        if parts.count == 2, let year = parts[0], let month = parts[1], (1...12).contains(month) { return PlanDate(year: year, month: month) }
        // Words for a day ("明天", "下周五", "next Friday"), read by the date rules.
        if let (plan, _) = CaptureParser.explicitSchedule(raw.trimmed, clock: clock, selectedDay: clock.today) {
            return plan.day == nil ? PlanDate(year: plan.year, month: plan.month) : plan.dayOnly
        }
        throw Failure(message: "\"\(raw)\" is not a day (YYYY-MM-DD, YYYY-MM, today, tomorrow, +N).")
    }

    /// [1…7] with 1 = Sunday, or "daily" / "weekdays" / "weekends".
    private func weekdays(_ value: Any?) throws -> Set<Int> {
        switch value {
        case nil, is NSNull: return Set(1...7)
        case let name as String:
            switch name.lowercased() {
            case "daily", "everyday": return Set(1...7)
            case "weekdays": return [2, 3, 4, 5, 6]
            case "weekends": return [1, 7]
            default:
                let names = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
                let days = name.lowercased().split(separator: ",").compactMap { names[String($0.trimmingCharacters(in: .whitespaces).prefix(3))] }
                guard !days.isEmpty, days.count == name.split(separator: ",").count else {
                    throw Failure(message: "\"weekdays\" is daily, weekdays, weekends, or names like mon,thu.")
                }
                return Set(days)
            }
        case let list as [Int] where !list.isEmpty && list.allSatisfy((1...7).contains): return Set(list)
        default: throw Failure(message: "\"weekdays\" is daily, weekdays, weekends, names like mon,thu, or numbers 1–7 (1 = Sunday).")
        }
    }
}
