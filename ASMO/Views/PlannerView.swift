import Combine
import EventKit
import SwiftData
import SwiftUI

enum PlannerPage: String, CaseIterable {
    case day = "当天"
    case month = "月计划"
    case inbox = "未安排"

    var icon: String {
        switch self {
        case .day: "sun.max"
        case .month: "calendar"
        case .inbox: "tray"
        }
    }
}

private enum PlannerSheet: String, Identifiable {
    case jump, archive, settings, editor, important, birthdayGreeting
    case captureReview
    var id: Self { self }
}

private struct DesktopDraftContext: Hashable {
    let schedule: PlanDate?
}

private struct ArchivedDayEntry: Sendable, Codable {
    let documentDigest: String
    let defaultYear: Int
    let entry: ArchiveEntry
    var recordKey: String { documentDigest + ":" + entry.id }
}

/// The imported history, already sorted into days, saved after each indexing: launch shows it in the first
/// frame (re-reading the documents takes a moment and runs in the background to refresh it).
private enum ArchiveIndexCache {
    private static var url: URL {
        // One per store: Debug test runs (ASMO_TEST_STORE) never touch the real one.
        let test = ProcessInfo.processInfo.environment["ASMO_TEST_STORE"] == "1"
        return AppPaths.caches
            .appendingPathComponent(test ? "archive-index-test.json" : "archive-index.json")
    }
    /// Read once per launch.
    static let atLaunch: [PlanDate: [ArchivedDayEntry]] = {
        guard let data = try? Data(contentsOf: url),
              let pairs = try? JSONDecoder().decode([Pair].self, from: data) else { return [:] }
        return Dictionary(pairs.map { ($0.day, $0.entries) }, uniquingKeysWith: { first, _ in first })
    }()

    static func clear() { try? FileManager.default.removeItem(at: url) }

    static func save(_ days: [PlanDate: [ArchivedDayEntry]]) {
        let pairs = days.map { Pair(day: $0.key, entries: $0.value) }
        if let data = try? JSONEncoder().encode(pairs) { try? data.write(to: url, options: .atomic) }
    }

    private struct Pair: Codable { let day: PlanDate; let entries: [ArchivedDayEntry] }
}

/// Keys of items created in the last minute, so one organize pass can't create the same item twice.
@MainActor
enum RecentItems {
    private static var keys: [String: Date] = [:]

    static func insert(_ key: String) -> Bool {
        let now = Date.now
        keys = keys.filter { now.timeIntervalSince($0.value) < 60 }
        guard keys[key] == nil else { return false }
        keys[key] = now
        return true
    }
}

/// What one organize pass did, so it can be undone as one step (撤销 in the notice, or ⌘Z on the page).
@MainActor
final class OrganizeBatch {
    static var current: OrganizeBatch?
    static var last: OrganizeBatch?
    let day: PlanDate
    /// The page as it was before the pass.
    let page: Data?
    var created: [UUID] = []
    var routines: [UUID] = []
    var revised: [(id: UUID, schedule: PlanDate?, end: Int?, completed: Bool)] = []
    var routineMarks: [(routine: UUID, day: String)] = []
    var undone = false
    var isEmpty: Bool { created.isEmpty && routines.isEmpty && revised.isEmpty && routineMarks.isEmpty }

    init(day: PlanDate, page: Data?) { self.day = day; self.page = page }
}

private struct AgendaCalendarRequest: Equatable {
    let first: PlanDate?
    let last: PlanDate?
    let timeZone: TimeZone
    let revision: Int
    let linkedAnchors: [UUID: Date]
}

@MainActor
struct PlannerView: View {
    let system: SystemPlanner
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \TaskRecord.createdAt) private var tasks: [TaskRecord]
    @Query(sort: \DayNote.updatedAt, order: .reverse) private var notes: [DayNote]
    @Query(sort: \ArchiveDocument.addedAt, order: .reverse) private var archives: [ArchiveDocument]
    @Query private var importantDates: [ImportantDateRecord]
    @Query(sort: \JournalArchiveEdit.updatedAt, order: .reverse) private var journalEdits: [JournalArchiveEdit]
    @Query(sort: \RoutineRecord.order) private var routines: [RoutineRecord]
    @Query private var routineMarks: [RoutineMark]
    /// Day pages are read by day (or just their days), never all at once: a query over every page refetched
    /// 1,600 pages of history on each redraw. `pagesVersion` redraws when any save changes them.
    @State private var pagesVersion = 0
    @StateObject private var pageController = PageController()

    #if !os(macOS)
    @State private var expandedDone = false
    #endif
    @State private var jumpDate = Date.now
    @State private var selected = CaptureClock().today
    @State private var lastKnownToday = CaptureClock().today
    /// Where today is relative to what 逐日 shows: 0 on screen, -1 above, 1 below.
    @State private var todayOffscreen = 0
    @State private var leftAt: Date?
    @State private var page: PlannerPage = .day
    @State private var entry = ""
    @State private var status = ""
    @State private var error: String?
    @State private var sheet: PlannerSheet?
    @State private var editor: EditorInput?
    @State private var initialImportantDate: ImportantDateRecord?
    @State private var greetingDraft: BirthdayGreetingDraft?
    @State private var queue: [CaptureDraft] = []
    @State private var processing = false
    @State private var voiceSampleTime: Double?
    @State private var voiceSampleCanPass = false
    @State private var transferringIDs: Set<UUID> = []
    @State private var undoIDs: Set<UUID> = []
    @State private var voice = VoiceCapture()
    @FocusState private var entryFocused: Bool
    @State private var desktopDraft: DesktopDraftContext?
    @State private var desktopEntryOpen = false
    @State private var savedDesktopDrafts: [DesktopDraftContext: String] = [:]
    @State private var desktopReview: [CaptureDraft] = []
    @State private var desktopFallbackAvailable = false
    @State private var archivedDays: [PlanDate: [ArchivedDayEntry]] = ArchiveIndexCache.atLaunch
    /// Bumped whenever the imported history is (re)indexed, so the calendar redraws with it.
    @State private var archiveRevision = 0
    @State private var archiveSource: ArchiveDocument?
    @State private var archiveDay: PlanDate?
    @State private var archiveUnplaced = false
    @State private var agendaAnchor = CaptureClock().today
    @State private var monthCursor = CaptureClock().today
    @State private var monthDetail: PlanDate?
    @State private var monthEvents: (days: [PlanDate: [SystemEvent]], linked: Set<UUID>) = ([:], [])
    @Namespace private var workspaceMotion
    @State private var agendaDayExpanded = true
    @State private var journalBefore = 14
    @State private var journalAfter = 21
    @State private var journalScroll = ScrollPosition(idType: PlanDate.self)
    @State private var journalReadyAnchor: PlanDate?
    @State private var revealJournal: Task<Void, Never>?
    @State private var journalNoteDate: PlanDate?
    @State private var journalEvents: (days: [PlanDate: [SystemEvent]], linked: Set<UUID>) = ([:], [])
    @State private var earliestArchiveDay: PlanDate?
    @State private var dropDay: PlanDate?
    @State private var notice: PlannerNotice?
    @State private var barOpen = false
    @State private var barText = ""
    @State private var barRecording = false
    @State private var barTranscribing = false
    @State private var routineAddingDay: PlanDate?
    /// While set, lines typed into a day's entry line become subtasks of this task (Tab / Shift-Tab).
    @State private var entryParent: UUID?
    @State private var editingRoutine: RoutineRecord?
    @State private var organizingDay: PlanDate?
    /// The document is the home: write freely; the cards (逐日) and the calendar are other views of the same items.
    /// The day open as its own page (nil = the 逐日 overview or the calendar). ASMO opens on today's page.
    @State private var documentDay: PlanDate? = nil
    /// The 逐日 card being written in (it becomes the document in place).
    @State private var editingDay: PlanDate?
    @State private var finishingEdit = false
    @State private var monthMounted = false
    @State private var organizeTick = 0
    /// Bumped to redraw the open page from storage (after undoing an organize pass).
    @State private var pageRebuild = 0
    /// The page's microphone: transcribing what was said, then organizing it (shown in the status pill).
    @State private var pageTranscribing = false
    @State private var voiceOrganizing = false
    /// The Apple Intelligence assistant (iPhone) is working on what was typed or said.
    /// Mac home: "paper" (one continuous document, like a doc you just write in) or "calendar".
    @AppStorage("macHome") private var macHome = "paper"
    /// The day the paper opens on (today, or a day double-clicked in the calendar).
    @State private var paperFocus: PlanDate?
    @State private var assistantWorking = false
    @State private var assistantCommands: AgentCommands?
    /// Something said or typed in the bar is being organized by the model.
    /// Debug builds: "pill:listening|transcribing|organizing|off" shows the voice pill without a microphone.
    @State private var debugVoicePhase: VoicePhase?
    @State private var documentOrganizing = false
    /// Pages organizing right now (each day's box organizes on its own).
    @State private var organizingPages = 0
    /// The writing view's first day (the day it was opened on); it lists the days around it, each in its own box.
    @State private var writingFrom: PlanDate?
    /// The writing view has scrolled to its day (it stays hidden until then, so it never shows a jump).
    @State private var writingPlaced = false
    @State private var leavingDocument = false
    /// The page whose writing is being organized in the background (dates in it are read from this day).
    @State private var organizingBase: PlanDate?
    @AppStorage("voiceLocale") private var voiceLocale = "zh-Hans-CN"
    @AppStorage("verifiedVoiceAutoSave") private var verifiedVoiceAutoSave = false
    @AppStorage("voiceSampleCount") private var voiceSampleCount = 0
    @AppStorage("voiceSampleCorrect") private var voiceSampleCorrect = 0
    @AppStorage("voiceSampleSeconds") private var voiceSampleSeconds = 0.0

    private var clock: CaptureClock { CaptureClock() }
    private var theme: PlannerTheme { PlannerTheme(dark: scheme == .dark) }
    private var linkedIDs: Set<UUID> { Set(system.reminders.compactMap(\.asmoID)) }
    private var localItems: [TaskRecord] {
        let linked = linkedIDs
        return tasks.filter { !linked.contains($0.id) }
    }
    private var isToday: Bool { selected.dayOnly == clock.today }

    private func voiceStop(_ phase: VoicePhase) -> (() -> Void)? {
        phase == .listening ? { toggleDocumentVoice() } : nil
    }

    /// What floats at the bottom: notices, then the voice status, the 今天 pill and (on iPhone) the capture bar.
    private var bottomControls: some View {
        VStack(spacing: 10) {
            if let notice {
                PlannerNoticeBar(notice: notice, theme: theme) {
                    if self.notice?.id == notice.id { withAnimation(.smooth(duration: 0.2)) { self.notice = nil } }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(notice.id)
            }
            if let phase = voicePhase {
                VoiceStatusPill(phase: phase, voice: voice, theme: theme, stop: voiceStop(phase))
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            } else if editingDay == nil {
            HStack(spacing: 10) {
            if !barOpen, !Self.compactLayout, let direction = todayDirection {
                TodayButton(direction: direction, next: page == .day ? todayStatus.next : nil, theme: theme, action: showToday)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            // The Mac has no capture bar: things are added by hand on a day, or by an agent through `asmo`.
            #if os(iOS)
            CaptureBar(text: $barText, expanded: $barOpen,
                       preview: barText.trimmed.isEmpty || barCommand != nil ? []
                           : Dictation.items(barText, clock: clock, defaultDay: clock.today),
                       command: barCommand.flatMap(describe),
                       recording: barRecording, transcribing: barTranscribing, theme: theme, today: clock.today,
                       dayName: friendlyDay, toggleVoice: toggleBarVoice, submit: submitBar)
            #endif
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: todayDirection)
            } else {
                #if os(iOS)
                EmptyView()
                #endif
            }
        }
        .padding(.horizontal, Self.compactLayout ? 14 : 24)
        .padding(.bottom, Self.compactLayout ? 8 : 20)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: voicePhase)
    }

    /// The day whose page is open as an editor right now.
    private var openPageDay: PlanDate? {
        #if os(macOS)
        documentDay
        #else
        editingDay
        #endif
    }

    /// The voice status pill: the page's microphone listening / transcribing, or spoken writing being organized.
    private var voicePhase: VoicePhase? {
        if let debugVoicePhase { return debugVoicePhase }
        if pageController.recording { return .listening }
        if pageTranscribing { return .transcribing }
        if (voiceOrganizing && documentOrganizing) || assistantWorking { return .organizing }
        return nil
    }

    var body: some View {
        #if DEBUG
        let started = Date.now
        defer { PerfLog.note("plannerBody", since: started) }
        #endif
        return workspace
        .tint(theme.accent)
        .task {
            #if os(macOS)
            rollOverdueTasks()
            #if DEBUG
            PerfLog.watch()
            #endif
            // An empty today opens as a blank page, ready to write.
            let today = clock.today
            // 逐日 is the writing view: open on today, cursor in today's box.
            // Items struck through on a page before strike meant "done": they're done.
            #if os(macOS)
            // A look change once saved the page's own ink as a line's color: those aren't the writer's colors.
            for task in tasks {
                guard let style = task.titleStyle else { continue }
                let kept = style.split(separator: " ").filter { part in
                    guard part.hasPrefix("#"), part.count == 7, let value = Int(part.dropFirst(), radix: 16) else { return true }
                    let color = NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                                        blue: CGFloat(value & 255) / 255, alpha: 1)
                    return !DocCoordinator.isThemeColor(color)
                }
                let joined = kept.joined(separator: " ")
                if joined != style { task.titleStyle = joined.isEmpty ? nil : joined }
            }
            #endif
            for task in tasks where (task.titleStyle ?? "").split(separator: " ").contains("s") {
                task.completed = true
                let rest = (task.titleStyle ?? "").split(separator: " ").filter { $0 != "s" }
                task.titleStyle = rest.isEmpty ? nil : rest.joined(separator: " ")
            }
            persist()
            // The calendar is home: open on this month (a day is written by clicking it).
            instantly { page = .month; monthCursor = today; selected = today }
            // Teach dictation the English words and names in the user's own items.
            let words = tasks.suffix(400).flatMap { $0.title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) }
                .map(String.init).filter { $0.count >= 3 && $0.allSatisfy(\.isASCII) }
            var counts: [String: Int] = [:]
            for word in words { counts[word, default: 0] += 1 }
            VoiceCapture.vocabulary = counts.sorted { $0.value > $1.value }.map(\.key)
            #else
            // The calendar is home: open on this month (tapping a day opens its page).
            instantly { page = .month; monthCursor = clock.today; selected = clock.today }
            #endif
            await refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                updateCurrentDay()
                returnAfterAway()
                Task { await refresh() }
            }
            if phase != .active, leftAt == nil { leftAt = .now }
            if phase == .background { voice.cancel() }
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in leftAt = .now }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in returnAfterAway() }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in updateCurrentDay() }
        // The day-changed notice can be missed (asleep at midnight, clock changed): check now and then too.
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in updateCurrentDay() }
        #if os(macOS)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in updateCurrentDay() }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .asmoToday)) { _ in showToday() }
        // A save that touched day pages (here, or by an agent through the bridge): draw them again.
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave).receive(on: RunLoop.main)) { note in
            let touched = [ModelContext.NotificationKey.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
                .compactMap { note.userInfo?[$0.rawValue] as? [PersistentIdentifier] }.joined()
            if touched.contains(where: { $0.entityName == "DayPage" }) { pagesVersion &+= 1 }
        }
        .onReceive(voiceKeyEvents, perform: handleVoiceKey)
        #if os(iOS) && DEBUG
        .task { await PhoneDebugHooks.watch() }
        #endif
        .onOpenURL { url in
            guard url.scheme == "asmo", url.host == "item", let id = UUID(uuidString: url.lastPathComponent) else { return }
            Task {
                await refresh()
                if let item = system.reminders.first(where: { $0.asmoID == id }) { edit(item) }
                else if let task = tasks.first(where: { $0.id == id }) { edit(task) }
            }
        }
        .accessibilityHidden(sheet != nil)
        .overlay { plannerOverlay }
        .alert(AppName.display, isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    @ViewBuilder
    private var plannerOverlay: some View {
        #if os(macOS)
        if Self.calendarHome, let day = documentDay {
            dayEditor(day)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.97).combined(with: .opacity))
        }
        #endif
        if let sheet {
            ZStack {
                Color.black.opacity(scheme == .dark ? 0.52 : 0.28).ignoresSafeArea()
                Group {
                    switch sheet {
                    case .captureReview:
                        DesktopCaptureReview(drafts: desktopReview, source: entry, theme: theme, close: closePanel) { drafts in
                            self.sheet = nil
                            capture(drafts, forceReview: false)
                        }
                    case .birthdayGreeting:
                        if let greetingDraft {
                            BirthdayGreeting(draft: greetingDraft, theme: theme, close: closePanel) { time, zone in
                                previewGreeting(greetingDraft, time: time, zone: zone)
                            }
                        }
                    case .jump: jumpSheet
                    case .important: ImportantDatesView(initialRecord: initialImportantDate)
                    case .editor:
                        if let editor {
                            TaskEditor(input: editor, system: system, save: saveEditor, delete: deleteEditor).id(editor.id)
                        }
                    case .archive:
                        #if os(macOS)
                        ArchiveView(archives: archives, localTasks: localItems, reminders: system.reminders, dayNotes: notes,
                                    initialDocument: archiveSource, initialDate: archiveDay, initialUnplaced: archiveUnplaced)
                        #else
                        ArchiveView(archives: archives, localTasks: localItems, reminders: system.reminders, dayNotes: notes)
                        #endif
                    case .settings:
                        #if os(macOS)
                        PlannerSettings(system: system, openArchive: { self.sheet = .archive },
                                        openImportant: { self.sheet = .important })
                        #else
                        PlannerSettings(system: system)
                        #endif
                    }
                }
                .environment(\.closePlannerPanel, closePanel)
            }
        }
    }

    private func closePanel() {
        #if os(macOS)
        if sheet == .archive { archiveSource = nil; archiveDay = nil; archiveUnplaced = false }
        #endif
        if sheet == .important { initialImportantDate = nil }
        if sheet == .birthdayGreeting { greetingDraft = nil }
        sheet = nil
        advanceReview()
    }

    private var workspace: some View {
        #if DEBUG
        let started = Date.now
        defer { PerfLog.note("workspace", since: started) }
        #endif
        return VStack(spacing: 0) {
            // Mac: no top bar (the calendar's own row has the month, arrows and settings).
            if !Self.calendarHome {
            DesktopWorkspaceHeader(current: documentDay != nil ? 0 : page == .month ? 1 : 0, theme: theme, select: selectWorkspace, tabs: !Self.calendarHome,
                                   today: showToday, settings: { sheet = .settings })
            }
            #if os(macOS)
            // Mac: the calendar is home; a day is written in its popup (DayEditorSheet). The month only redraws
            // when what it shows changed (opening a day, typing in it, the notice… leave it alone: no hitch).
            // The Mac is one document; seeing the month is Apple Calendar's job (the 逐日 calendar there).
            paperHome
            #else
            // iPhone: the calendar is home; a day opens as a pushed page (system back button and edge swipe).
            NavigationStack {
                ZStack(alignment: .bottom) {
                CalendarHost(key: calendarKey) { desktopMonth }
                    .equatable()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // While typing in the bar, a tap anywhere on the calendar puts the keyboard away (and only that).
                    .overlay {
                        if barOpen {
                            theme.ink.opacity(0.04).ignoresSafeArea()
                                .onTapGesture { closeBar() }
                                .transition(.opacity)
                        }
                    }
                    .animation(.smooth(duration: 0.2), value: barOpen)
                    // The calendar keeps its shape when the keyboard comes up; only the bar rides above it.
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                    bottomControls
                }
                    .background(theme.paper.ignoresSafeArea())
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(item: $editingDay) { day in
                        writingView
                            .navigationTitle(AppLanguage.dayTitle(month: day.month, day: day.day ?? 1) + " " + journalWeekday(day))
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbarBackground(theme.paper, for: .navigationBar)
                            .toolbar {
                                if pageController.isEditing {
                                    ToolbarItem(placement: .confirmationAction) {
                                        Button("完成") { pageController.resignFocus() }.fontWeight(.semibold)
                                    }
                                } else if day == clock.today, todayStatus.total > 0 {
                                    ToolbarItem(placement: .topBarTrailing) {
                                        ProgressRing(done: todayStatus.done, total: todayStatus.total, theme: theme)
                                    }
                                }
                            }
                    }
            }
            .tint(theme.accent)
            // However the page is left (back button, edge swipe, another day), what was written is kept and organized.
            .onChange(of: editingDay) { left, _ in
                guard let left else { return }
                storePhonePage(left)
                pageController.resignFocus()
                Task { try? await Task.sleep(for: .milliseconds(400)); await organizeStoredPage(left) }
            }
            #endif
        }
        .background(theme.paper.ignoresSafeArea())
        .foregroundStyle(theme.ink)
        #if os(macOS)
        // Only while there is something to show (a notice, the microphone): an empty layer there still took the
        // clicks meant for the bottom of the document.
        .overlay(alignment: .bottom) {
            if notice != nil || voicePhase != nil { bottomControls }
        }
        #endif
        .onChange(of: documentOrganizing) { _, busy in if !busy { voiceOrganizing = false } }
        .sheet(item: $editingRoutine) { routine in
            RoutineEditor(routine: routine, theme: theme,
                          save: { title, days in updateRoutine(routine, title: title, weekdays: days); editingRoutine = nil },
                          stop: { editingRoutine = nil; stopRoutine(routine) })
        }
        .task(id: archives.map(\.digest)) { await indexArchiveDays() }
        .onChange(of: agendaAnchor) { _, _ in
            journalReadyAnchor = nil
            journalBefore = 14
            journalAfter = 21
        }
    }

    /// One coherent zoom instead of a few flying labels: the month is the zoomed-out view of the days.
    /// Going to 日历 the day page shrinks away while the month settles from slightly larger; coming back reverses it.
    private var journalTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.9, anchor: .top).combined(with: .opacity)
    }

    private var calendarTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 1.07, anchor: .top).combined(with: .opacity)
    }

    /// Per-item flying was half-convincing (only some text moved), so it is off.
    private var desktopMotion: DesktopTaskMotion? { nil }

    private func switchDesktopView(calendar: Bool) {
        guard (page == .month) != calendar, !desktopCaptureBusy else { return }
        // Each view opens on the present: 逐日 on today, 日历 on this month. No carried-over position.
        if calendar {
            hideDesktopCapture()
            #if os(macOS)
            // The day boxes stay alive under the calendar; don't leave one taking keystrokes.
            pageController.textView?.window?.makeFirstResponder(nil)
            #endif
            journalNoteDate = nil
            var quiet = Transaction(); quiet.disablesAnimations = true
            withTransaction(quiet) { monthCursor = clock.today }
            moveDesktopWorkspace(to: .month)
            // Selecting today folds rows in 逐日; wait until it has faded out so nothing moves on screen.
            revealJournal?.cancel()
            revealJournal = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(360))
                guard !Task.isCancelled, page == .month else { return }
                withTransaction(quiet) { selected = clock.today }
            }
        } else {
            navigateAgenda(to: clock.today)
        }
    }

    private func selectWorkspace(_ index: Int) {
        hideDesktopCapture()
        if editingDay != nil {
            #if os(macOS)
            if index == 1 { leaveEditing { switchDesktopView(calendar: true) } } else { openDocument(clock.today) }
            #else
            if index == 1 { leaveEditing { switchDesktopView(calendar: true) } } else { finishEditing() }
            #endif
            return
        }
        if documentDay != nil {
            if index == 0 { closeDocument(); return }
            closeDocument { switchDesktopView(calendar: true) }
            return
        }
        switchDesktopView(calendar: index == 1)
    }

    /// Opens a day as its own page.
    /// Clicking into a day: its 逐日 card turns into the page, in place.
    private func openDocument(_ day: PlanDate) {
        hideDesktopCapture()
        let target = day.dayOnly
        #if os(macOS)
        #if DEBUG
        PerfLog.opened = .now
        #endif
        // The day's page pops up over the calendar (another day open: it closes and is organized first).
        if let current = documentDay {
            if current != target { closeDocument(to: target) }
        } else {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.18)) { documentDay = target }
        }
        selected = target
        #else
        if let current = editingDay, current != target {
            finishEditing { beginEditing(target) }
            return
        }
        beginEditing(target)
        #endif
    }

    private func beginEditing(_ day: PlanDate) {
        selected = day
        agendaDayExpanded = true
        if page != .day && !Self.calendarHome { instantly { page = .day } }
        #if os(macOS)
        openDocument(day)
        return
        #endif
        // The writing view opens on this day; the overview stays where it was underneath.
        instantly { writingFrom = day }
        #if os(iOS)
        // A day opens to be read: from the top, without the keyboard. Tapping the page starts writing.
        pageController.load(pageData(day))
        pageController.resignFocus()
        #endif
        editingDay = day
    }

    /// Leaving the page for another view: start organizing, then go at once. Results still land in their days
    /// when the model returns (the page files them after it closes), so nothing waits on it.
    private func leaveEditing(then next: @escaping () -> Void) {
        guard let day = editingDay, !finishingEdit else { return }
        organizeTick += 1
        #if os(iOS)
        editingDay = nil
        next()
        return
        #endif
        Task { @MainActor in
            // One frame so the page reads its lines before it goes.
            try? await Task.sleep(for: .milliseconds(50))
            instantly { editingDay = nil }
            next()
            try? await Task.sleep(for: .milliseconds(700))
            await organizeStoredPage(day)
        }
    }

    /// Leaving the card: organize what was written (a progress bar shows), then turn back into the 逐日 view.
    private func finishEditing(then next: (() -> Void)? = nil) {
        #if os(macOS)
        // The day's page closes (what's written is organized onto the calendar).
        closeDocument()
        next?()
        return
        #endif
        #if os(iOS)
        guard let day = editingDay else { return }
        instantly { selected = day }
        editingDay = nil
        next?()
        return
        #else
        guard let day = editingDay, !finishingEdit else { return }
        finishingEdit = true
        organizeTick += 1
        #endif
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            var waited = 0
            while documentOrganizing && waited < 200 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            // Back on the overview at the day that was being written.
            let last = editingDay ?? day
            instantly { selected = last; agendaDayExpanded = true; journalScroll.scrollTo(id: last, anchor: .top) }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { editingDay = nil }
            finishingEdit = false
            next?()
            try? await Task.sleep(for: .milliseconds(700))
            await organizeStoredPage(day)
        }
    }

    /// The day's page, edited in place inside its 逐日 card. It is at least as tall as the window, so while
    /// writing the day reads as a full screen; scrolling still reaches the other days. Esc, 完成, or a click
    /// outside the page organizes it and returns to the overview.
    #if os(iOS)
    /// The writing view (iPhone): every day listed, each in its own box with its items and its writing. The day
    /// being written has the live text; tapping another day's box moves there (the day left is organized).
    private var writingView: some View {
        let start = writingFrom ?? editingDay ?? clock.today
        // One day at a time (opened from the calendar; 完成 goes back to it).
        let days = [editingDay ?? start]
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(days, id: \.self) { day in
                        phoneWritingBox(day)
                    }
                }
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 120)
            }
            .scrollDismissesKeyboard(.interactively)
            // The floating 说/完成 bar sits above the keyboard; keep the line being written clear of it.
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 66) }
            // Text never slides under the status bar.
            .clipped()
            .opacity(writingPlaced ? 1 : 0)
            .task(id: start) {
                writingPlaced = false
                for delay in [0, 60, 160] {
                    if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) } else { await Task.yield() }
                    proxy.scrollTo(start, anchor: .top)
                }
                withAnimation(.smooth(duration: 0.15)) { writingPlaced = true }
            }
        }
        .background(theme.paper)
    }

    private func phoneWritingBox(_ day: PlanDate) -> some View {
        let isToday = day == clock.today
        let writing = editingDay == day
        let relative = [0: String(localized: " · 今天"), 1: String(localized: " · 明天"), -1: String(localized: " · 昨天")][dayDelta(clock.today, day) ?? 99] ?? ""
        let rows = phoneRows(day)
        let written = writing ? "" : PageController.decode(pageData(day)).trimmed
        // The date and today's progress are in the navigation bar above.
        _ = (isToday, relative)
        return VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows) { entry in
                    DesktopJournalTask(entry: entry, calendar: clock.calendar, theme: theme, motion: nil)
                }
                if writing {
                    PhonePageEditor(controller: pageController, theme: theme,
                                    placeholder: rows.isEmpty ? String(localized: "随便写…一行一件事，写完点完成，自动整理成待办") : String(localized: "继续写…"))
                        .frame(minHeight: 120, alignment: .top)
                } else {
                    Text(written.isEmpty ? (rows.isEmpty ? "写点什么…" : "继续写…") : written)
                        .font(.system(size: 16))
                        .foregroundStyle(written.isEmpty ? theme.quiet.opacity(0.6) : theme.ink)
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                        .padding(.vertical, 6).padding(.horizontal, 5)
                        .contentShape(Rectangle())
                        .onTapGesture { switchPhoneDay(to: day) }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(writing ? theme.field : theme.surface.opacity(theme.dark ? 0.6 : 0.55))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(writing ? theme.accent.opacity(0.45) : theme.line, lineWidth: writing ? 1.2 : 1)
                    }
            }
            .animation(.smooth(duration: 0.18), value: writing)
        }
        .id(day)
    }

    /// The day's items as rows (same as the overview).
    private func phoneRows(_ day: PlanDate) -> [TimelineEntry] {
        let linkedTasks = Dictionary(tasks.lazy.filter(\.calendarLinked).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let entries = timelineEntries(events: journalEvents.days[day] ?? [],
                                      local: localItems.filter { $0.schedule?.dayOnly == day },
                                      reminders: system.reminders.filter { $0.schedule?.dayOnly == day },
                                      linkedTasks: linkedTasks, availableLinkedIDs: journalEvents.linked, includeUntimed: true)
        return nested(merged(entries, routinesOn: day))
    }

    /// Moves the cursor to another day: the day left is saved and organized in the background.
    private func switchPhoneDay(to day: PlanDate) {
        guard let current = editingDay, current != day else { return }
        storePhonePage(current)
        instantly {
            editingDay = day
            selected = day
        }
        pageController.load(pageData(day))
        Task { await organizeStoredPage(current) }
    }

    /// While writing on iPhone: 说 and 完成 float just above the keyboard, always in reach.
    private var phonePageBar: some View {
        HStack(spacing: 10) {
            Button(action: toggleDocumentVoice) {
                HStack(spacing: 6) {
                    ASMOIcon(mark: pageController.recording ? .stop : .mic, size: 14)
                    Text(pageController.recording ? "结束" : "说").font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(pageController.recording ? theme.onAccent : theme.accent)
                .padding(.horizontal, 14).frame(height: 38)
                .background(pageController.recording ? theme.accent : theme.wash.opacity(0.7),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pageMic")
            if documentOrganizing || finishingEdit {
                ProgressView().controlSize(.small).tint(theme.accent)
            }
            Spacer(minLength: 0)
            Button { finishEditing() } label: {
                Text(finishingEdit ? "整理中…" : "完成")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.onAccent)
                    .padding(.horizontal, 18).frame(height: 38)
                    .background(theme.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pageDone")
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.paper)
                .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.line) }
                .shadow(color: .black.opacity(theme.dark ? 0.4 : 0.12), radius: 14, y: 4)
        }
    }

    /// Stores what was written as the day's page and marks the new lines for organizing.
    private func storePhonePage(_ day: PlanDate) {
        let text = pageController.text
        // Only lines written since the page was last stored are new; older ones were organized already.
        let before = Set(PageController.decode(pageData(day)).components(separatedBy: "\n").map(\.trimmed))
        // Nothing changed: the page stays exactly as stored (formatting written on the Mac included).
        let stored = pageController.toStore()
        guard stored.changed else { return }
        savePage(stored.data, day: day)
        let lines = text.components(separatedBy: "\n").map(\.trimmed).filter { !$0.isEmpty && !before.contains($0) }
        if !lines.isEmpty, let page = dayPage(day.key) {
            page.pendingRaw = lines.joined(separator: "\n")
            persist()
        }
    }
    #else
    #if DEBUG
    /// Test driver for the page being written (Debug only): see "ed:" in the nav hooks.
    private func debugEdit(_ command: String) {
        let out = AppPaths.caches.appendingPathComponent("asmo-ed.txt")
        guard let view = pageController.textView, let storage = view.textStorage else {
            try? "no page".write(to: out, atomically: true, encoding: .utf8); return
        }
        let string = storage.string as NSString
        let (verb, rest) = command.firstIndex(of: ":").map { (String(command[..<$0]), String(command[command.index(after: $0)...])) } ?? (command, "")
        func find(_ text: String) -> NSRange? {
            let range = string.range(of: text)
            return range.location == NSNotFound ? nil : range
        }
        switch verb {
        case "sel": if let range = find(rest) { view.setSelectedRange(range) }
        case "caret": if let range = find(rest) { view.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0)) }
        case "line": if let range = find(rest) { view.setSelectedRange(string.paragraphRange(for: range)) }
        case "end": view.setSelectedRange(NSRange(location: storage.length, length: 0))
        case "ins": view.insertText(rest, replacementRange: view.selectedRange())
        case "attrs":
            // "attrs:TEXT": the raw attributes where TEXT starts, written to asmo-ed.txt.
            // "attrs:TEXT|N": N characters after where TEXT starts.
            let parts = rest.components(separatedBy: "|")
            if let range = find(parts[0]) {
                let at = min(storage.length - 1, range.location + (parts.count > 1 ? Int(parts[1]) ?? 0 : 0))
                let attributes = storage.attributes(at: at, effectiveRange: nil)
                try? attributes.map { "\($0.key.rawValue) = \($0.value)" }.sorted().joined(separator: "\n")
                    .write(to: out, atomically: true, encoding: .utf8)
            }
            return
        // "type:TEXT": one character at a time, as keys would (so as-you-type rules run); "⏎" is Return.
        case "type":
            for character in rest {
                if character == "⏎" { view.doCommand(by: #selector(NSResponder.insertNewline(_:))); continue }
                view.insertText(String(character), replacementRange: view.selectedRange())
            }
        case "key": view.doCommand(by: Selector(rest))
        case "scrolltest":
            // "scrolltest:N": scroll N steps of 60 pt, drawing each, and write the slowest and average frame.
            guard let clip = view.enclosingScrollView?.contentView else { return }
            var times: [Double] = []
            let steps = Int(rest) ?? 200
            for step in 0..<steps {
                let started = Date.now
                let y = step < steps / 2 ? clip.bounds.minY + 60 : max(0, clip.bounds.minY - 60)
                clip.scroll(to: NSPoint(x: 0, y: y))
                view.enclosingScrollView?.reflectScrolledClipView(clip)
                view.window?.displayIfNeeded()
                times.append(Date.now.timeIntervalSince(started) * 1000)
            }
            let report = String(format: "frames %d avg %.2f ms max %.2f ms >16ms %d", times.count,
                                times.reduce(0, +) / Double(max(1, times.count)), times.max() ?? 0, times.filter { $0 > 16 }.count)
            try? report.write(to: out, atomically: true, encoding: .utf8)
            return
        case "month":
            if let day = JournalDays.date(forKey: rest + "-01") { jump(toMonth: day) }
        case "repeat":
            // "repeat:每月15号": as if picked in the 重复 menu; "repeat:" lists the menu.
            guard let coordinator = (view as? DocTextView)?.coordinator else { return }
            if rest.isEmpty {
                let choices = coordinator.repeatChoices()?.map { "\($0.label) → \($0.tag)" }.joined(separator: "\n") ?? "no menu here"
                try? choices.write(to: out, atomically: true, encoding: .utf8)
                return
            }
            coordinator.applyRepeat(rest)
        case "hitmap":
            // Which view takes a click at points down the middle of the document (anything not the text covers it).
            guard let window = view.window, let root = window.contentView, let scroll = view.enclosingScrollView else { return }
            var rows: [String] = []
            let fine = rest == "fine"
            for fraction in stride(from: fine ? 0.80 : 0.02, through: 0.999, by: fine ? 0.005 : 0.04) {
                for xf in fine ? [0.5] : [0.3, 0.5, 0.7] {
                    let local = NSPoint(x: scroll.bounds.width * xf, y: scroll.bounds.height * fraction)
                    let point = scroll.convert(local, to: nil)
                    let hit = root.hitTest(root.superview?.convert(point, from: nil) ?? point)
                    let name = hit.map { String(describing: type(of: $0)).prefix(40) } ?? "nil"
                    if hit !== view { rows.append(String(format: "y %.3f (window y %.0f) x %.1f → %@", fraction, point.y, xf, String(name))) }
                }
            }
            rows.insert("scroll in window \(scroll.convert(scroll.bounds, to: nil)) window content \(root.frame)", at: 0)
            var chain: NSView? = scroll.superview
            while let node = chain, node !== root {
                rows.insert("  host \(String(describing: type(of: node)).prefix(50)) \(node.convert(node.bounds, to: nil)) flipped \(node.isFlipped)", at: 1)
                chain = node.superview
            }
            try? (rows.count == 1 ? rows[0] + "\nall text" : rows.joined(separator: "\n")).write(to: out, atomically: true, encoding: .utf8)
            return
        case "click", "scrollto":
            // "click:TEXT": a click in the middle of TEXT where it's drawn, sent to this window only; writes where the
            // cursor landed. "scrollto:TEXT": scroll so TEXT is at the top of the window.
            // "click:TEXT|N": the one character N away from where TEXT starts (N = -3: an item's bullet).
            let parts = rest.components(separatedBy: "|")
            let offset = parts.count > 1 ? Int(parts[1]) : nil
            guard var range = find(parts[0]), let layout = view.layoutManager, let container = view.textContainer,
                  let window = view.window, let clip = view.enclosingScrollView?.contentView else {
                try? "not found".write(to: out, atomically: true, encoding: .utf8); return
            }
            if let offset { range = NSRange(location: max(0, range.location + offset), length: 1) }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += view.textContainerOrigin.x
            rect.origin.y += view.textContainerOrigin.y
            if verb == "scrollto" {
                clip.scroll(to: NSPoint(x: 0, y: max(0, rect.minY - 30)))
                view.enclosingScrollView?.reflectScrolledClipView(clip)
                return
            }
            let point = view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            func mouse(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            // The text view's click waits for the button to come up: queue that first.
            if let up = mouse(.leftMouseUp) { window.postEvent(up, atStart: false) }
            // Straight to the view under the point (a window in the background takes its first click as "come
            // forward" only), the way the window would route it.
            if let down = mouse(.leftMouseDown), let target = window.contentView?.hitTest(window.contentView?.superview?.convert(point, from: nil) ?? point) {
                if target !== view {
                    try? "covered by \(type(of: target))".write(to: out, atomically: true, encoding: .utf8); return
                }
                target.mouseDown(with: down)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let text = view.textStorage?.string ?? ""
                let all = text as NSString
                let at = view.selectedRange().location
                let line = all.paragraphRange(for: NSRange(location: min(at, max(0, all.length - 1)), length: 0))
                var probe = line.location
                var heading = ""
                while probe >= 0 {
                    let paragraph = all.paragraphRange(for: NSRange(location: probe, length: 0))
                    if view.textStorage?.attribute(.asmoDay, at: paragraph.location, effectiveRange: nil) != nil { heading = all.substring(with: paragraph); break }
                    if paragraph.location == 0 { break }
                    probe = paragraph.location - 1
                }
                try? "wanted \(rest) at y \(Int(rect.midY - clip.bounds.minY)) of \(Int(clip.bounds.height)) → line [\(all.substring(with: line).trimmed)] in [\(heading.trimmed)]"
                    .write(to: out, atomically: true, encoding: .utf8)
            }
            return
        case "barclick":
            // "barclick:N": a click on the Nth button (from 0) of the bar next to the selection, sent to this
            // window only (the real mouse isn't touched).
            guard let bar = view.subviews.first(where: { String(describing: type(of: $0)).contains("NSHostingView") }), !bar.isHidden,
                  let window = view.window, let index = Int(rest) else {
                try? "no bar".write(to: out, atomically: true, encoding: .utf8); return
            }
            let point = bar.convert(NSPoint(x: 12 + 6 + 15 + CGFloat(index) * 31, y: bar.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
            }
        case "paste", "pastefile", "pastehtml":
            // A private pasteboard (never the user's clipboard): "paste:TEXT" (\n for new lines),
            // "pastefile:/path" (as from Finder), "pastehtml:/path/page.html" (as from a browser).
            let board = NSPasteboard(name: NSPasteboard.Name("asmo-test-paste"))
            board.clearContents()
            switch verb {
            case "pastefile": board.writeObjects([URL(fileURLWithPath: rest) as NSURL])
            case "pastehtml":
                if let data = try? Data(contentsOf: URL(fileURLWithPath: rest)) {
                    board.declareTypes([.html, .string], owner: nil)
                    board.setData(data, forType: .html)
                    board.setString(String(decoding: data, as: UTF8.self), forType: .string)
                }
            default: board.setString(rest.replacingOccurrences(of: "\\n", with: "\n"), forType: .string)
            }
            if let doc = view as? DocTextView, let body = doc.coordinator?.writingAttributes,
               !DocPaste.insert(from: board, into: doc, body: body) {
                view.insertText(board.string(forType: .string) ?? "", replacementRange: view.selectedRange())
            }
        case "rep":
            // "rep:12:deleteBackward:": a held key (about 30 ms per repeat).
            let parts = rest.split(separator: ":", maxSplits: 1).map(String.init)
            let count = Int(parts.first ?? "") ?? 1
            Task { @MainActor in
                for _ in 0..<count {
                    view.doCommand(by: Selector(parts.count > 1 ? parts[1] : "deleteBackward:"))
                    try? await Task.sleep(for: .milliseconds(30))
                }
            }
        case "span":
            // "span:from|to": select from the start of one text to the end of another (across lines).
            let ends = rest.components(separatedBy: "|")
            if ends.count == 2, let a = find(ends[0]), let b = find(ends[1]), NSMaxRange(b) >= a.location {
                view.setSelectedRange(NSRange(location: a.location, length: NSMaxRange(b) - a.location))
            }
        case "fmt":
            switch rest {
            case "bold": pageController.toggleBold()
            case "italic": pageController.toggleItalic()
            case "underline": pageController.toggleUnderline()
            case "strike": pageController.toggleStrike()
            case "highlight": pageController.highlight()
            case "heading": pageController.toggleHeading()
            case "bullet": pageController.toggleLinePrefix("• ")
            case "check": pageController.toggleLinePrefix("☐ ")
            case "link": pageController.link()
            case "red": pageController.color(.systemRed)
            case "eraser": pageController.color(nil)
            case "image": if let image = NSImage(named: NSImage.applicationIconName) { view.insertImage(image) }
            case "repeat": pageController.makeRepeating()
            default: break
            }
        case "dump":
            var lines: [String] = []
            var location = 0
            while location < string.length {
                let range = string.paragraphRange(for: NSRange(location: location, length: 0))
                location = NSMaxRange(range)
                var line = ""
                storage.enumerateAttributes(in: range) { attributes, sub, _ in
                    var piece = string.substring(with: sub).replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\t", with: "→")
                        .replacingOccurrences(of: "\u{200B}", with: "")
                    if piece.isEmpty { return }
                    if attributes[.attachment] != nil { piece = "[img]" }
                    let font = attributes[.font] as? NSFont
                    let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
                    if traits.contains(.boldFontMask) || (font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false) { piece = "**\(piece)**" }
                    if traits.contains(.italicFontMask) || ((attributes[.obliqueness] as? CGFloat) ?? 0) > 0.05 { piece = "_\(piece)_" }
                    if let color = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB), color.redComponent > 0.8,
                       color.greenComponent < 0.45 { piece = "{red}\(piece)" }
                    if attributes[.underlineStyle] != nil { piece = "<u>\(piece)</u>" }
                    if attributes[.strikethroughStyle] != nil { piece = "~~\(piece)~~" }
                    if attributes[.backgroundColor] != nil { piece = "==\(piece)==" }
                    if let link = attributes[.link] { piece = "[\(piece)](\(link))" }
                    if (font?.pointSize ?? 15) > 17 { piece = "#\(piece)" }
                    line += piece
                }
                let item = storage.attribute(NSAttributedString.Key("asmo.line"), at: range.location, effectiveRange: nil) != nil
                    || (range.length > 1 && storage.attribute(NSAttributedString.Key("asmo.line"), at: range.location + range.length - 2, effectiveRange: nil) != nil)
                if !line.isEmpty { lines.append((item ? "I| " : "T| ") + line) }
            }
            let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let day = openPageDay
            let items = tasks.filter { $0.schedule?.dayOnly == day }.sorted { $0.createdAt < $1.createdAt }.map { task in
                "S| \(task.completed ? "[x]" : "[ ]") \(task.title)\(task.titleStyle.map { " {\($0)}" } ?? "")\(task.parentID.flatMap { byID[$0]?.title }.map { " ↳ " + $0 } ?? "")"
            }
            let repeats = routines.map { routine in
                "R| \(routine.title) \(routine.ruleLabel) \(routine.startMinute.map { String(format: "%02d:%02d", $0 / 60, $0 % 60) } ?? "-")\(routine.endDay.map { " ends " + $0 } ?? "")"
            }
            try? (lines + ["--- stored"] + items + repeats).joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        default: break
        }
    }
    #endif
    #endif

    /// Content switches without animation: it should feel immediate, not slide or fade.
    private func instantly(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    /// Leaves the page at once; anything written but not yet organized is organized in the background.
    /// The page's ‹ › and ⌘[ ⌘]: the day before or after (the one left is organized).
    private func stepDocument(_ step: Int) {
        guard let current = documentDay, let date = current.date(in: clock.calendar),
              let next = clock.calendar.date(byAdding: .day, value: step, to: date) else { return }
        closeDocument(to: PlanDate.from(next, calendar: clock.calendar))
    }

    #if os(macOS)
    /// The day being written, as a page over the calendar.
    /// The days on the paper: today and the two weeks ahead, and every other day that has anything on it — items,
    /// a page, the imported history, an old day note — however far back or ahead, plus the month plans
    /// ("2027 年 1 月") and the important dates of the coming month. The paper shows what the calendar shows.
    private var paperDays: [PlanDate] {
        #if DEBUG
        let started = Date.now
        defer { PerfLog.note("paperDays", since: started) }
        #endif
        // Read through lastKnownToday so midnight passing redraws the document.
        let today = max(lastKnownToday, clock.today)
        // Every day ahead is there to write on, empty or not: six weeks to begin with, further as the reader
        // scrolls to the end or jumps to a later month.
        // Behind today too: every day back to the cutoff, written on or not (a day skipped for being empty
        // reads as a gap in the dates).
        var days = Set((-paperHistory...paperAheadDays).compactMap { clock.offset(days: $0) })
        for task in tasks where !task.calendarLinked {
            if let day = task.schedule?.dayOnly { days.insert(day) }
        }
        days.formUnion(pageDays())
        for note in notes where !note.body.trimmed.isEmpty {
            if let day = JournalDays.date(forKey: note.dayKey) { days.insert(day) }
        }
        // History days with something written (an imported "11.3:" with nothing after it is just a date).
        for (day, entries) in archivedDays where entries.contains(where: { !$0.entry.body.trimmed.isEmpty }) { days.insert(day) }
        days.insert(today)
        // The past is shown back to a point (a long page is slow to edit); 更早的记录 moves the point back.
        let cutoff = clock.offset(days: -paperHistory) ?? today
        let shown = days.filter { $0.day == nil || $0 >= cutoff }
        var result = Set(shown)
        if let paperFocus {
            // A day jumped to, with the written days around it and the rest of its month (the history there reads
            // in context, and a month chosen in the sidebar is there whole).
            result.insert(paperFocus)
            let focusDate = paperFocus.date(in: clock.calendar) ?? .now
            let monthEnd = clock.calendar.dateInterval(of: .month, for: focusDate)?.end ?? focusDate
            // The month itself, every day of it.
            if let month = clock.calendar.dateInterval(of: .month, for: focusDate) {
                var date = month.start
                while date < month.end {
                    result.insert(PlanDate.from(date, calendar: clock.calendar))
                    guard let next = clock.calendar.date(byAdding: .day, value: 1, to: date) else { break }
                    date = next
                }
            }
            if let low = clock.calendar.date(byAdding: .day, value: -10, to: focusDate),
               let high = clock.calendar.date(byAdding: .day, value: 10, to: max(focusDate, monthEnd.addingTimeInterval(-1))) {
                let lo = PlanDate.from(low, calendar: clock.calendar), hi = PlanDate.from(high, calendar: clock.calendar)
                result.formUnion(days.filter { $0.day != nil && $0 >= lo && $0 <= hi })
            }
        }
        // Every month with something written, for the contents sidebar.
        var months: [Int: PlanDate] = [:]
        for day in days where day.day != nil {
            let key = day.year * 100 + day.month
            if let first = months[key], first <= day { continue }
            months[key] = day
        }
        // The next two years are there to jump to, written in or not.
        for offset in 0...24 {
            let total = today.year * 12 + today.month - 1 + offset
            let key = (total / 12) * 100 + total % 12 + 1
            if months[key] == nil { months[key] = PlanDate(year: total / 12, month: total % 12 + 1, day: 1) }
        }
        let list = months.keys.sorted().compactMap { months[$0] }
        if list != paperContentsModel.months {
            let model = paperContentsModel
            DispatchQueue.main.async { model.months = list }
        }
        return result.sorted()
    }

    /// Past days on the paper (earlier months are reached from the contents sidebar).
    private let paperHistory = 60
    /// Days after today on the paper: six weeks, plus what scrolling to the end or jumping ahead has added.
    @State private var paperAhead = 0
    private static let paperAheadBase = 45
    private static let paperAheadLimit = 731
    private var paperAheadDays: Int { min(Self.paperAheadLimit, Self.paperAheadBase + paperAhead) }

    /// The reader reached the end of the document: another month of days is added below.
    private func extendPaper() {
        guard paperAheadDays < Self.paperAheadLimit else { return }
        paperAhead += 31
    }
    /// The sidebar's months and the month on screen: observed by the sidebar only, so scrolling past a month
    /// never redraws the planner.
    @State private var paperContentsModel = PaperContentsModel()
    /// Every day that has a page, read again only after a save (`pagesVersion`).
    private final class PageDays { var version = -1; var days = Set<PlanDate>() }
    @State private var pageDaysBox = PageDays()

    private func pageDays() -> Set<PlanDate> {
        if pageDaysBox.version != pagesVersion {
            var descriptor = FetchDescriptor<DayPage>()
            descriptor.propertiesToFetch = [\.dayKey]
            let pages = (try? context.fetch(descriptor)) ?? []
            pageDaysBox.days = Set(pages.compactMap { JournalDays.date(forKey: $0.dayKey) })
            pageDaysBox.version = pagesVersion
        }
        return pageDaysBox.days
    }

    /// The page of one day (including one made but not saved yet).
    private func dayPage(_ key: String) -> DayPage? {
        var descriptor = FetchDescriptor<DayPage>(predicate: #Predicate { $0.dayKey == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
    @AppStorage("paperContents") private var paperContents = true

    /// The logo and 文档 | 日历: the same place in both views.
    private var homeLeading: some View {
        HStack(spacing: 10) {
            Image("BrandMark").resizable().interpolation(.high).scaledToFit().frame(width: 26, height: 24)
                .accessibilityHidden(true)
            if !paperContents {
                Button { paperContents = true } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.quiet)
                        .frame(width: 30, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(DesktopButtonStyle(theme: theme))
                .help("显示目录")
            }
            // Back to this month (to today in it), wherever the document is: ⇧⌘T too.
            Button { jump(to: clock.today) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .semibold))
                    Text("本月").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(theme.quiet)
                .padding(.horizontal, 10).frame(height: 28).contentShape(Rectangle())
            }
            .buttonStyle(DesktopButtonStyle(theme: theme))
            .help("回到这个月（今天） ⇧⌘T")
        }
    }

    private func jump(to day: PlanDate) {
        let today = clock.today
        paperFocus = day == today ? nil : day.dayOnly
        if day == today {
            paperAhead = 0
        } else if let delta = dayDelta(today, day), delta > 0 {
            // A later day: the document runs on to the end of its month (and a little past), with no gap.
            paperAhead = max(paperAhead, min(Self.paperAheadLimit, delta + 41) - Self.paperAheadBase)
        }
        paperJump += 1
    }

    /// Counts jumps: the document scrolls to its anchor on each.
    @State private var paperJump = 0

    /// Home on the Mac: one continuous document, a heading per day, today in front. Write in it like in any doc;
    /// lines become items by the date and time rules, agents write into the same pages, and it copies out as text
    /// or Markdown.
    private var paperHome: some View {
        VStack(spacing: 0) {
            ZStack {
                PageToolbar(controller: pageController, theme: theme).fixedSize()
                HStack(spacing: 8) {
                    homeLeading
                    Spacer()
                    Button {
                        guard let text = pageController.textView?.textStorage else { return }
                        let markdown = PageMarkdown.markdown(text).replacingOccurrences(of: "-  ", with: "- ")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(markdown, forType: .string)
                        announce(String(localized: "整份文档已复制为 Markdown"))
                    } label: {
                        Text("复制 Markdown").font(.system(size: 12, weight: .medium)).foregroundStyle(theme.quiet)
                            .padding(.horizontal, 10).frame(height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(DesktopButtonStyle(theme: theme))
                    .help("把整份文档复制成 Markdown，可以直接贴给 AI")
                    Button { sheet = .settings } label: {
                        Image(systemName: "gearshape").font(.system(size: 14, weight: .medium)).foregroundStyle(theme.quiet)
                            .frame(width: 32, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(DesktopButtonStyle(theme: theme))
                    .accessibilityLabel("设置")
                }
            }
            // The same height and padding as the calendar's row, so nothing jumps when switching.
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 6)
            ZStack(alignment: .top) {
                Rectangle().fill(theme.line.opacity(0.6)).frame(height: 1)
                if documentOrganizing { ProgressView().progressViewStyle(.linear).tint(theme.accent).frame(height: 2) }
            }
            .frame(height: 2)
            let days = documentDays(paperDays)
            HStack(spacing: 0) {
                if paperContents {
                    paperSidebar
                    Rectangle().fill(theme.line.opacity(0.6)).frame(width: 1)
                }
                DayDocumentView(days: days, anchor: paperFocus ?? clock.today, jump: paperJump, theme: theme,
                                actions: documentActions, controller: pageController, organizeRequest: organizeTick,
                                rebuildRequest: pageRebuild, autofocus: true, minHeight: 600, organizeWhenIdle: false,
                                scrolls: true, visibleDay: { [paperContentsModel] day in
                                    let month = PlanDate(year: day.year, month: day.month)
                                    if paperContentsModel.visible != month { paperContentsModel.visible = month }
                                }, reachedEnd: { extendPaper() }, endsNear: clock.offset(days: paperAheadDays - 3))
            }
        }
    }

    private var paperSidebar: some View {
        PaperContentsSidebar(model: paperContentsModel, theme: theme, thisYear: clock.today.year,
                             today: PlanDate(year: clock.today.year, month: clock.today.month), reduceMotion: reduceMotion,
                             pick: { jump(toMonth: $0) }, close: { paperContents = false })
    }

    /// A month from the contents: its first written day at the top of the window.
    private func jump(toMonth first: PlanDate) {
        let today = clock.today
        if first.year == today.year && first.month == today.month { jump(to: today); return }
        jump(to: first)
    }

    private func dayEditor(_ day: PlanDate) -> some View {
        #if DEBUG
        let started = Date.now
        defer { PerfLog.note("dayEditor", since: started) }
        #endif
        var docDay = documentDay(day)
        docDay.showsHeading = false
        let relative = [0: String(localized: " · 今天"), 1: String(localized: " · 明天"), -1: String(localized: " · 昨天")][dayDelta(clock.today, day) ?? 99] ?? ""
        _ = relative
        return DayEditorSheet(organizing: documentOrganizing, theme: theme, close: { closeDocument() }) {
            PageToolbar(controller: pageController, theme: theme)
        } content: {
            DayDocumentView(days: [docDay], anchor: day, theme: theme, actions: documentActions,
                            controller: pageController, organizeRequest: organizeTick, rebuildRequest: pageRebuild,
                            autofocus: true, minHeight: 420)
                .id(day)
        }
        .overlay(alignment: .bottom) {
            // What the microphone and the organizer are doing, and the notice with 撤销, stay visible over the page.
            VStack(spacing: 10) {
                if let notice {
                    PlannerNoticeBar(notice: notice, theme: theme) {
                        if self.notice?.id == notice.id { withAnimation(.smooth(duration: 0.2)) { self.notice = nil } }
                    }
                    .id(notice.id)
                }
                if let phase = voicePhase {
                    VoiceStatusPill(phase: phase, voice: voice, theme: theme, stop: voiceStop(phase))
                }
            }
            .padding(.bottom, 28)
        }
    }
    #endif

    private func closeDocument(then next: (() -> Void)? = nil, to other: PlanDate? = nil) {
        guard let current = documentDay else { return }
        #if os(macOS)
        pageController.textView?.window?.makeFirstResponder(nil)
        #else
        pageController.resignFocus()
        #endif
        instantly {
            if let other {
                documentDay = other
            } else {
                documentDay = nil
                if Self.calendarHome {
                    selected = current
                } else if next == nil {
                    page = .day
                    selected = current
                    agendaAnchor = current
                    agendaDayExpanded = true
                }
            }
        }
        next?()
        // Give the page a moment to save its last words, then organize them from storage.
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            await organizeStoredPage(current)
        }
    }

    private func moveDesktopWorkspace(to next: PlannerPage) {
        guard page != next else { return }
        monthDetail = nil
        page = next
    }

    /// The day title (76) and the page's padding (4 + 21 + 1): what fills the window besides the page itself.
    static let editorChrome: CGFloat = 102

    /// The calendar is the only view: on Mac a day is written in a centered popup, on iPhone in a full page.
    static let calendarHome = true

    #if os(iOS)
    static let compactLayout = true
    #else
    static let compactLayout = false
    #endif

    private var pagePadding: CGFloat {
        #if os(macOS)
        38
        #else
        17
        #endif
    }

    private var navigation: some View {
        HStack(spacing: 17) {
            Button(action: showToday) {
                Image("BrandMark").resizable().scaledToFit()
                    .frame(width: 32, height: 25).frame(minWidth: 44, minHeight: 45)
            }
            .accessibilityLabel("回到今天")
            navItem(String(localized: "当天"), active: page == .day) { page = .day }
            navItem(String(localized: "月计划"), active: page == .month) { page = .month }
            navItem(String(localized: "归档"), active: false) { sheet = .archive }
            Spacer(minLength: 0)
            Menu {
                Button("重要日期", systemImage: "sparkle") { sheet = .important }
                Button("未安排", systemImage: "tray") { page = .inbox }
                Button("设置", systemImage: "gearshape") { sheet = .settings }
            } label: {
                ASMOIcon(mark: .more, size: 18).frame(width: 37, height: 44)
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("更多")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, pagePadding)
        .frame(maxWidth: 1130)
        .frame(maxWidth: .infinity)
        .background(theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line).frame(height: 1) }
    }

    private func navItem(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title.localized).font(.subheadline.weight(active ? .semibold : .medium))
                .foregroundStyle(active ? theme.ink : theme.quiet)
                .frame(minHeight: 47)
                .overlay(alignment: .bottom) {
                    if active { Capsule().fill(theme.accent).frame(height: 2) }
                }
        }
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private func header(events: [SystemEvent]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if page == .day {
                    Button { jumpDate = selected.date(in: clock.calendar) ?? .now; sheet = .jump } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(heading).font(.system(.title, design: .default, weight: .bold))
                                .lineLimit(1).minimumScaleFactor(0.68)
                            Text(weekday).font(.subheadline.weight(.medium)).foregroundStyle(theme.quiet)
                                .fixedSize()
                            ASMOIcon(mark: .down, size: 13).foregroundStyle(theme.quiet)
                        }
                    }
                    .accessibilityLabel("\(heading)，\(weekday)，跳转到日期")
                    .accessibilityIdentifier("plannerDate")
                    .accessibilityAddTraits(.isHeader)
                } else {
                    Text(heading).font(.title.bold()).accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 0)
                if page != .inbox {
                    dateArrow(.left, direction: -1, label: page == .day ? String(localized: "前一天") : String(localized: "上个月"))
                    dateArrow(.right, direction: 1, label: page == .day ? String(localized: "后一天") : String(localized: "下个月"))
                }
            }
            .buttonStyle(.plain)
            if page == .day { importantHeader(events: events) }
            Rectangle().fill(theme.line).frame(height: 1).padding(.top, 5)
        }
    }

    private func dateArrow(_ icon: ASMOIcon.Mark, direction: Int, label: String) -> some View {
        Button { shift(direction) } label: {
            ASMOIcon(mark: icon, size: 15).frame(width: 32, height: 32)
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line) }
                .frame(minWidth: 38, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label.localized)
    }

    private var heading: String {
        switch page {
        case .day:
            let year = selected.year == clock.today.year ? "" : String(localized: "\(selected.year) 年 ")
            return String(localized: "\(year)\(selected.month) 月 \(selected.day ?? 1) 日")
        case .month:
            #if os(macOS)
            return String(localized: "\(selected.year) 年 \(selected.month) 月")
            #else
            return String(localized: "\(selected.month)月计划")
            #endif
        case .inbox: return String(localized: "未安排")
        }
    }

    private var weekday: String {
        guard let date = selected.date(in: clock.calendar) else { return "" }
        let index = clock.calendar.component(.weekday, from: date) - 1
        return AppLanguage.weekday(index + 1)
    }

    @ViewBuilder
    private func importantHeader(events: [SystemEvent], on day: PlanDate? = nil,
                                 localDates: [ImportantDateRecord]? = nil) -> some View {
        let local = localDates ?? importantDates.filter { $0.rule.matches(day ?? selected, calendar: clock.calendar) }
        let combined = local.map { ($0.title, $0.kind) } + events.compactMap { event in
            event.importantKind.map { (event.title, $0) }
        }
        let unique = combined.enumerated().filter { index, item in
            !combined.prefix(index).contains { $0.0 == item.0 }
        }
        if !unique.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(unique), id: \.offset) { entry in
                    if let record = local.first(where: { $0.title == entry.element.0 }) {
                        occasionLine(record, on: day ?? selected)
                    } else {
                        #if os(macOS)
                        HStack(spacing: 7) {
                            ASMOIcon(mark: .spark, size: 15)
                            Text(entry.element.0)
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.accent)
                        #else
                        Label(entry.element.0, systemImage: entry.element.1.icon)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(theme.accent)
                        #endif
                    }
                }
            }
            .accessibilityIdentifier("importantDateHeader")
        }
    }

    private func occasionLine(_ record: ImportantDateRecord, on day: PlanDate) -> some View {
        HStack(spacing: 8) {
            Button {
                editOccasion(record)
            } label: {
                HStack(spacing: 5) {
                    ASMOIcon(mark: .spark, size: 14)
                    Text(record.title).font(.subheadline.weight(.semibold))
                    if let zone = record.rule.timeZoneID {
                        Text(ImportantDateTimeZone.label(for: zone)).font(.caption)
                            .foregroundStyle(theme.quiet)
                    }
                }
                .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("occasion-\(record.id.uuidString)")
            .help("编辑日期与时区")
            if canPlanGreeting(for: record, on: day, clock: clock) {
                Button("祝福提醒…") {
                    planGreeting(for: record, on: day)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(theme.accent)
                .accessibilityLabel("为\(record.title)设置祝福提醒")
                .accessibilityIdentifier("greeting-\(record.id.uuidString)")
                .help("按指定时区设置祝福提醒")
            }
        }
    }

    private func editOccasion(_ record: ImportantDateRecord) {
        initialImportantDate = record
        sheet = .important
    }

    private func canPlanGreeting(for record: ImportantDateRecord, on day: PlanDate, clock: CaptureClock) -> Bool {
        guard record.kind == .birthday,
              let lastMoment = record.rule.time(on: day, hour: 23, minute: 59, localCalendar: clock.calendar)
        else { return false }
        return lastMoment > clock.now
    }

    private func planGreeting(for record: ImportantDateRecord, on day: PlanDate) {
        greetingDraft = BirthdayGreetingDraft(title: record.title, day: day, rule: record.rule)
        sheet = .birthdayGreeting
    }

    private func previewGreeting(_ draft: BirthdayGreetingDraft, time: Date, zone: String) {
        let title = "给\(draft.title.hasSuffix("生日") ? String(draft.title.dropLast(2)) : draft.title)发祝福"
        let schedule = PlanDate.from(time, calendar: clock.calendar, includeTime: true)
        let note = String(localized: "生日：\(draft.day.label) · \(ImportantDateTimeZone.label(for: draft.rule.timeZoneID))\n祝福时间按\(zone)安排。")
        editor = EditorInput(id: UUID(), title: title, note: note, schedule: schedule, action: .reminder,
                             alert: time, reviewing: true)
        greetingDraft = nil
        sheet = .editor
    }
    #if !os(macOS)
    private func dayContent(events: [SystemEvent]) -> some View {
        let items = timelineEntries(events: events, local: localItems.filter { $0.schedule?.dayOnly == selected },
                                    reminders: system.reminders.filter { $0.schedule?.dayOnly == selected })
        return PlannerColumns {
            timelineSection(items).frame(maxWidth: .infinity, alignment: .leading)
            anytimeSection.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func timelineSection(_ items: [TimelineEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle(String(localized: "时间线"))
                Spacer()
                if !items.isEmpty { Text("\(items.count) 项已排时间").font(.caption).foregroundStyle(theme.quiet) }
            }
            if items.isEmpty {
                Text("当天没有排时间的事项。").font(.subheadline).foregroundStyle(theme.quiet)
            } else {
                DayTimeline(entries: items, selected: selected, theme: theme)
            }
            if !system.canReadEvents { connectCalendarButton }
        }
    }

    private var anytimeSection: some View {
        let local = localItems.filter { $0.schedule?.dayOnly == selected && $0.schedule?.hour == nil }
        let external = system.reminders.filter { $0.schedule?.dayOnly == selected && $0.schedule?.hour == nil }
        let done = local.filter(\.completed).count + external.filter(\.completed).count
        return VStack(alignment: .leading, spacing: 15) {
            taskSection(title: String(localized: "随时做"), local: local.filter { !$0.completed }, external: external.filter { !$0.completed })
            if done > 0 {
                DisclosureGroup("已完成 \(done) 项", isExpanded: $expandedDone) {
                    taskRows(local: local.filter(\.completed), external: external.filter(\.completed), showDate: false)
                }
                .font(.caption).foregroundStyle(theme.quiet)
            }
            if isToday { overdueSection(local: localItems, reminders: system.reminders) }
            Rectangle().fill(theme.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 9) {
                sectionTitle(String(localized: "日备注"))
                DayNoteEditor(key: selected.key, saved: notes.first { $0.dayKey == selected.key }?.body ?? "",
                              save: saveNote, theme: theme).id(selected.key)
            }
        }
    }
    #endif

    private var connectCalendarButton: some View {
        Button {
            Task { await report { try await system.authorizeEvents() } }
        } label: {
            HStack(spacing: 6) {
                ASMOIcon(mark: .calendar, size: 15)
                Text("连接 Apple 日历").font(.caption.weight(.medium))
            }
            .foregroundStyle(theme.accent)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func overdueSection(local: [TaskRecord], reminders: [SystemTask]) -> some View {
        let past = local.filter { !$0.completed && !$0.calendarLinked && isBeforeToday($0.schedule) }
        let overdue = reminders.filter { !$0.completed && isBeforeToday($0.schedule) }
        if !past.isEmpty || !overdue.isEmpty {
            DisclosureGroup {
                taskRows(local: past, external: overdue, showDate: true)
            } label: {
                Text("逾期 \(past.count + overdue.count) 项")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.quiet)
            }
        }
    }

    private func timelineEntries(events: [SystemEvent], local: [TaskRecord], reminders: [SystemTask],
                                 linkedTasks: [UUID: TaskRecord]? = nil,
                                 availableLinkedIDs: Set<UUID>? = nil, includeUntimed: Bool = false) -> [TimelineEntry] {
        let calendar = clock.calendar
        let visibleEvents = events.filter { $0.importantKind == nil }
        let linked = Set(visibleEvents.compactMap(\.asmoID))
        var entries = visibleEvents.map { event -> TimelineEntry in
            let task = event.asmoID.flatMap { id in
                if let linkedTasks { return linkedTasks[id] }
                return tasks.first { $0.id == id && $0.calendarLinked }
            }
            let detail = [event.calendarTitle, event.alertLead.map {
                DayTimeline.time(event.start.addingTimeInterval(-Double($0) * 60), calendar: calendar) + String(localized: " 提醒")
            }].compactMap { $0 }.joined(separator: " · ")
            let toggle: (() -> Void)? = task.map { record in
                { record.completed.toggle(); persist() }
            }
            return TimelineEntry(id: event.id, title: event.title, detail: detail,
                                 start: event.allDay ? nil : event.start, end: event.allDay ? nil : event.end,
                                 completed: task?.completed ?? false, toggle: toggle,
                                 edit: { edit(event, task: task) }, dragID: event.writable ? event.id : nil)
        }
        var untimed: [TimelineEntry] = []
        for task in local where !linked.contains(task.id) {
            guard let plan = task.schedule, includeUntimed || plan.hour != nil else { continue }
            if task.calendarLinked, let anchor = task.linkedEventStart,
               availableLinkedIDs?.contains(task.id) ?? system.hasLinkedEvent(task.id, anchor: anchor) { continue }
            // A subtask carried with its parent doesn't repeat the parent's "从 11/7 顺延".
            let parentCarried = task.parentID.flatMap { id in local.first { $0.id == id }?.carriedFrom }
            let carried = task.carriedFrom == parentCarried ? nil
                : task.carriedFrom.flatMap(JournalDays.date(forKey:)).map { String(localized: "从 \($0.month)/\($0.day ?? 1) 顺延") }
            let detail = [carried ?? "", task.note, task.calendarLinked ? String(localized: "日历待同步") : "",
                          task.pendingReminder == nil ? "" : String(localized: "提醒待设置")].filter { !$0.isEmpty }.joined(separator: " · ")
            let entry = TimelineEntry(id: task.id.uuidString, title: task.title, detail: detail,
                                      start: plan.hour == nil ? nil : plan.date(in: calendar),
                                      end: endDate(plan, minute: task.endMinute),
                                      completed: task.completed, toggle: { task.completed.toggle(); persist() },
                                      edit: { edit(task) }, timeEdit: agendaTimeEdit(for: task, plan: plan),
                                      dragID: task.calendarLinked ? nil : task.id.uuidString,
                                      delete: deleteAction(task),
                                      rename: renameAction(task),
                                      makeRoutine: routineAction(task),
                                      titleStyle: task.titleStyle)
            if plan.hour == nil { untimed.append(entry) }
            else { entries.append(entry) }
        }
        for task in reminders {
            guard let plan = task.schedule, includeUntimed || plan.hour != nil else { continue }
            let detail = [task.note, task.alertAt.map {
                DayTimeline.time($0, calendar: calendar) + String(localized: " 系统提醒")
            } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
            let entry = TimelineEntry(id: task.id, title: task.title, detail: detail,
                                      start: plan.hour == nil ? nil : plan.date(in: calendar),
                                      end: endDate(plan, minute: task.endMinute), completed: task.completed,
                                      toggle: { Task { await report { try await system.toggle(task) } } },
                                      edit: { edit(task) }, dragID: task.id)
            if plan.hour == nil { untimed.append(entry) }
            else { entries.append(entry) }
        }
        entries.sort { ($0.start ?? .distantFuture, $0.id) < ($1.start ?? .distantFuture, $1.id) }
        return entries + untimed
    }

    private func agendaTimeEdit(for task: TaskRecord, plan: PlanDate) -> TimelineTimeEdit? {
        guard plan.day != nil, !task.calendarLinked else { return nil }
        let start = plan.hour.map { $0 * 60 + (plan.minute ?? 0) }
        return TimelineTimeEdit(selection: .init(start: start, end: task.endMinute)) { selection in
            guard task.modelContext != nil, let current = task.schedule, current.day != nil,
                  !task.calendarLinked else { throw EditorError.date }
            var schedule = current.dayOnly
            if let minute = selection.start {
                schedule.hour = minute / 60
                schedule.minute = minute % 60
                guard let instant = schedule.date(in: clock.calendar) else { throw EditorError.clock }
                if let end = selection.end {
                    guard let finish = endDate(schedule, minute: end), finish > instant else { throw EditorError.range }
                }
            }
            task.schedule = schedule
            task.endMinute = selection.end
            do { try context.save() }
            catch { context.rollback(); throw error }
        }
    }

    private func endDate(_ schedule: PlanDate, minute: Int?) -> Date? {
        guard let minute else { return nil }
        var day = schedule.dayOnly
        if minute >= 1440 {
            guard let start = day.date(in: clock.calendar),
                  let later = clock.calendar.date(byAdding: .day, value: minute / 1440, to: start) else { return nil }
            day = PlanDate.from(later, calendar: clock.calendar)
        }
        day.hour = (minute / 60) % 24
        day.minute = minute % 60
        return day.date(in: clock.calendar)
    }

    private var monthContent: some View {
        let month = String(selected.key.prefix(7))
        return VStack(alignment: .leading, spacing: 24) {
            taskSection(title: String(localized: "本月 · 日期待定"),
                        local: localItems.filter { $0.schedule?.key == month }, external: [])
            taskSection(title: String(localized: "已安排"),
                        local: localItems.filter { $0.schedule?.day != nil && $0.schedule?.key.hasPrefix(month) == true },
                        external: system.reminders.filter { $0.schedule?.key.hasPrefix(month) == true }, showDate: true)
        }
    }

    private func sectionTitle(_ title: String, count: Int? = nil) -> some View {
        HStack(spacing: 9) {
            Text(title.localized).accessibilityAddTraits(.isHeader)
            if let count { Text("\(count) 项").font(.caption.monospacedDigit()).foregroundStyle(theme.quiet) }
        }
        .font(.headline.weight(.semibold))
        .foregroundStyle(theme.ink)
    }

    private func taskSection(title: String, local: [TaskRecord], external: [SystemTask], showDate: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let count = local.filter { !$0.completed }.count + external.filter { !$0.completed }.count
            #if os(macOS)
            sectionTitle(title, count: count > 0 ? count : nil)
            VStack(alignment: .leading, spacing: 0) {
                taskRows(local: local, external: external, showDate: showDate)
            }
            #else
            sectionTitle(title, count: count)
            if local.isEmpty && external.isEmpty {
                Text("这里还没有待办").font(.subheadline).foregroundStyle(theme.quiet)
            }
            taskRows(local: local, external: external, showDate: showDate)
            #endif
        }
    }

    @ViewBuilder
    private func taskRows(local: [TaskRecord], external: [SystemTask], showDate: Bool) -> some View {
        ForEach(local.sorted { ($0.completed ? 1 : 0, $0.schedule ?? selected, $0.createdAt) <
                               ($1.completed ? 1 : 0, $1.schedule ?? selected, $1.createdAt) }, id: \.id) { task in
            taskRow(title: task.title, completed: task.completed, schedule: task.schedule, showDate: showDate,
                    indicator: task.pendingReminder == nil ? nil : String(localized: "提醒待设置"),
                    toggle: { task.completed.toggle(); persist() }, edit: { edit(task) })
        }
        ForEach(external.sorted { ($0.completed ? 1 : 0, $0.schedule ?? selected) <
                                  ($1.completed ? 1 : 0, $1.schedule ?? selected) }) { task in
            taskRow(title: task.title, completed: task.completed, schedule: task.schedule, showDate: showDate,
                    indicator: task.alertAt == nil ? nil : String(localized: "系统提醒"),
                    toggle: { Task { await report { try await system.toggle(task) } } }, edit: { edit(task) })
        }
    }

    private func taskRow(title: String, completed: Bool, schedule: PlanDate?, showDate: Bool,
                         indicator: String?, toggle: @escaping () -> Void, edit: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Button(action: toggle) {
                    ASMOCheckbox(complete: completed, theme: theme)
                        #if os(macOS)
                        .frame(width: 23, height: 40, alignment: .leading)
                        #else
                        .frame(width: 36, height: 44)
                        #endif
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(completed ? "恢复 \(title)" : "完成 \(title)")
                Button(action: edit) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).strikethrough(completed).foregroundStyle(completed ? theme.quiet : theme.ink)
                        if (showDate && schedule != nil) || schedule?.hour != nil || indicator != nil {
                            HStack {
                                if let schedule, showDate { Text(schedule.label) }
                                else if let hour = schedule?.hour {
                                    Text(String(format: "%02d:%02d", hour, schedule?.minute ?? 0))
                                }
                                if let indicator { Label(indicator, systemImage: "bell") }
                            }
                            .font(.caption).foregroundStyle(theme.quiet)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .accessibilityHint("打开编辑")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.accent)
            Rectangle().fill(theme.line).frame(height: 1)
        }
    }

    #if !os(macOS)
    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let elapsed = voiceSampleTime {
                HStack(spacing: 12) {
                    Text("本次口述 \(elapsed.formatted(.number.precision(.fractionLength(1)))) 秒")
                        .foregroundStyle(theme.quiet)
                    Spacer()
                    Button("准确") { rateVoice(correct: true, seconds: elapsed) }
                        .disabled(!voiceSampleCanPass)
                    Button("需修正") { rateVoice(correct: false, seconds: elapsed) }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
            if !status.isEmpty {
                HStack {
                    Text(status).font(.caption).foregroundStyle(theme.quiet).accessibilityIdentifier("captureStatus")
                    Spacer()
                    if !undoIDs.isEmpty {
                        Button("撤销", action: undo).buttonStyle(.plain).font(.caption.weight(.semibold))
                            .foregroundStyle(theme.accent)
                    }
                }
            }
            HStack(spacing: 9) {
                ASMOIcon(mark: .plus, size: 17).foregroundStyle(theme.accent)
                TextField(voice.recording ? "正在听…" : "记件事…", text: $entry, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .focused($entryFocused)
                    .onSubmit { addTyped() }
                    .accessibilityIdentifier("captureInput")
                if !entry.trimmed.isEmpty {
                    Button(action: organizeTyped) {
                        Image(systemName: "sparkles").frame(width: 30, height: 36)
                    }
                    .disabled(processing || voice.recording || voice.processing)
                    .accessibilityLabel("智能整理文字")
                    Button(action: addTyped) {
                        ASMOIcon(mark: .arrow).frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("保存待办")
                    .accessibilityIdentifier("captureSave")
                }
                Button(action: record) {
                    HStack(spacing: 6) {
                        ASMOIcon(mark: voice.recording ? .stop : .mic, size: 17)
                    }
                    .padding(.horizontal, 10)
                    .frame(minWidth: 40, minHeight: 39).foregroundStyle(theme.onAccent)
                    .background(theme.accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .disabled(voice.processing || processing)
                .accessibilityLabel(voice.recording ? "停止录音" : "语音录入")
            }
            .buttonStyle(.plain)
            .padding(7)
            .padding(.leading, 8)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 13))
            .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(theme.line) }
        }
        .padding(.horizontal, pagePadding)
        .padding(.top, 10)
        .padding(.bottom, 13)
        .frame(maxWidth: 1130)
        .frame(maxWidth: .infinity)
        .background(theme.paper)
    }

    #endif

    private func desktopDayActions(day: PlanDate, note: String) -> some View {
        let matches = desktopDraft == DesktopDraftContext(schedule: day)
        let editingNote = journalNoteDate == day
        let hasNote = !note.trimmed.isEmpty
        let hasPage = pageData(day) != nil
        return VStack(alignment: .leading, spacing: 5) {
            if hasPage {
                notesPreview(day)
            }
            if true {
                // One quiet line: everything else (notes, routines, links) is written on the page itself.
                desktopCaptureButton
            }
            if matches { desktopCaptureFeedback }
            if editingNote {
                HStack {
                    Text("日备注").font(.caption.weight(.medium))
                    Spacer()
                    Button("收起") { journalNoteDate = nil }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(theme.quiet)
                        .accessibilityLabel("收起日备注")
                }
                DayNoteEditor(key: day.key, saved: note, save: { saveNote($0, on: day) }, theme: theme,
                              autoFocus: true, dismissEditor: { journalNoteDate = nil })
                    .id(day)
            } else if hasNote {
                desktopNoteButton(day, label: note)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 5)
    }

    private func desktopNoteButton(_ day: PlanDate, label: String) -> some View {
        Button { journalNoteDate = day } label: {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(theme.quiet)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 6)
                .frame(minHeight: 34, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(DesktopButtonStyle(theme: theme))
        .accessibilityIdentifier("dayNoteOpen")
        .accessibilityHint("编辑日备注")
    }

    private var desktopCaptureButton: some View {
        // Looks exactly like the empty input line, so a click simply puts the cursor there.
        Button { openDocument(selected) } label: {
            HStack(spacing: 10) {
                ASMOIcon(mark: .plus, size: 13).foregroundStyle(theme.accent.opacity(0.8))
                    .frame(width: 22)
                Text("继续写…")
                    .font(.body)
                    .foregroundStyle(theme.quiet.opacity(0.85))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(desktopCaptureBusy)
        .accessibilityIdentifier("timelineAdd")
    }

    /// The day's notes in 逐日: read-only text plus image thumbnails; clicking opens the day's page.
    private func notesPreview(_ day: PlanDate) -> some View {
        let page = pageData(day).flatMap {
            try? NSAttributedString(data: $0, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
        }
        let text = (page?.string ?? "").replacingOccurrences(of: "\u{FFFC}", with: "").trimmed
        var images: [PlatformImage] = []
        page?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: page?.length ?? 0)) { value, _, _ in
            guard let attachment = value as? NSTextAttachment, images.count < 4 else { return }
            if let image = attachment.image ?? attachment.fileWrapper?.regularFileContents.flatMap(PlatformImage.init(data:)) {
                images.append(image)
            }
        }
        return Button { openDocument(day) } label: {
            VStack(alignment: .leading, spacing: 8) {
                if !text.isEmpty {
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(theme.quiet)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                }
                if !images.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                            Image(platformImage: image).resizable().scaledToFill()
                                .frame(width: 120, height: 76)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.line) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 40).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("打开这一天的页面")
    }

    private func pageData(_ day: PlanDate) -> Data? {
        dayPage(day.key)?.rtfd
    }

    private func savePage(_ data: Data?, day: PlanDate) {
        let existing = dayPage(day.key)
        if let data {
            if let existing { existing.rtfd = data; existing.updatedAt = .now }
            else { context.insert(DayPage(dayKey: day.key, rtfd: data)) }
        } else if let existing {
            context.delete(existing)
        }
        persist()
    }

    /// A free writing area under the day, like a page in a doc: Return starts a new line, Tab indents
    /// (a subtask), "- " bullets are fine. When you click away (or press ⌘↵) ASMO turns the lines into items.
    private var desktopInlineInput: some View {
        let organizing = processing
        return VStack(alignment: .leading, spacing: 4) {
            if let context = desktopDraft, context.schedule != defaultSchedule {
                Text(context.schedule.map { "记到 \($0.label)" } ?? "记到未安排")
                    .font(.caption).foregroundStyle(theme.quiet).padding(.leading, 40)
            }
            HStack(alignment: .top, spacing: 10) {
                ASMOIcon(mark: .plus, size: 13).foregroundStyle(theme.accent).frame(width: 22)
                    .padding(.top, 9)
                ZStack(alignment: .topLeading) {
                    if entry.isEmpty {
                        Text(voice.recording ? "正在听…" : "随便写…  一行一件事，Tab 缩进成子任务，写完点别处自动整理")
                            .font(.body).foregroundStyle(theme.quiet.opacity(0.85))
                            .padding(.top, 8).padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $entry)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .scrollDisabled(true)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 34)
                        .focused($entryFocused)
                        .task {
                            // Focus after the editor has joined the window.
                            try? await Task.sleep(for: .milliseconds(45))
                            if !Task.isCancelled && desktopEntryOpen && desktopDraft?.schedule?.dayOnly == selected && sheet == nil {
                                entryFocused = true
                            }
                        }
                        .onKeyPress(.return, phases: .down) { press in
                            // ⌘↵ organizes now; plain Return is just a new line.
                            guard press.modifiers.contains(.command) else { return .ignored }
                            submitDesktopCapture()
                            entryFocused = true
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            guard !processing, !voice.recording, !voice.processing else { return .ignored }
                            entryFocused = false
                            return .handled
                        }
                        .accessibilityIdentifier("captureInput")
                }
                VStack(spacing: 4) {
                    Button(action: record) {
                        ASMOIcon(mark: voice.recording ? .stop : .mic, size: 14)
                            .frame(width: 26, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(DesktopButtonStyle(theme: theme, selected: voice.recording))
                    .disabled(voice.processing || processing)
                    .accessibilityLabel(voice.recording ? "停止录音" : "语音录入")
                    .help(voice.recording ? "停止录音" : "语音录入")
                }
                .padding(.top, 5)
            }
            .padding(.horizontal, 8)
            .background(alignment: .bottom) {
                Rectangle().fill(entryFocused ? theme.accent.opacity(0.5) : theme.line).frame(height: 1)
                    .padding(.leading, 40)
            }
            if !entry.trimmed.isEmpty {
                HStack(spacing: 6) {
                    if organizing { ProgressView().controlSize(.mini) }
                    Text(organizing ? "正在整理…" : "写完点别处，或按 ⌘↵ 整理成待办")
                        .font(.caption).foregroundStyle(theme.quiet)
                }
                .padding(.leading, 40)
            }
        }
        .onChange(of: entryFocused) { _, focused in
            // Leaving the page is the signal that the writing is done.
            if !focused, !entry.trimmed.isEmpty, !voice.recording, !voice.processing { submitDesktopCapture() }
        }
        .onOutsideClick(active: desktopEntryOpen) {
            // Clicking anywhere else: organize what was written, then fold back to the quiet line.
            guard !voice.recording, !voice.processing, !processing else { return }
            if !entry.trimmed.isEmpty { submitDesktopCapture() }
            hideDesktopCapture()
        }
        .onChange(of: entry) { _, _ in
            if desktopFallbackAvailable { desktopFallbackAvailable = false; status = "" }
        }
    }

    @ViewBuilder
    private var desktopCaptureFeedback: some View {
        if let elapsed = voiceSampleTime {
            ViewThatFits {
                HStack(spacing: 8) {
                    Text("本次口述 \(elapsed.formatted(.number.precision(.fractionLength(1)))) 秒")
                    Button("准确") { rateVoice(correct: true, seconds: elapsed) }.disabled(!voiceSampleCanPass)
                    Button("需修正") { rateVoice(correct: false, seconds: elapsed) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Button("准确") { rateVoice(correct: true, seconds: elapsed) }.disabled(!voiceSampleCanPass)
                    Button("需修正") { rateVoice(correct: false, seconds: elapsed) }
                }
            }
            .font(.caption).buttonStyle(.borderless).foregroundStyle(theme.quiet)
        }
        if !status.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(status).font(.caption).foregroundStyle(theme.quiet).accessibilityIdentifier("captureStatus")
                    .fixedSize(horizontal: false, vertical: true)
                if desktopFallbackAvailable {
                    Button("按原文记下") {
                        desktopFallbackAvailable = false
                        addTyped()
                    }
                    .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(theme.accent)
                } else if !undoIDs.isEmpty {
                    Button("撤销", action: undo)
                        .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(theme.accent)
                }
            }
            .padding(.leading, 6)
        }
    }

    private var desktopCaptureBusy: Bool { processing || voice.recording || voice.processing }

    private func hideDesktopCapture() {
        entryParent = nil
        desktopEntryOpen = false
        entryFocused = false
    }

    private func beginDesktopCapture() {
        guard !desktopCaptureBusy, sheet == nil else { return }
        let next = DesktopDraftContext(schedule: selected)
        if desktopDraft != next {
            if let desktopDraft, !entry.trimmed.isEmpty {
                savedDesktopDrafts[desktopDraft] = entry
            }
            entry = savedDesktopDrafts.removeValue(forKey: next) ?? ""
            desktopDraft = next
            status = ""
            desktopFallbackAvailable = false
            voiceSampleTime = nil
        }
        if desktopEntryOpen { entryFocused = true }
        journalNoteDate = nil
        desktopEntryOpen = true
    }

    private func submitDesktopCapture() {
        let original = entry.trimmed
        guard !original.isEmpty, !processing, !voice.recording, !voice.processing else { return }
        if let day = captureSchedule?.dayOnly, captureSchedule?.day != nil {
            if commitDraft(original, defaultDay: day) != nil {
                entry = ""
                status = ""
                undoIDs = []
            }
            return
        }
        if desktopFallbackAvailable { desktopFallbackAvailable = false; addTyped(); return }
        let draft = CaptureParser.manual(original, clock: clock, selectedDay: captureSchedule)
        if !original.contains(where: \.isNewline), CaptureParser.shouldOrganize(original, draft: draft) {
            organizeDesktopTyped()
        } else {
            addTyped()
        }
    }

    private func organizeDesktopTyped() {
        let original = entry
        let date = captureSchedule
        let capturedClock = clock
        guard !original.trimmed.isEmpty, !processing else { return }
        processing = true
        desktopFallbackAvailable = false
        status = String(localized: "正在整理…")
        Task {
            defer { processing = false }
            let locale = Locale(identifier: voiceLocale)
            let parsed = try? await TaskExtraction.onDevice(original, locale: locale)
            guard entry == original else { status = ""; return }
            let drafts: [CaptureDraft]
            if let parsed, !parsed.isEmpty {
                drafts = CaptureParser.validatedDesktop(parsed, original: original, clock: capturedClock, selectedDay: date)
            } else if let recovered = CaptureParser.explicitSequence(original, clock: capturedClock, selectedDay: date) {
                drafts = recovered
            } else {
                status = String(localized: "没能自动拆分，原文已保留。")
                desktopFallbackAvailable = true
                return
            }
            status = ""
            desktopReview = drafts
            sheet = .captureReview
        }
    }

    private func desktopAgenda(focusHeight: CGFloat, pageHeight: CGFloat) -> some View {
        let local = localItems
        let reminders = system.reminders
        let calendar = clock.calendar
        let today = clock.today
        let days = JournalDays.window(around: agendaAnchor, before: journalBefore, after: journalAfter, calendar: calendar)
        let localByDay = Dictionary(grouping: local) { $0.schedule?.dayOnly }
        let remindersByDay = Dictionary(grouping: reminders) { $0.schedule?.dayOnly }
        let notesByKey = Dictionary(notes.map { ($0.dayKey, $0.body) }, uniquingKeysWith: { newest, _ in newest })
        let edits = Dictionary(journalEdits.map { ($0.recordKey, $0.body) }, uniquingKeysWith: { newest, _ in newest })
        let promoted = Set(tasks.compactMap(\.importKey))
        let linkedTasks = Dictionary(tasks.lazy.filter(\.calendarLinked).map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
        let visibleDays = Set(days)
        let linkedAnchors = linkedTasks.compactMapValues { task -> Date? in
            guard let day = task.schedule?.dayOnly, visibleDays.contains(day) else { return nil }
            return task.linkedEventStart
        }
        let calendarRequest = AgendaCalendarRequest(first: days.first, last: days.last, timeZone: calendar.timeZone,
                                                    revision: system.calendarRevision, linkedAnchors: linkedAnchors)
        let gregorian = Dictionary(grouping: importantDates.filter { $0.rule.system == .gregorian }) {
            DateComponents(month: $0.month, day: $0.day)
        }
        let lunar = importantDates.filter { $0.rule.system == .lunar }

        return ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(days, id: \.self) { day in
                        let events = journalEvents.days[day] ?? []
                        let occasions = (gregorian[DateComponents(month: day.month, day: day.day)] ?? []) + lunar
                        let entries = timelineEntries(events: events, local: localByDay[day] ?? [],
                                                      reminders: remindersByDay[day] ?? [], linkedTasks: linkedTasks,
                                                      availableLinkedIDs: journalEvents.linked, includeUntimed: true)
                        agendaDay(day, today: today, events: events, entries: entries,
                                  occasions: occasions.filter { $0.rule.matches(day, calendar: calendar) },
                                  note: notesByKey[day.key] ?? "",
                                  archive: primaryArchive(on: day, promoted: promoted), edits: edits,
                                  focusHeight: focusHeight, pageHeight: pageHeight)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 25)
                .padding(.bottom, 96)
                .frame(maxWidth: .infinity)
            }
            .scrollPosition($journalScroll, anchor: .top)
            #if os(iOS)
            // The floating 说/完成 bar sits above the keyboard; keep the line being written clear of it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if editingDay != nil { Color.clear.frame(height: 66) }
            }
            .scrollDismissesKeyboard(.interactively)
            #endif
            .onScrollTargetVisibilityChange(idType: PlanDate.self, threshold: 0.15) { visible in
                let today = clock.today
                let where_ = visible.contains(today) || visible.isEmpty ? 0 : (visible.min() ?? today) > today ? -1 : 1
                if where_ != todayOffscreen { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { todayOffscreen = where_ } }
                if visible.contains(agendaAnchor), journalReadyAnchor != agendaAnchor { journalReadyAnchor = agendaAnchor }
                guard journalReadyAnchor == agendaAnchor else { return }
                if let first = days.first, visible.contains(first), let earliestArchiveDay, first > earliestArchiveDay {
                    journalBefore += 21
                    journalScroll.scrollTo(id: first, anchor: .top)
                }
                if let last = days.last, visible.contains(last) {
                    journalAfter += 21
                }
            }
            .id(agendaAnchor)
            .task(id: agendaAnchor) {
                let target = agendaAnchor
                // Twice: once right away, once after the lazy rows have laid out (returning from a day page).
                for delay in [0, 120] {
                    if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                    else { await Task.yield() }
                    if !Task.isCancelled, agendaAnchor == target {
                        journalScroll = ScrollPosition(id: target, anchor: .top)
                    }
                }
            }
        .task(id: calendarRequest) {
            let result = await system.agendaEvents(on: days, calendar: calendar, linkedAnchors: linkedAnchors)
            if !Task.isCancelled { journalEvents = result }
        }
    }

    private func agendaDay(_ day: PlanDate, today: PlanDate, events: [SystemEvent], entries: [TimelineEntry],
                           occasions: [ImportantDateRecord], note: String, archive: ArchivedDayEntry?,
                           edits: [String: String], focusHeight: CGFloat, pageHeight: CGFloat) -> some View {
        let expanded = day == selected && agendaDayExpanded
        let isToday = day == today
        let archiveText = archive.map { JournalArchiveText(edits[$0.recordKey] ?? $0.entry.body) }
        let occasionTitles = Set(occasions.map(\.title) + events.filter { $0.importantKind != nil }.map(\.title)).sorted()
        return VStack(alignment: .leading, spacing: 0) {
            DesktopJournalSection(date: day, weekday: journalWeekday(day), isToday: isToday,
                                  showYear: day.year != today.year, theme: theme, expanded: expanded,
                                  motion: desktopMotion,
                                  progress: isToday ? { let status = todayStatus; return status.total > 0 ? (status.done, status.total) : nil }() : nil,
                                  toggleDay: { toggleAgendaDay(day) }) {
                if !expanded {
                    agendaSummary(entries: entries, occasions: occasionTitles, archive: archiveText, note: note)
                }
            }
            // The page and the organized list share one spot and cross-fade, so leaving the page never stacks
            // both for a frame (no jump, no flash).
            ZStack(alignment: .topLeading) {
            // Writing has its own view (every day in a box); the overview stays as it is.
            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    importantHeader(events: events, on: day, localDates: occasions)
                        .padding(.horizontal, 7)
                    ForEach(Array(nested(merged(entries, routinesOn: day)).enumerated()), id: \.element.id) { index, entry in
                        DesktopJournalTask(entry: entry, calendar: clock.calendar, theme: theme,
                                           motion: index < 30 ? desktopMotion : nil)
                            .plannerDraggable(entry.dragID, title: entry.title, theme: theme)
                    }
                    if let archive {
                        journalArchiveLine(archive, day: day, edits: edits)
                            .padding(.horizontal, 7)
                    }
                    if routineAddingDay == day {
                        DesktopRoutineSection(instances: [], theme: theme, adding: true,
                                              toggle: toggleRoutine, skip: skipRoutine, saveTime: saveRoutineTime,
                                              update: { updateRoutine($0, title: $1, weekdays: $2) }, stop: stopRoutine,
                                              add: addRoutine, endAdding: { routineAddingDay = nil })
                    }
                    desktopDayActions(day: day, note: note)
                }
                .padding(.horizontal, 7)
                .padding(.top, 4)
                .padding(.bottom, 21)
                // The open day always fills the window, so 继续写 swaps content without changing any height.
                .frame(minHeight: max(320, pageHeight - Self.editorChrome), alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
            }
            Rectangle().fill(theme.line).frame(height: 1)
        }
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.wash.opacity(dropDay == day ? 0.55 : 0))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(theme.accent.opacity(dropDay == day ? 0.5 : 0), lineWidth: 1.5)
                }
                .padding(.horizontal, -6)
                .animation(.smooth(duration: 0.15), value: dropDay == day)
        }
        .plannerDayDrop(day, target: $dropDay, perform: dropOnDay)
    }

    @ViewBuilder
    private func agendaSummary(entries: [TimelineEntry], occasions: [String],
                               archive: JournalArchiveText?, note: String) -> some View {
        let count = entries.count + occasions.count
        if count > 0 {
            if let occasion = occasions.first {
                Text(occasion).foregroundStyle(theme.accent)
            }
            // The preview shows what's still ahead: top-level open items first, subtasks and finished ones last.
            let subtasks = Set(tasks.lazy.filter { $0.parentID != nil }.map(\.id.uuidString))
            let ordered = entries.filter { !$0.completed && !subtasks.contains($0.id) }
                + entries.filter { $0.completed || subtasks.contains($0.id) }
            let visible = ordered.prefix(occasions.isEmpty ? 2 : 1)
            ForEach(visible) { entry in
                if entry.id != visible.first?.id || !occasions.isEmpty {
                    Circle().fill(theme.quiet.opacity(0.45)).frame(width: 3, height: 3)
                }
                let title = entry.start.map { DayTimeline.time($0, calendar: clock.calendar) + "  " + entry.title } ?? entry.title
                let text = Text(title)
                    .strikethrough(entry.completed)
                    .foregroundStyle(entry.completed ? theme.quiet : theme.ink)
                if let motion = desktopMotion { motion.label(text, id: entry.id) } else { text }
            }
            let more = count - visible.count - (occasions.isEmpty ? 0 : 1)
            if more > 0 { Text("+\(more)").font(.caption.monospacedDigit()).foregroundStyle(theme.quiet).fixedSize() }
        } else if let archive {
            Text(archive.text)
                .strikethrough(archive.completed)
                .foregroundStyle(archive.completed ? theme.quiet : theme.ink)
        } else if !note.trimmed.isEmpty {
            Text(note).foregroundStyle(theme.quiet)
        }
    }

    private func journalWeekday(_ date: PlanDate) -> String {
        guard let value = date.date(in: clock.calendar) else { return "" }
        return AppLanguage.weekday(clock.calendar.component(.weekday, from: value))
    }

    private func primaryArchive(on day: PlanDate, promoted: Set<String>) -> ArchivedDayEntry? {
        guard let first = archivedDays[day]?.first(where: { !$0.entry.body.trimmed.isEmpty }),
              !promoted.contains(first.entry.id) else { return nil }
        return first
    }

    /// A day's title is its overview: clicking it opens or folds the day. Writing starts from 「继续写…」.
    private func toggleAgendaDay(_ day: PlanDate) {
        guard !desktopCaptureBusy else { return }
        if editingDay == day { finishEditing(); return }
        if editingDay != nil { finishEditing { expandAgendaDay(day) }; return }
        expandAgendaDay(day)
    }

    private func expandAgendaDay(_ day: PlanDate) {
        let folding = selected == day && agendaDayExpanded
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) {
            selected = day
            agendaDayExpanded = !folding
        }
    }

    /// From 日历 the journal is still hidden: lay it out on the day first (no animation), then fade it in,
    /// so nothing rebuilds or scrolls while it is on screen.
    private func navigateAgenda(to day: PlanDate) {
        #if os(macOS)
        // The calendar is home: show that day's month with the day selected.
        hideDesktopCapture()
        selected = day
        monthCursor = day
        moveDesktopWorkspace(to: .month)
        return
        #endif
        let fromMonth = page == .month
        hideDesktopCapture()
        let inWindow = JournalDays.window(around: agendaAnchor, before: journalBefore, after: journalAfter,
                                          calendar: clock.calendar).contains(day)
        var quiet = Transaction(); quiet.disablesAnimations = true
        withTransaction(quiet) {
            selected = day
            agendaDayExpanded = true
            journalNoteDate = nil
            if inWindow { journalScroll.scrollTo(id: day, anchor: .top) } else { agendaAnchor = day }
        }
        guard fromMonth else { moveDesktopWorkspace(to: .day); return }
        revealJournal?.cancel()
        revealJournal = Task { @MainActor in
            // A rebuilt list repositions itself twice (0 and 120 ms); reveal after that, a frame is enough otherwise.
            try? await Task.sleep(for: .milliseconds(inWindow ? 30 : 150))
            guard !Task.isCancelled else { return }
            // Rows above are measured on the first pass; anchor again (still hidden) so the day lands on top.
            withTransaction(quiet) { journalScroll = ScrollPosition(id: day, anchor: .top) }
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            withTransaction(quiet) { journalScroll.scrollTo(id: day, anchor: .top) }
            moveDesktopWorkspace(to: .day)
        }
    }

    private func journalArchiveLine(_ item: ArchivedDayEntry, day: PlanDate, edits: [String: String]) -> some View {
        DesktopJournalText(value: JournalArchiveText(edits[item.recordKey] ?? item.entry.body), label: String(localized: "历史记录"),
                           theme: theme, save: { value in saveJournalEdit(value, item: item) },
                           original: { openArchive(item, day: day) })
            .accessibilityIdentifier("journalArchive-\(day.key)")
    }

    private func openArchive(_ item: ArchivedDayEntry, day: PlanDate) {
        archiveSource = archives.first { $0.digest == item.documentDigest && $0.defaultYear == item.defaultYear }
        archiveDay = day
        archiveUnplaced = false
        sheet = .archive
    }

    private func saveJournalEdit(_ value: JournalArchiveText, item: ArchivedDayEntry) {
        if let edit = journalEdits.first(where: { $0.recordKey == item.recordKey }) {
            guard edit.body != value.encoded else { return }
            if value.encoded == item.entry.body {
                context.delete(edit)
            } else {
                edit.body = value.encoded
                edit.updatedAt = .now
            }
        } else {
            guard value.encoded != item.entry.body else { return }
            context.insert(JournalArchiveEdit(recordKey: item.recordKey, body: value.encoded))
        }
        persist()
    }

    /// Everything the month view shows, as one cheap fingerprint (see CalendarHost).
    private var calendarKey: Int {
        var hasher = Hasher()
        hasher.combine(monthCursor); hasher.combine(selected); hasher.combine(clock.today); hasher.combine(scheme == .dark)
        hasher.combine(monthDetail); hasher.combine(dropDay); hasher.combine(monthEvents.days.count)
        hasher.combine(system.calendarRevision); hasher.combine(system.reminders.count)
        for task in tasks {
            hasher.combine(task.id); hasher.combine(task.title); hasher.combine(task.completed)
            hasher.combine(task.schedule); hasher.combine(task.endMinute); hasher.combine(task.parentID)
        }
        for routine in routines {
            hasher.combine(routine.id); hasher.combine(routine.title); hasher.combine(routine.weekdaysRaw)
            hasher.combine(routine.startMinute); hasher.combine(routine.endDay)
        }
        for mark in routineMarks { hasher.combine(mark.routineID); hasher.combine(mark.dayKey); hasher.combine(mark.skipped) }
        for event in monthEvents.days.values.joined() { hasher.combine(event.id); hasher.combine(event.title) }
        hasher.combine(importantDates.count); hasher.combine(notes.count)
        // The imported history (indexed in the background) and edits to its lines.
        hasher.combine(archiveRevision)
        for edit in journalEdits { hasher.combine(edit.recordKey); hasher.combine(edit.body) }
        return hasher.finalize()
    }

    private var desktopMonth: some View {
        let calendar = clock.calendar
        #if os(iOS)
        // iPhone: months in one continuous vertical scroll (Apple Calendar), each built when it scrolls into view.
        return PhoneMonthScroller(start: monthCursor, jump: 0, today: clock.today, theme: theme, calendar: calendar,
                                  items: { desktopCalendarItems($0, calendar: calendar) },
                                  openDay: { openDocument($0) },
                                  writeDay: { day in
                                      openDocument(day)
                                      Task { try? await Task.sleep(for: .milliseconds(550)); pageController.focus() }
                                  }, settings: { sheet = .settings })
        #else
        let month = CalendarMonth(containing: monthCursor, calendar: calendar)
        let visible = Set(month.days)
        let anchors = Dictionary(tasks.lazy.compactMap { task -> (UUID, Date)? in
            guard task.calendarLinked, let day = task.schedule?.dayOnly, visible.contains(day),
                  let start = task.linkedEventStart else { return nil }
            return (task.id, start)
        }, uniquingKeysWith: { first, _ in first })
        let plans = localItems.filter { $0.schedule?.key == String(monthCursor.key.prefix(7)) }.map { task in
            CalendarDayItem(id: task.id.uuidString, title: task.title, kind: .task, completed: task.completed,
                            open: { edit(task) })
        }
        let request = AgendaCalendarRequest(first: month.days.first, last: month.days.last, timeZone: calendar.timeZone,
                                            revision: system.calendarRevision, linkedAnchors: anchors)
        return DesktopMonthView(month: month, cursor: monthCursor, selected: selected, today: clock.today,
                                items: desktopCalendarItems(month, calendar: calendar), monthPlans: plans,
                                theme: theme, motion: desktopMotion,
                                detailDay: $monthDetail, dropDay: $dropDay, select: { selected = $0 },
                                shift: shiftDesktopMonth, drop: dropOnDay,
                                jump: {
                                    jumpDate = monthCursor.date(in: calendar) ?? .now
                                    sheet = .jump
                                }, openDay: { day in
                                    // Double-click: that day on the paper (the document is where days are written).
                                    paperFocus = day.dayOnly
                                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { macHome = "paper" }
                                }, add: quickAddToCalendar,
                                settings: Self.calendarHome ? { sheet = .settings } : nil, logo: Self.calendarHome,
                                leading: AnyView(homeLeading))
            .task(id: request) {
                let result = await system.agendaEvents(on: month.days, calendar: calendar, linkedAnchors: anchors)
                if !Task.isCancelled { monthEvents = result }
            }
        #endif
    }

    private func shiftDesktopMonth(_ offset: Int) {
        let calendar = clock.calendar
        guard let date = monthCursor.date(in: calendar),
              let next = calendar.date(byAdding: .month, value: offset, to: date) else { return }
        monthDetail = nil
        monthCursor = PlanDate.from(next, calendar: calendar)
    }

    // MARK: Hold-to-talk from anywhere

    private var voiceKeyEvents: Publishers.MergeMany<NotificationCenter.Publisher> {
        Publishers.MergeMany([.asmoView, .asmoDebugType, .asmoDebugNav, .asmoDebugDump, .asmoDebugImage, .asmoPageChanged].map {
            NotificationCenter.default.publisher(for: $0)
        })
    }

    private func handleVoiceKey(_ note: Notification) {
        switch note.name {
        case .asmoView:
            #if os(macOS)
            paperFocus = nil
            paperJump += 1
            #else
            selectWorkspace(note.object as? Int ?? 0)
            #endif
        case .asmoPageChanged:
            // An agent wrote on the page that is open: show it.
            if note.object == nil { pageRebuild += 1 }
            else if let key = note.object as? String,
               documentDay?.key == key || editingDay?.key == key || (macHome == "paper" && paperDays.contains { $0.key == key }) {
                pageRebuild += 1
            }
        case .asmoDebugType:
            // Test input (Debug): written at the cursor of the open page, as if typed and followed by Return.
            if let text = note.object as? String { pageController.insert(text.trimmingCharacters(in: .newlines) + "\n") }
        #if os(macOS)
        case .asmoDebugImage:
            if let url = note.object as? URL, let image = NSImage(contentsOf: url) { pageController.textView?.insertImage(image) }
        case .asmoDebugDump:
            // Test (Debug): the open page's paragraphs with their item markers and paragraph styles.
            if let url = note.object as? URL, let storage = pageController.textView?.textStorage {
                var out: [String] = []
                let string = storage.string as NSString
                var location = 0
                while location < string.length {
                    let range = string.paragraphRange(for: NSRange(location: location, length: 0))
                    location = NSMaxRange(range)
                    let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
                    let line = storage.attribute(NSAttributedString.Key("asmo.line"), at: range.location, effectiveRange: nil) != nil
                    out.append("[\(line ? "item" : "text") before=\(style?.paragraphSpacingBefore ?? -1) after=\(style?.paragraphSpacing ?? -1) line=\(style?.lineSpacing ?? -1)] "
                               + string.substring(with: range).replacingOccurrences(of: "\t", with: "→").replacingOccurrences(of: "\n", with: "⏎"))
                }
                try? out.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        #endif
        case .asmoDebugNav:
            // "-1"/"1": edit the previous/next day; "close": click outside (finish editing).
            if let text = note.object as? String {
                if text.trimmed == "close" { if Self.calendarHome { closeDocument() } else { finishEditing() }; return }
                // "edit:2026-11-09": click that day in the calendar (its page pops up).
                if text.hasPrefix("edit:"), let day = JournalDays.date(forKey: String(text.dropFirst(5)).trimmed) { openDocument(day); return }
                // "step:1": the page's › (‹ with -1).
                if text.hasPrefix("step:"), let step = Int(String(text.dropFirst(5)).trimmed) { stepDocument(step); return }
                if text.trimmed == "cal" {
                    #if os(macOS)
                    withAnimation(.smooth(duration: 0.25)) { macHome = "calendar" }
                    #else
                    selectWorkspace(1)
                    #endif
                    return
                }
                if text.trimmed == "paper" { jump(to: clock.today); return }
                // "paperday:2026-11-20": what a double-click on that day in the calendar does.
                if text.hasPrefix("paperday:"), let day = JournalDays.date(forKey: String(text.dropFirst(9)).trimmed) {
                    jump(to: day); return
                }
                // "clock:86400": pretend it is that many seconds later (testing midnight); the day check follows.
                #if DEBUG
                if text.hasPrefix("clock:"), let seconds = TimeInterval(String(text.dropFirst(6)).trimmed) {
                    CaptureClock.debugShift = seconds; updateCurrentDay(); return
                }
                #endif
                if text.trimmed == "settings" { sheet = .settings; return }
                // "bar:<text>": the floating bar, typed and sent. "check:<title>" / "delete:<title>": the row actions.
                // "popover:<N>": 日历's day panel for today+N. "undo": ⌘Z.
                let command = text.trimmed
                if command.hasPrefix("bar:") { barText = String(command.dropFirst(4)); submitBar(); return }
                if command.hasPrefix("check:"), let task = tasks.first(where: { $0.title.contains(command.dropFirst(6)) }) {
                    task.completed.toggle(); persist(); return
                }
                if command.hasPrefix("delete:"), let task = tasks.first(where: { $0.title.contains(command.dropFirst(7)) }) {
                    deleteTask(task); return
                }
                if command.hasPrefix("popover:"), let date = clock.today.date(in: clock.calendar),
                   let target = clock.calendar.date(byAdding: .day, value: Int(command.dropFirst(8)) ?? 0, to: date) {
                    selectWorkspace(1)
                    Task { try? await Task.sleep(for: .milliseconds(500)); monthDetail = PlanDate.from(target, calendar: clock.calendar) }
                    return
                }
                if command == "undo" { notice?.undo?(); notice = nil; return }
                if command.hasPrefix("pill:") {
                    debugVoicePhase = ["listening": .listening, "transcribing": .transcribing, "organizing": .organizing][String(command.dropFirst(5))]
                    return
                }
                if command == "organize" { organizeTick += 1; return }
                #if os(macOS)
                // "cmdz": the same action ⌘Z sends (Edit ▸ Undo through the responder chain).
                // (The test copy runs in the background, so its window is never key: aim at it directly.)
                let testWindow = NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.frame.width > 400 && !($0 is NSPanel) }
                if command == "cmdz" {
                    // Resolve the target the way the menu does for ⌘Z: up the responder chain from the focused view,
                    // asking each for the action itself or a supplemental target (an undo manager).
                    let undo = Selector(("undo:"))
                    var responder = testWindow?.firstResponder
                    var target: AnyObject?
                    while let current = responder, target == nil {
                        if current.responds(to: undo) { target = current }
                        else if let other = current.supplementalTarget(forAction: undo, sender: nil) as AnyObject? { target = other }
                        responder = current.nextResponder
                    }
                    let log = AppPaths.caches.appendingPathComponent("asmo-tasks.txt")
                    try? "undo target: \(String(describing: target.map { type(of: $0) }))".write(to: log, atomically: true, encoding: .utf8)
                    if let target { NSApp.sendAction(undo, to: target, from: nil) }
                    return
                }
                if command == "ping" {
                    let url = AppPaths.caches.appendingPathComponent("asmo-ping.txt")
                    try? String(Date.now.timeIntervalSince1970).write(to: url, atomically: true, encoding: .utf8)
                    return
                }
                if command == "undoinfo" {
                    let responder = testWindow?.firstResponder
                    let info = "key=\(NSApp.keyWindow != nil) main=\(NSApp.mainWindow != nil) responder=\(String(describing: responder.map { type(of: $0) })) "
                        + "canUndo=\(responder?.undoManager?.canUndo ?? false) action=\(responder?.undoManager?.undoActionName ?? "-") "
                        + "batch=\(OrganizeBatch.last != nil)"
                    let url = AppPaths.caches.appendingPathComponent("asmo-tasks.txt")
                    try? info.write(to: url, atomically: true, encoding: .utf8)
                    return
                }
                #endif
                if command == "finish" { finishEditing(); return }
                // "tasks": every item with its day, time, parent and state → asmo-tasks.txt (test checks).
                if text.trimmed == "tasks" {
                    let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    let lines = tasks.sorted { ($0.schedule?.key ?? "", $0.createdAt) < ($1.schedule?.key ?? "", $1.createdAt) }.map { task in
                        let time = task.schedule?.hour.map { String(format: " %02d:%02d", $0, task.schedule?.minute ?? 0) } ?? ""
                        let parent = task.parentID.flatMap { byID[$0]?.title }.map { "  ↳ " + $0 } ?? ""
                        return "\(task.completed ? "[x]" : "[ ]") \(task.schedule?.dayOnly.key ?? "-")\(time) \(task.title)\(parent)"
                    }
                    let url = AppPaths.caches.appendingPathComponent("asmo-tasks.txt")
                    try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
                    return
                }
                // "openN": click day today+N in 日历 (opens it in 逐日).
                if text.trimmed.hasPrefix("open"), let date = clock.today.date(in: clock.calendar),
                   let target = clock.calendar.date(byAdding: .day, value: Int(text.trimmed.dropFirst(4)) ?? 0, to: date) {
                    navigateAgenda(to: PlanDate.from(target, calendar: clock.calendar)); return
                }
                if text.trimmed.hasPrefix("title") {
                    let step = Int(text.trimmed.dropFirst(5)) ?? 0
                    if let date = clock.today.date(in: clock.calendar),
                       let target = clock.calendar.date(byAdding: .day, value: step, to: date) {
                        toggleAgendaDay(PlanDate.from(target, calendar: clock.calendar))
                    }
                    return
                }
                if text.trimmed == "day" { selectWorkspace(0); return }
                // "ed:…": drive the page being written like a person would (select, type, keys, toolbar), and "ed:dump".
                #if DEBUG && os(macOS)
                if text.hasPrefix("ed:") { debugEdit(String(text.dropFirst(3))); return }
                #endif
                if let step = Int(text.trimmed), let current = editingDay ?? Optional(selected),
                   let date = current.date(in: clock.calendar), let next = clock.calendar.date(byAdding: .day, value: step, to: date) {
                    openDocument(PlanDate.from(next, calendar: clock.calendar))
                }
            }
        default: break
        }
    }

    private func heardLabel(_ draft: CaptureDraft) -> String {
        guard let schedule = draft.schedule, schedule.day != nil else { return String(localized: "已记下 · ") + draft.title }
        let day = friendlyDay(schedule.dayOnly)
        let time = schedule.hour.map { String(format: " %02d:%02d", $0, schedule.minute ?? 0) } ?? ""
        return "\(day)\(time) · \(draft.title)"
    }

    // MARK: The document

    /// Organizes a page's leftover writing after you've left it: judged lines become items (removed from the
    /// page), thoughts stay. Works from storage, so leaving is instant.
    private func organizeStoredPage(_ day: PlanDate) async {
        // An organize started inside the page is still running: it files its own results when it returns.
        guard !documentOrganizing, openPageDay != day,
              let page = dayPage(day.key), let raw = page.pendingRaw,
              documentDay != day else { return }
        // Quotes, headings-in-text and bare links stay as written, the same as on the open page.
        let lines = raw.components(separatedBy: "\n").filter { !$0.trimmed.isEmpty && !NoteRule.looksLikeNote($0, heading: false) }
        page.pendingRaw = nil
        persist()
        guard !lines.isEmpty else { return }
        let judgements = await PageOrganizer.shared.judge(lines, context: organizeContext(for: day, text: lines.joined(separator: "\n")), clock: pageClock(day))
        fileJudgements(lines: lines, judgements: judgements, day: day)
    }

    /// Files organized lines of a page that is no longer open: items go to their days, the lines leave the page.
    @discardableResult
    private func fileJudgements(lines: [String], judgements: [LineJudgement], day: PlanDate) -> String? {
        if let page = dayPage(day.key), page.pendingRaw != nil {
            page.pendingRaw = nil
            persist()
        }
        organizingBase = day
        beginOrganizeBatch(day)
        defer { organizingBase = nil }
        var filed = Set<String>()
        var moved = 0
        for (line, judgement) in zip(lines, judgements) where !judgement.isNote {
            if judgement.drop { filed.insert(line.trimmed); continue }
            var running = day
            var lastTop: UUID?
            for (index, piece) in judgement.pieces.enumerated() {
                let done = judgement.done.indices.contains(index) ? judgement.done[index] : false
                if judgement.targets.indices.contains(index), let target = judgement.targets[index],
                   reviseItem(target, piece: piece, done: done, page: day) {
                    continue
                }
                let marked = judgement.pieceSub.indices.contains(index) && judgement.pieceSub[index]
                let follows = index > 0 && (marked || piece.range(of: #"^(记得|带上|带好|顺便|别忘了?|别忘记|看完|没定|定了)"#, options: .regularExpression) != nil)
                var pieceDay = running
                let source = judgement.sources.indices.contains(index) ? judgement.sources[index] : piece
                found: for candidate in [piece, source].map({ $0.replacingOccurrences(of: Dictation.wholeMarker, with: "") }) {
                    for item in Dictation.items(candidate, clock: pageClock(day), defaultDay: running) {
                        if case .task(let draft) = item, let date = draft.schedule, date.day != nil, date.dayOnly != running {
                            pieceDay = date.dayOnly
                            break found
                        }
                    }
                }
                // An organizer item names its own date; without one it is the page's day (not the item before's).
                if piece.hasPrefix(Dictation.wholeMarker) && pieceDay == running && running != day {
                    pieceDay = day
                    for item in Dictation.items(piece.replacingOccurrences(of: Dictation.wholeMarker, with: ""), clock: pageClock(day), defaultDay: day) {
                        if case .task(let draft) = item, let date = draft.schedule, date.day != nil { pieceDay = date.dayOnly }
                        break
                    }
                }
                running = pieceDay
                let made = commitDocumentLine(piece, day: pieceDay, parent: follows ? lastTop : nil, done: done) ?? []
                if !follows, let first = made.first(where: { $0.kind == .task }) { lastTop = UUID(uuidString: first.id) }
                if pieceDay != day { moved += 1 }
            }
            filed.insert(line.trimmed)
            if let note = judgement.noteText { appendNote(note, day: day) }
        }
        // Take the filed lines off the page.
        if !filed.isEmpty, let data = pageData(day), let text = try? NSMutableAttributedString(
            data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil) {
            let string = text.string as NSString
            var location = string.length
            while location > 0 {
                let paragraph = string.paragraphRange(for: NSRange(location: location - 1, length: 0))
                let content = string.substring(with: paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
                if filed.contains(NoteRule.stripMarker(content)) || filed.contains(content) {
                    text.deleteCharacters(in: paragraph)
                }
                location = paragraph.location
            }
            let remaining = text.string.trimmed.isEmpty ? nil
                : try? text.data(from: NSRange(location: 0, length: text.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            savePage(remaining, day: day)
        }
        var summary = endOrganizeBatch(quiet: true)
        if moved > 0, summary != nil { summary! += String(localized: "，\(moved) 件记到了别的日子") }
        if let summary, let batch = OrganizeBatch.last { announce(summary, undo: { undoOrganize(batch) }) }
        return summary
    }

    /// The mic in the page's toolbar: what you say is written at the cursor, then organized like typing.
    private func toggleDocumentVoice() {
        if pageController.recording {
            pageController.recording = false
            pageTranscribing = true
            Task {
                defer { pageTranscribing = false }
                do {
                    let heard = try await voice.finish(locale: Locale(identifier: voiceLocale))
                    guard !heard.trimmed.isEmpty else { announce(String(localized: "没有听清，请再说一次")); return }
                    pageController.insert(heard + "\n")
                    // Organize what was said right away (with the rest of the page as context), visibly.
                    voiceOrganizing = true
                    organizeTick += 1
                } catch {
                    announce(error.localizedDescription)
                }
            }
        } else {
            guard !voice.recording, !voice.processing else { return }
            Task {
                do {
                try await voice.start()
                    pageController.recording = true
                } catch {
                    announce(error.localizedDescription)
                }
            }
        }
    }

    /// Everything the paper's days are drawn from, looked up once per drawing (years of history means
    /// thousands of days; each one should only touch its own things).
    private struct DocIndex {
        var tasks: [PlanDate: [TaskRecord]] = [:]
        var gregorian: [Int: [ImportantDateRecord]] = [:]
        var lunar: [ImportantDateRecord] = []
        var marks: [String: RoutineMark] = [:]
        var notes: [String: DayNote] = [:]
        var pages: [String: Data] = [:]
        /// Lines written on a page but not organized yet (they stay to-dos-in-waiting when the page is drawn again).
        var pending: [String: [String]] = [:]
        var reminders: [PlanDate: [SystemTask]] = [:]
        var promoted = Set<String>()
        var edits: [String: String] = [:]
        /// Changes when the important dates or the time zone do (what `occasions(on:)` remembers is for one value).
        var occasionSignature = 0
        /// Important dates are shown from this day on.
        var since = PlanDate(year: 1, month: 1, day: 1)
    }

    private func docIndex(_ days: [PlanDate]? = nil) -> DocIndex {
        var index = DocIndex()
        for task in tasks where !task.calendarLinked {
            if let day = task.schedule?.dayOnly { index.tasks[day, default: []].append(task) }
        }
        for record in importantDates {
            if record.rule.system == .gregorian { index.gregorian[record.rule.month * 100 + record.rule.day, default: []].append(record) }
            else { index.lunar.append(record) }
        }
        var hasher = Hasher()
        hasher.combine(clock.calendar.timeZone.identifier)
        for record in importantDates {
            hasher.combine(record.id); hasher.combine(record.month); hasher.combine(record.day); hasher.combine(record.systemRaw)
            hasher.combine(record.timeZoneID); hasher.combine(record.kindRaw)
            hasher.combine(record.alternativeMonth); hasher.combine(record.alternativeDay)
        }
        index.occasionSignature = hasher.finalize()
        index.marks = Dictionary(routineMarks.map { ($0.routineID.uuidString + "|" + $0.dayKey, $0) }, uniquingKeysWith: { first, _ in first })
        index.notes = Dictionary(notes.filter { !$0.body.trimmed.isEmpty }.map { ($0.dayKey, $0) }, uniquingKeysWith: { first, _ in first })
        // Only the pages of the days being drawn.
        let keys = (days ?? []).map(\.key)
        let pages: [DayPage]
        if days == nil {
            pages = (try? context.fetch(FetchDescriptor<DayPage>())) ?? []
        } else {
            pages = (try? context.fetch(FetchDescriptor<DayPage>(predicate: #Predicate { keys.contains($0.dayKey) }))) ?? []
        }
        index.pages = Dictionary(pages.compactMap { page in page.rtfd.map { (page.dayKey, $0) } }, uniquingKeysWith: { first, _ in first })
        for page in pages { if let raw = page.pendingRaw { index.pending[page.dayKey] = raw.components(separatedBy: "\n") } }
        for reminder in system.reminders where reminder.asmoID == nil {
            if let day = reminder.schedule?.dayOnly { index.reminders[day, default: []].append(reminder) }
        }
        index.promoted = Set(tasks.compactMap(\.importKey))
        index.edits = Dictionary(journalEdits.map { ($0.recordKey, $0.body) }, uniquingKeysWith: { newest, _ in newest })
        index.since = clock.offset(days: -60) ?? clock.today
        return index
    }

    /// When each important date begins on each local day, worked out once per day.
    private final class OccasionStarts {
        var signature = 0
        var byDay: [PlanDate: [(id: UUID, start: ImportantDateStart)]] = [:]
    }
    @State private var occasionStarts = OccasionStarts()

    /// The important dates that begin on this local day (in their own time zones), with when.
    private func occasions(on day: PlanDate, signature: Int) -> [(record: ImportantDateRecord, start: ImportantDateStart)] {
        let box = occasionStarts
        if box.signature != signature {
            box.signature = signature
            box.byDay = [:]
        }
        let found: [(id: UUID, start: ImportantDateStart)]
        if let known = box.byDay[day] {
            found = known
        } else {
            let calendar = clock.calendar
            found = importantDates.compactMap { record in record.start(onLocal: day, calendar: calendar).map { (record.id, $0) } }
            box.byDay[day] = found
        }
        guard !found.isEmpty else { return [] }
        return found.compactMap { entry in importantDates.first { $0.id == entry.id }.map { ($0, entry.start) } }
    }

    private func documentDays(_ days: [PlanDate]) -> [DocDay] {
        #if DEBUG
        let started = Date.now
        defer { PerfLog.note("documentDays", since: started) }
        #endif
        let index = docIndex(days)
        return days.map { documentDay($0, index: index) }
    }

    private func documentDay(_ day: PlanDate) -> DocDay { documentDay(day, index: docIndex([day])) }

    private func documentDay(_ day: PlanDate, index: DocIndex) -> DocDay {
        let today = clock.today
        let calendar = clock.calendar
        let heading: String
        if day.day == nil {
            // A month's plan: things for "sometime in January".
            heading = day.year == today.year ? String(localized: "\(day.month) 月 · 这个月里") : String(localized: "\(String(day.year)) 年 \(day.month) 月 · 这个月里")
        } else {
            let delta = dayDelta(today, day) ?? 0
            let relative = delta == 0 ? String(localized: " · 今天") : delta == 1 ? String(localized: " · 明天") : delta == -1 ? String(localized: " · 昨天") : ""
            // Another year's days say which year.
            let year = day.year == today.year ? "" : String(day.year) + " 年 "
            heading = year + String(localized: "\(day.month) 月 \(day.day ?? 1) 日  \(journalWeekday(day))\(relative)")
        }
        let dayTasks = index.tasks[day] ?? []
        let ids = Set(dayTasks.map(\.id))
        func time(_ minute: Int?, end: Int?) -> String? {
            guard let minute else { return nil }
            return PlannerClockTime.label(minute) + (end.map { "–" + PlannerClockTime.label($0) } ?? "")
        }
        func minute(_ task: TaskRecord) -> Int? { task.schedule?.hour.map { $0 * 60 + (task.schedule?.minute ?? 0) } }
        func line(_ task: TaskRecord, depth: Int) -> DocLine {
            DocLine(kind: .task, id: task.id.uuidString, depth: depth, time: time(minute(task), end: task.endMinute),
                    title: task.title, done: task.completed, style: task.titleStyle)
        }
        func family(_ task: TaskRecord, depth: Int) -> [DocLine] {
            [line(task, depth: depth)] + dayTasks.filter { $0.parentID == task.id }
                .sorted { $0.createdAt < $1.createdAt }
                .flatMap { family($0, depth: min(depth + 1, 3)) }
        }
        // Top level: important dates first, then tasks, routines and calendar events in time order; untimed after;
        // the imported history last.
        var top: [(minute: Int?, order: Date, lines: [DocLine])] = []
        for task in dayTasks where task.parentID == nil || !ids.contains(task.parentID!) {
            top.append((minute(task), task.createdAt, family(task, depth: 0)))
        }
        guard day.day != nil else {
            top.sort { ($0.minute ?? 10_000, $0.order) < ($1.minute ?? 10_000, $1.order) }
            return DocDay(day: day, heading: heading, isToday: false, lines: top.flatMap(\.lines), notes: index.pages[day.key], pending: index.pending[day.key] ?? [])
        }
        var occasionTitles = Set<String>()
        // Birthdays and anniversaries from now on (on days of the old history they'd only be noise, and lunar
        // dates cost a calendar conversion each). A date kept in another time zone shows on the local day it
        // begins there, with the local time: a birthday in China starts at 11:00 the morning before in New York.
        let recent = day >= index.since
        for (record, start) in recent ? occasions(on: day, signature: index.occasionSignature) : []
            where occasionTitles.insert(record.title).inserted {
            let elsewhere = start.minute != 0 || start.there != day
            let zone = ImportantDateTimeZone.label(for: record.rule.timeZoneID)
            top.append((-1, .distantPast, [DocLine(
                kind: .occasion, id: "occasion-\(record.id)", time: start.minute != 0 ? PlannerClockTime.label(start.minute) : nil,
                title: record.title,
                tag: elsewhere ? String(localized: "\(zone) \(start.there.month)月\(start.there.day ?? 1)日") : nil)]))
        }
        // Routines show on every day they repeat, the same as the day at rest (逐日 / frozen).
        for instance in routineInstances(on: day, marks: index.marks) {
            let routine = instance.routine
            top.append((routine.startMinute, routine.createdAt,
                        [DocLine(kind: .routine, id: routine.id.uuidString + "|" + day.key,
                                 time: time(routine.startMinute, end: routine.endMinute), title: routine.title,
                                 done: instance.done, tag: routine.ruleLabel)]))
        }
        for event in (journalEvents.days[day] ?? []) where event.asmoID.map({ !ids.contains($0) }) ?? true {
            if event.importantKind != nil {
                guard recent, occasionTitles.insert(event.title).inserted else { continue }
                top.append((-1, event.start, [DocLine(kind: .occasion, id: "occasion-" + event.id, title: event.title)]))
                continue
            }
            let start = event.allDay ? nil : PlanDate.from(event.start, calendar: calendar, includeTime: true).minuteOfDay
            top.append((start, event.start, [DocLine(kind: .event, id: event.id, time: start.map { PlannerClockTime.label($0) },
                                                     title: event.title)]))
        }
        // Apple Reminders made elsewhere: shown like events (they're checked off in Reminders or the calendar).
        for reminder in index.reminders[day] ?? [] {
            top.append((reminder.schedule?.minuteOfDay, .distantFuture,
                        [DocLine(kind: .event, id: "reminder-" + reminder.id,
                                 time: reminder.schedule?.minuteOfDay.map { PlannerClockTime.label($0) },
                                 title: reminder.title, done: reminder.completed)]))
        }
        top.sort { ($0.minute ?? 10_000, $0.order) < ($1.minute ?? 10_000, $1.order) }
        var lines = top.flatMap(\.lines)
        // An old day note (from before pages) and the imported history, as written that day.
        if let note = index.notes[day.key] {
            for (index, text) in note.body.components(separatedBy: .newlines).map(\.trimmed).filter({ !$0.isEmpty }).enumerated() {
                lines.append(DocLine(kind: .archive, id: "note-\(day.key)-\(index)", title: text))
            }
        }
        if let history = archivedDays[day] {
            let promoted = index.promoted
            let edits = index.edits
            var seen = Set(lines.map { $0.title.trimmed })
            for item in history where !item.entry.body.trimmed.isEmpty && !promoted.contains(item.entry.id) {
                let text = JournalArchiveText(edits[item.recordKey] ?? item.entry.body)
                let key = text.text.trimmed
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                // One line on the page per line of the entry.
                for (index, part) in text.text.components(separatedBy: .newlines).map(\.trimmed).filter({ !$0.isEmpty }).enumerated() {
                    lines.append(DocLine(kind: .archive, id: "archive-\(item.recordKey)-\(index)", title: part, done: text.completed))
                }
            }
        }
        return DocDay(day: day, heading: heading, isToday: day == today, lines: lines, notes: index.pages[day.key], pending: index.pending[day.key] ?? [])
    }

    private var documentActions: DocActions {
        DocActions(
            commit: { text, day, page, parent, done in commitDocumentLine(text, day: day, page: page, parent: parent, done: done) },
            update: { line, text, day, parent in updateDocumentLine(line, text: text, day: day, parent: parent) },
            toggle: { line, day in
                if line.kind == .task, let task = tasks.first(where: { $0.id.uuidString == line.id }) {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { task.completed.toggle(); persist() }
                } else if line.kind == .routine, let instance = routineInstance(line.id, day: day) {
                    toggleRoutine(instance)
                }
            },
            restore: { id in
                guard let uuid = UUID(uuidString: id), let bring = deletedTasks[uuid] else { return false }
                deletedTasks[uuid] = nil
                bring()
                return true
            },
            restyle: { id, style in
                // An item made a moment ago may not be in the query yet: look it up in the store.
                let uuid = UUID(uuidString: id)
                let task = tasks.first(where: { $0.id == uuid })
                    ?? uuid.flatMap { key in try? context.fetch(FetchDescriptor<TaskRecord>(predicate: #Predicate { $0.id == key })).first }
                guard let task, task.titleStyle != style else { return }
                task.titleStyle = style
                persist()
            },
            strike: { line, day, struck in
                if line.kind == .task, let task = tasks.first(where: { $0.id.uuidString == line.id }), task.completed != struck {
                    task.completed = struck
                    persist()
                } else if line.kind == .routine, let instance = routineInstance(line.id, day: day), instance.done != struck {
                    // Struck = done that day, un-struck = not done (whatever mark the day had, a skip included).
                    if let mark = routineMark(instance) { context.delete(mark) }
                    if struck { context.insert(RoutineMark(routineID: instance.routine.id, dayKey: instance.day.key, skipped: false)) }
                    persist()
                }
            },
            editTag: { id in
                // A date's "中国时间 11月22日": its day and time zone are changed in the date's own editor.
                if id.hasPrefix("occasion-"), let record = importantDates.first(where: { "occasion-\($0.id)" == id }) {
                    editOccasion(record)
                    return
                }
                let routineID = id.split(separator: "|").first.map(String.init)
                if let routine = routines.first(where: { $0.id.uuidString == routineID }) { editingRoutine = routine }
            },
            delete: { line, day in
                if line.kind == .task, let task = tasks.first(where: { $0.id.uuidString == line.id }) {
                    deleteTask(task)
                } else if line.kind == .routine, let instance = routineInstance(line.id, day: day) {
                    // A repeating line deleted: it stops repeating from this day (or, one tap away, just this day).
                    stopRoutine(instance.routine, from: day, instance: instance)
                }
            },
            saveNotes: { day, data, pending in
                if pageData(day) != data { savePage(data, day: day) }
                let raw = pending.isEmpty ? nil : pending.joined(separator: "\n")
                if let page = dayPage(day.key), page.pendingRaw != raw {
                    page.pendingRaw = raw
                    persist()
                }
            },
            dayOf: { text, page, fallback in
                // "piece|clause": the piece's own date wins, then the clause's, then the fallback.
                for candidate in text.replacingOccurrences(of: Dictation.wholeMarker, with: "").components(separatedBy: "|") {
                    for item in Dictation.items(candidate, clock: pageClock(page), defaultDay: fallback) {
                        if case .task(let draft) = item, let date = draft.schedule, date.day != nil, date.dayOnly != fallback {
                            return date.dayOnly
                        }
                    }
                }
                return fallback
            },
            moved: { count, day in announce(count == 1 ? String(localized: "已记到 \(friendlyDay(day))") : String(localized: "\(count) 件记到了 \(friendlyDay(day))")) },
            classify: { lines, day in
                await PageOrganizer.shared.judge(lines, context: organizeContext(for: day, text: lines.joined(separator: "\n")), clock: pageClock(day))
            },
            revise: { ref, piece, done, page in reviseItem(ref, piece: piece, done: done, page: page) },
            batch: { day, begin in if begin { beginOrganizeBatch(day) } else { endOrganizeBatch(quiet: false) } },
            undoOrganize: { if let batch = OrganizeBatch.last { undoOrganize(batch) } },
            organizing: { busy in
                organizingPages = max(0, organizingPages + (busy ? 1 : -1))
                documentOrganizing = organizingPages > 0
            },
            fileLater: { lines, judgements, day in fileJudgements(lines: lines, judgements: judgements, day: day) },
            navigate: { step in stepDocument(step) },
            focused: { day in
                // The cursor moved to another day's box: that day is the one being written.
                #if os(macOS)
                _ = day   // One page at a time on the Mac (the popup).
                #else
                if editingDay != nil, editingDay != day { instantly { editingDay = day; selected = day } }
                #endif
            })
    }

    private func routineInstance(_ lineID: String, day: PlanDate) -> RoutineInstance? {
        let id = lineID.split(separator: "|").first.map(String.init)
        return routineInstances(on: day).first { $0.routine.id.uuidString == id }
    }

    /// A finished line of writing in the document. Commands run; dated text lands on its day; "每天…" becomes a
    /// routine. Returns the lines to draw in place for this day, or nil to keep the line as a note.
    /// Words like 明天 on a page mean "the day after this page", so a page reads dates from its own day.
    private func pageClock(_ day: PlanDate) -> CaptureClock {
        var copy = clock
        copy.actualNow = clock.now
        let calendar = clock.calendar
        let time = calendar.dateComponents([.hour, .minute, .second], from: clock.now)
        if let start = day.dayOnly.date(in: calendar),
           let moved = calendar.date(bySettingHour: time.hour ?? 12, minute: time.minute ?? 0, second: time.second ?? 0, of: start) {
            copy.now = moved
        }
        return copy
    }

    private func commitDocumentLine(_ text: String, day: PlanDate, page: PlanDate? = nil, parent: UUID?, done: Bool = false) -> [DocLine]? {
        let relative = pageClock(organizingBase ?? page ?? editingDay ?? documentDay ?? day)
        if text.hasPrefix(Dictation.verbatimMarker) {
            return commitWrittenLine(String(text.dropFirst(Dictation.verbatimMarker.count)), day: day, clock: relative, parent: parent, done: done)
        }
        // The organizer already wrote this as exactly one item: read it whole, never as a command.
        let whole = text.hasPrefix(Dictation.wholeMarker)
        if !whole, let command = PlannerCommand.parse(text, clock: relative, defaultDay: day) {
            _ = run(command)
            return []
        }
        let items = whole ? [Dictation.item(text, clock: relative, defaultDay: day)].compactMap { $0 }
            : Dictation.items(text, clock: relative, defaultDay: day)
        // Something a routine already covers ("做了大眼操") checks the routine off instead of adding a task.
        let spoken: String = {
            if whole, case .task(let draft)? = items.first { return draft.title }
            return Dictation.cleanTitle(text)
        }()
        let dayRoutines = routines.filter { $0.applies(to: day, calendar: clock.calendar) }
        let routineHit = dayRoutines.first(where: { Dictation.sameThing($0.title, spoken) })
            ?? PlannerCommand.bestMatch(spoken, among: dayRoutines, title: \.title, day: { _ in day }, today: day)
                .flatMap { spoken.count <= $0.title.count + 6 ? $0 : nil }
        if let routine = routineHit {
            if done, let instance = routineInstances(on: day).first(where: { $0.routine.id == routine.id }), !instance.done {
                toggleRoutine(instance)
                OrganizeBatch.current?.routineMarks.append((routine.id, day.key))
            }
            return []
        }
        guard !items.isEmpty else { return nil }
        var here: [DocLine] = []
        var elsewhere: [PlanDate] = []
        var review: [CaptureDraft] = []
        for item in items {
            switch item {
            case .task(let draft) where draft.requiresReview:
                review.append(draft)
            case .task(let draft):
                // The same thing said twice ("明天做 rebuttal" in two sentences, or already on the day) is one item;
                // said as done, the existing one is checked off.
                let target0 = (draft.schedule ?? day).dayOnly
                let key = draft.title.lowercased().replacingOccurrences(of: " ", with: "")
                if let existing = tasks.first(where: { $0.schedule?.dayOnly == target0 && !$0.calendarLinked
                    && Dictation.sameThing($0.title, draft.title) }) {
                    if done && !existing.completed {
                        OrganizeBatch.current?.revised.append((existing.id, existing.schedule, existing.endMinute, existing.completed))
                        existing.completed = true
                    }
                    continue
                }
                // Items made a moment ago may not be in the query yet.
                guard RecentItems.insert(key + "|" + target0.key) else { continue }
                let task = TaskRecord(id: draft.id, title: draft.title, schedule: draft.schedule ?? day, endMinute: draft.endMinute)
                task.sourceText = draft.original == draft.title ? nil : draft.original
                task.completed = done
                let target = task.schedule?.dayOnly ?? day
                if target == day {
                    task.parentID = parent
                    let minute = task.schedule?.hour.map { $0 * 60 + (task.schedule?.minute ?? 0) }
                    here.append(DocLine(kind: .task, id: task.id.uuidString,
                                        time: minute.map { PlannerClockTime.label($0) + (task.endMinute.map { "–" + PlannerClockTime.label($0) } ?? "") },
                                        title: task.title, done: done))
                } else {
                    elsewhere.append(target)
                }
                context.insert(task)
                OrganizeBatch.current?.created.append(task.id)
            case .routine(let draft):
                let routine = RoutineRecord(title: draft.title, weekdays: draft.weekdays, monthDay: draft.monthDay, startMinute: draft.startMinute,
                                            endMinute: draft.endMinute, startDay: clock.today.key,
                                            order: (routines.map(\.order).max() ?? 0) + 1)
                // Already a running routine ("每天喝水" said again): nothing new.
                if routines.contains(where: { $0.endDay == nil && $0.weekdays == draft.weekdays && $0.monthDay == draft.monthDay && Dictation.sameThing($0.title, draft.title) }) {
                    continue
                }
                context.insert(routine)
                OrganizeBatch.current?.routines.append(routine.id)
                if day == clock.today && routine.applies(to: day, calendar: clock.calendar) {
                    here.append(DocLine(kind: .routine, id: routine.id.uuidString + "|" + day.key,
                                        time: draft.startMinute.map { PlannerClockTime.label($0) }, title: draft.title,
                                        tag: RoutineParser.label(draft.weekdays, monthDay: draft.monthDay)))
                }
            }
        }
        persist()
        if !review.isEmpty {
            queue.append(contentsOf: review)
            advanceReview()
        }
        if let first = elsewhere.first {
            announce(elsewhere.count == 1 ? String(localized: "已记到 \(friendlyDay(first))") : String(localized: "\(elsewhere.count) 件记到了别的日子"))
        }
        return here
    }

    /// A line typed on the page becomes one item, in the writer's own words. "每天…" is a repeating item; a date
    /// or time in the line is where and when it goes (and is the only thing taken out of the title).
    private func commitWrittenLine(_ text: String, day: PlanDate, clock relative: CaptureClock, parent: UUID?, done: Bool) -> [DocLine]? {
        let written = text.trimmed
        guard !written.isEmpty else { return nil }
        if let draft = RoutineParser.parse(written, clock: relative),
           !routines.contains(where: { $0.endDay == nil && $0.weekdays == draft.weekdays && $0.monthDay == draft.monthDay && Dictation.sameThing($0.title, draft.title) }) {
            let routine = RoutineRecord(title: draft.title, weekdays: draft.weekdays, monthDay: draft.monthDay, startMinute: draft.startMinute,
                                        // From the day it's written on (today at the earliest).
                                        endMinute: draft.endMinute, startDay: max(day.dayOnly, clock.today).key,
                                        order: (routines.map(\.order).max() ?? 0) + 1)
            context.insert(routine)
            persist()
            guard routine.applies(to: day, calendar: clock.calendar) else { return [] }
            return [DocLine(kind: .routine, id: routine.id.uuidString + "|" + day.key,
                            time: draft.startMinute.map { PlannerClockTime.label($0) }, title: draft.title,
                            tag: RoutineParser.label(draft.weekdays, monthDay: draft.monthDay))]
        }
        let draft = CaptureParser.manual(written, clock: relative, selectedDay: day)
        // A date or time counts only where a writer puts one on purpose: at the start of the line ("明天 交材料",
        // "下午3点开会"). In the middle of a sentence ("订周五的票") it is part of the words, and the line stays whole,
        // on this day. A date it couldn't pin down stays in the words too: nothing is asked, nothing is guessed.
        let leads = !draft.title.trimmed.isEmpty && draft.title != written && written.hasSuffix(draft.title)
        let sure = leads && (!draft.requiresReview || draft.action != .task)
        let schedule = sure ? (draft.schedule ?? day) : day
        let title = sure ? draft.title : written
        let task = TaskRecord(id: draft.id, title: title, schedule: schedule, endMinute: schedule.hour == nil ? nil : draft.endMinute)
        task.sourceText = written == title ? nil : written
        task.completed = done
        let target = schedule.dayOnly
        if target == day { task.parentID = parent }
        context.insert(task)
        OrganizeBatch.current?.created.append(task.id)
        persist()
        guard target == day else {
            announce(String(localized: "已记到 \(friendlyDay(target))"))
            return []
        }
        let minute = schedule.hour.map { $0 * 60 + (schedule.minute ?? 0) }
        return [DocLine(kind: .task, id: task.id.uuidString,
                        time: minute.map { PlannerClockTime.label($0) + (task.endMinute.map { "–" + PlannerClockTime.label($0) } ?? "") },
                        title: title, done: done)]
    }

    // MARK: Organizing context, batches and undo

    /// What the organizer is told besides the writing: today, the page's day, and the items already there (the
    /// page's own items and routines, plus open items on nearby days), numbered so it can point at them.
    private func organizeContext(for day: PlanDate, text: String = "") -> OrganizeContext {
        // Each day's box reads its own dates: in 11月12日's box "明天" is the 13th. So the model is told the
        // page's day is "today", and every label (明天, 昨天) is counted from it, the way the rules read the page.
        let today = day.dayOnly
        func label(_ date: PlanDate) -> String {
            let relative = [0: "（今天）", 1: "（明天）", -1: "（昨天）"][dayDelta(today, date) ?? 99] ?? ""
            return "\(date.month)月\(date.day ?? 1)日 \(journalWeekday(date))" + relative
        }
        func when(_ start: Int?, _ end: Int?) -> String {
            guard let start else { return "" }
            return PlannerClockTime.label(start) + (end.map { "–" + PlannerClockTime.label($0) } ?? "") + " "
        }
        let now = clock.calendar.dateComponents([.hour, .minute], from: clock.now)
        let time = day == clock.today ? "，现在 \(String(format: "%02d:%02d", now.hour ?? 0, now.minute ?? 0))" : ""
        var lines = ["今天：\(label(today))\(time)", "这一页：\(label(day))"]
        var refs: [String: String] = [:]
        var rows: [String] = []
        func add(_ ref: String, _ text: String) {
            let id = "E\(refs.count + 1)"
            refs[id] = ref
            rows.append(id + " " + text)
        }
        func minute(_ task: TaskRecord) -> Int? { task.schedule?.hour.map { $0 * 60 + (task.schedule?.minute ?? 0) } }
        let own = tasks.filter { $0.schedule?.dayOnly == day && !$0.calendarLinked }
            .sorted { (minute($0) ?? 10_000, $0.createdAt) < (minute($1) ?? 10_000, $1.createdAt) }
        for task in own {
            add("task:" + task.id.uuidString, "\(label(day)) \(when(minute(task), task.endMinute))\(task.title)\(task.completed ? "（已完成）" : "")")
        }
        for instance in routineInstances(on: day) {
            let routine = instance.routine
            add("routine:" + routine.id.uuidString,
                "\(routine.ruleLabel) \(when(routine.startMinute, routine.endMinute))\(routine.title)\(instance.done ? "（今天已完成）" : "")")
        }
        // Open items on the days right around the page, and any open item in the next three weeks that shares
        // words with what was written ("和导师开会" finds Wednesday's meeting). A long unrelated list only
        // distracts a small model.
        let written = Set(pairs(text))
        let nearby = tasks.filter { task in
            guard !task.completed, !task.calendarLinked, let date = task.schedule?.dayOnly, date != day,
                  let delta = dayDelta(day, date) else { return false }
            if (-1...1).contains(delta) { return true }
            return (-3...21).contains(delta) && !written.isDisjoint(with: pairs(task.title))
        }
        .sorted { ($0.schedule?.dayOnly.key ?? "", minute($0) ?? 10_000) < ($1.schedule?.dayOnly.key ?? "", minute($1) ?? 10_000) }
        for task in nearby.prefix(20) {
            guard let date = task.schedule?.dayOnly else { continue }
            add("task:" + task.id.uuidString, "\(label(date)) \(when(minute(task), task.endMinute))\(task.title)")
        }
        lines.append(rows.isEmpty ? "已有事项：无" : "已有事项：\n" + rows.joined(separator: "\n"))
        return OrganizeContext(prompt: lines.joined(separator: "\n"), refs: refs)
    }

    /// Character pairs of the meaningful part of a text (for finding items the writing talks about).
    private func pairs(_ text: String) -> [String] {
        let letters = Array(text.lowercased().filter { $0.isLetter || $0.isNumber })
        let filler: Set<String> = ["一个", "这个", "那个", "然后", "就是", "我会", "进行", "的一", "一下", "今天", "明天", "下午", "上午", "晚上"]
        return zip(letters, letters.dropFirst()).map { String([$0, $1]) }.filter { !filler.contains($0) }
    }

    private func beginOrganizeBatch(_ day: PlanDate) {
        guard OrganizeBatch.current == nil else { return }
        OrganizeBatch.current = OrganizeBatch(day: day, page: pageData(day))
    }

    /// Ends the pass and says what it did (with 撤销 unless `quiet`, where the caller announces).
    @discardableResult
    private func endOrganizeBatch(quiet: Bool) -> String? {
        guard let batch = OrganizeBatch.current else { return nil }
        OrganizeBatch.current = nil
        guard !batch.isEmpty else { return nil }
        OrganizeBatch.last = batch
        var parts: [String] = []
        if !batch.created.isEmpty || !batch.routines.isEmpty { parts.append(String(localized: "整理出 \(batch.created.count + batch.routines.count) 件")) }
        let updated = batch.revised.count + batch.routineMarks.count
        if updated > 0 { parts.append(String(localized: "更新了 \(updated) 件已有的")) }
        let summary = parts.joined(separator: "，")
        if !quiet { announce(summary, undo: { undoOrganize(batch) }) }
        return summary
    }

    /// Puts everything back as it was before the pass: new items removed, changed items restored, and the
    /// writing back on the page (kept as written; it won't be organized again by itself).
    private func undoOrganize(_ batch: OrganizeBatch) {
        guard !batch.undone else { return }
        batch.undone = true
        let created = Set(batch.created)
        for task in tasks where created.contains(task.id) { context.delete(task) }
        let routineIDs = Set(batch.routines)
        for routine in routines where routineIDs.contains(routine.id) { context.delete(routine) }
        for change in batch.revised.reversed() {
            guard let task = tasks.first(where: { $0.id == change.id }) else { continue }
            task.schedule = change.schedule
            task.endMinute = change.end
            task.completed = change.completed
        }
        for mark in batch.routineMarks {
            for record in routineMarks where record.routineID == mark.routine && record.dayKey == mark.day { context.delete(record) }
        }
        savePage(batch.page, day: batch.day)
        if let page = dayPage(batch.day.key) { page.pendingRaw = nil }
        persist()
        if OrganizeBatch.last === batch { OrganizeBatch.last = nil }
        if editingDay == batch.day || documentDay == batch.day { pageRebuild += 1 }
        announce(String(localized: "已撤销整理，原文放回了页面"))
    }

    /// The writing talks about an item that already exists: said as done → checked off; a new date or time →
    /// moved; otherwise nothing (it was just mentioned again).
    @discardableResult
    private func reviseItem(_ ref: String, piece: String, done: Bool, page: PlanDate) -> Bool {
        let parts = ref.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return false }
        let text = piece.replacingOccurrences(of: Dictation.wholeMarker, with: "").trimmed
        // The model's pointer has to name the same thing: "跑步" is never the bank transfer, whatever it said.
        let said = Dictation.cleanTitle(CaptureParser.manual(text, clock: pageClock(page), selectedDay: page).title)
        func alike(_ title: String) -> Bool {
            let a = Set(said.lowercased().filter { $0.isLetter || $0.isNumber })
            let b = Set(title.lowercased().filter { $0.isLetter || $0.isNumber })
            guard !a.isEmpty, !b.isEmpty else { return false }
            return Dictation.sameThing(said, title) || Double(a.intersection(b).count) / Double(min(a.count, b.count)) >= 0.5
        }
        if parts[0] == "routine" {
            guard let routine = routines.first(where: { $0.id == id }), alike(routine.title) else { return false }
            guard done, let instance = routineInstances(on: page).first(where: { $0.routine.id == id }), !instance.done else { return true }
            toggleRoutine(instance)
            OrganizeBatch.current?.routineMarks.append((id, page.key))
            return true
        }
        guard let task = tasks.first(where: { $0.id == id }), alike(task.title) else { return false }
        let current = task.schedule?.dayOnly ?? page
        let parsed = CaptureParser.manual(text, clock: pageClock(page), selectedDay: current)
        // Moving an item to another day is only trusted when the titles really match ("和导师开会" is not the
        // "开会" on Monday): a weak match becomes a new item instead.
        if let date = parsed.schedule, date.day != nil, date.dayOnly != current {
            let title = Dictation.cleanTitle(parsed.title)
            let shared = Set(pairs(title)).intersection(pairs(task.title)).count
            let similar = Dictation.sameThing(title, task.title)
                || Double(shared) / Double(max(1, min(pairs(title).count, pairs(task.title).count))) >= 0.6
                    && abs(title.count - task.title.count) <= 3
            if !similar { return false }
        }
        var schedule = task.schedule
        var end = task.endMinute
        if let date = parsed.schedule, parsed.title.trimmed != text {
            // A date and/or time was said with it.
            var next = date.day != nil ? date : current
            if date.hour == nil { next.hour = task.schedule?.hour; next.minute = task.schedule?.minute }
            else { end = parsed.endMinute }
            schedule = next
        }
        // "一点半理发，这个已经没问题了" is settled, not done: an item still ahead today can't be done yet.
        var stillAhead = false
        if let when = task.schedule, when.dayOnly == clock.today, let hour = when.hour {
            let now = clock.calendar.dateComponents([.hour, .minute], from: clock.now)
            stillAhead = hour * 60 + (when.minute ?? 0) > (now.hour ?? 0) * 60 + (now.minute ?? 0)
        }
        let completed = task.completed || (done && !stillAhead)
        guard schedule != task.schedule || end != task.endMinute || completed != task.completed else { return true }
        OrganizeBatch.current?.revised.append((task.id, task.schedule, task.endMinute, task.completed))
        task.schedule = schedule
        task.endMinute = end
        task.completed = completed
        persist()
        return true
    }

    /// An item line was edited in the document: its text (with any time typed in it) becomes the item.
    private func updateDocumentLine(_ line: DocLine, text: String, day: PlanDate, parent: UUID?) {
        var parsed = CaptureParser.manual(text, clock: clock, selectedDay: day)
        // Keep the user's words exactly; only a time or date written at the start of the line is taken out of the
        // title ("15:00 开会"). One in the middle of the sentence ("订周五的票") is part of the words.
        let leads = !parsed.title.trimmed.isEmpty && text.trimmed.hasSuffix(parsed.title.trimmed)
        if !leads {
            parsed.title = text.trimmed
            parsed.schedule = day.dayOnly
            parsed.endMinute = nil
        }
        let minute = parsed.schedule?.hour.map { $0 * 60 + (parsed.schedule?.minute ?? 0) }
        let tookTime = parsed.title != text.trimmed
        let title = tookTime && !parsed.title.trimmed.isEmpty ? parsed.title.trimmed : text.trimmed
        switch line.kind {
        case .task:
            guard let task = tasks.first(where: { $0.id.uuidString == line.id }) else { return }
            // "每天…" at the start or "… #每天" at the end: the item becomes a repeating one, from this day on.
            if let rule = RoutineParser.parse(text, clock: pageClock(day)),
               !tasks.contains(where: { $0.parentID == task.id }) {
                makeRoutine(from: task, rule: rule, day: day)
                return
            }
            var schedule = task.schedule ?? day
            if let date = parsed.schedule, date.day != nil, date.dayOnly != day { schedule = date }
            else {
                schedule = day.dayOnly
                schedule.hour = minute.map { $0 / 60 }
                schedule.minute = minute.map { $0 % 60 }
            }
            let end = minute == nil ? nil : parsed.endMinute
            guard task.title != title || task.schedule != schedule || task.endMinute != end || task.parentID != parent else { return }
            task.title = title
            task.schedule = schedule
            task.endMinute = end
            task.parentID = parent
            persist()
            if schedule.dayOnly != day { announce(String(localized: "「\(title)」移到了 \(friendlyDay(schedule.dayOnly))")) }
        case .routine:
            // Editing a repeating line changes it on every day. A repeat rule written at its start
            // ("每周一三五 深蹲", "工作日 7:30 跑步") changes which days it repeats on.
            guard let instance = routineInstance(line.id, day: day) else { return }
            let routine = instance.routine
            if let rule = RoutineParser.parse(text, clock: pageClock(day)) {
                guard routine.title != rule.title || routine.startMinute != rule.startMinute || routine.weekdays != rule.weekdays
                        || routine.endMinute != rule.endMinute || routine.monthDay != rule.monthDay else { return }
                routine.title = rule.title
                routine.weekdays = rule.weekdays
                routine.monthDay = rule.monthDay
                routine.startMinute = rule.startMinute
                routine.endMinute = rule.endMinute
                persist()
                announce(String(localized: "「\(rule.title)」改成\(RoutineParser.label(rule.weekdays, monthDay: rule.monthDay))"))
                return
            }
            guard routine.title != title || routine.startMinute != minute else { return }
            routine.title = title
            routine.startMinute = minute
            routine.endMinute = minute == nil ? nil : parsed.endMinute
            persist()
        case .event, .occasion, .archive:
            return
        }
    }

    // MARK: Floating bar and dictation

    private func toggleBarVoice() {
        if barRecording {
            barRecording = false
            barTranscribing = true
            Task {
                defer { barTranscribing = false }
                do {
                    let heard = try await voice.finish(locale: Locale(identifier: voiceLocale))
                    barText = barText.trimmed.isEmpty ? heard : barText.trimmed + "，" + heard
                } catch {
                    announce(error.localizedDescription)
                }
            }
        } else {
            guard !voice.recording, !voice.processing else { return }
            Task {
                do {
                try await voice.start()
                    barRecording = true
                } catch {
                    announce(error.localizedDescription)
                }
            }
        }
    }

    private var barCommand: PlannerCommand? {
        barText.trimmed.isEmpty ? nil : PlannerCommand.parse(barText, clock: clock, defaultDay: clock.today)
    }

    /// The bar files what was said or typed, by the rules. Commands run directly.
    private func submitBar() {
        guard !barRecording, !barTranscribing, !barText.trimmed.isEmpty else { return }
        let text = barText
        #if os(iOS)
        // With Apple Intelligence, the assistant reads it (commands like "删掉看房" still go straight to the rules).
        if PhoneAssistant.isAvailable && barCommand == nil {
            barText = ""
            closeBar()
            Task { await askAssistant(text) }
            return
        }
        #endif
        if commitDictation(text, defaultDay: clock.today) != nil {
            barText = ""
            #if os(iOS)
            // Sent: the keyboard gets out of the way so the item can be seen landing on its day.
            closeBar()
            #endif
        }
    }

    #if os(iOS)
    /// Puts the keyboard away and folds the bar back (what was typed stays as a draft).
    private func closeBar() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { barOpen = false }
    }
    #endif

    /// Hands what was typed or said to the on-device assistant; everything it changed can be undone in one tap.
    /// If it can't help (unavailable, or it fails), the rules file the text as before.
    private func askAssistant(_ text: String) async {
        let commands = assistantCommands ?? AgentCommands(context: context)
        assistantCommands = commands
        assistantWorking = true
        defer { assistantWorking = false }
        do {
            let (summary, depth) = try await PhoneAssistant.handle(text, commands: commands)
            if commands.undoDepth > depth {
                announce(summary.isEmpty ? String(localized: "已记下") : summary) { commands.undo(to: depth) }
            } else if !summary.isEmpty {
                // Nothing changed (a question, say): its answer is the reply.
                announce(summary)
            }
        } catch {
            _ = commitDictation(text, defaultDay: clock.today)
        }
    }

    /// Adds plain text to the end of a day's page.
    private func appendNote(_ text: String, day: PlanDate) {
        let existing = pageData(day).flatMap {
            try? NSAttributedString(data: $0, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
        }
        let page = NSMutableAttributedString(attributedString: existing ?? NSAttributedString())
        if page.length > 0, !page.string.hasSuffix("\n") { page.append(NSAttributedString(string: "\n")) }
        page.append(NSAttributedString(string: text + "\n", attributes: [.font: PlatformFont.systemFont(ofSize: 15),
                                                                          .foregroundColor: PlatformColor(theme.ink)]))
        let data = try? page.data(from: NSRange(location: 0, length: page.length),
                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        savePage(data, day: day)
    }

    /// Files a typed or spoken run of text: each clause becomes its own item on its own day (today when none is said),
    /// "每天…/每周…" clauses become routines. Items that need a decision (reminders, calendar events, vague dates) go to review.
    @discardableResult
    private func commitDictation(_ text: String, defaultDay: PlanDate, parent: UUID? = nil) -> (text: String, needsReview: Bool)? {
        if let command = PlannerCommand.parse(text, clock: clock, defaultDay: defaultDay) {
            return run(command).map { ($0, false) }
        }
        let items = Dictation.items(text, clock: clock, defaultDay: defaultDay)
        guard !items.isEmpty else { return nil }
        var added: [TaskRecord] = []
        var newRoutines: [RoutineRecord] = []
        var review: [CaptureDraft] = []
        for item in items {
            switch item {
            case .task(let draft) where draft.requiresReview:
                review.append(draft)
            case .task(let draft):
                let task = TaskRecord(id: draft.id, title: draft.title, schedule: draft.schedule, endMinute: draft.endMinute)
                task.sourceText = draft.original == draft.title ? nil : draft.original
                if let parent, let owner = tasks.first(where: { $0.id == parent }),
                   owner.schedule?.dayOnly == draft.schedule?.dayOnly {
                    task.parentID = parent
                }
                added.append(task)
            case .routine(let draft):
                newRoutines.append(RoutineRecord(title: draft.title, weekdays: draft.weekdays, monthDay: draft.monthDay, startMinute: draft.startMinute,
                                                 endMinute: draft.endMinute, startDay: clock.today.key,
                                                 order: (routines.map(\.order).max() ?? 0) + 1 + newRoutines.count))
            }
        }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) {
            added.forEach(context.insert)
            newRoutines.forEach(context.insert)
            persist()
        }
        if !review.isEmpty {
            queue.append(contentsOf: review)
            advanceReview()
        }
        let count = added.count + newRoutines.count
        let text: String
        if count == 1, let task = added.first {
            text = String(localized: "已记下 · ") + heardLabel(CaptureDraft(title: task.title, original: task.title, schedule: task.schedule))
        } else if count == 1, let routine = newRoutines.first {
            text = String(localized: "已加入每日 · \(routine.ruleLabel) \(routine.title)")
        } else if count > 1 {
            let days = Set(added.compactMap { $0.schedule?.dayOnly.key }).count
            text = String(localized: "已记下 \(count) 件") + (days > 1 ? String(localized: "，分到 \(days) 天") : "") + (newRoutines.isEmpty ? "" : String(localized: "（含 \(newRoutines.count) 个每日）"))
        } else {
            text = String(localized: "请确认这条怎么记")
        }
        if count > 0 {
            announce(text) {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) {
                    added.forEach(context.delete)
                    newRoutines.forEach(context.delete)
                    persist()
                }
            }
        }
        return (text, !review.isEmpty)
    }

    /// Files a free-form page: lines become items, indentation becomes subtasks, "每天…" becomes a routine.
    /// A single line that is an instruction ("把理发挪到周二") runs as a command instead.
    @discardableResult
    private func commitDraft(_ text: String, defaultDay: PlanDate, styles: [String?] = [], keptNotes: Int = 0) -> String? {
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmed.isEmpty }
        if lines.count == 1, let command = PlannerCommand.parse(text, clock: clock, defaultDay: defaultDay) {
            return run(command)
        }
        let outline = Dictation.outline(text, clock: clock, defaultDay: defaultDay)
        guard !outline.isEmpty else { return nil }
        var added: [TaskRecord] = []
        var newRoutines: [RoutineRecord] = []
        var review: [CaptureDraft] = []
        let baseOrder = routines.map(\.order).max() ?? 0
        func file(_ node: OutlineItem, parent: UUID?) {
            switch node.item {
            case .task(let draft) where draft.requiresReview && parent == nil:
                review.append(draft)
                return
            case .task(let draft):
                let task = TaskRecord(id: draft.id, title: draft.title, schedule: draft.schedule, endMinute: draft.endMinute)
                task.sourceText = draft.original == draft.title ? nil : draft.original
                task.parentID = parent
                if styles.indices.contains(node.line) { task.titleStyle = styles[node.line] }
                added.append(task)
                node.children.forEach { file($0, parent: task.id) }
            case .routine(let draft):
                newRoutines.append(RoutineRecord(title: draft.title, weekdays: draft.weekdays, monthDay: draft.monthDay, startMinute: draft.startMinute,
                                                 endMinute: draft.endMinute, startDay: clock.today.key,
                                                 order: baseOrder + 1 + newRoutines.count))
            }
        }
        outline.forEach { file($0, parent: nil) }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) {
            added.forEach(context.insert)
            newRoutines.forEach(context.insert)
            persist()
        }
        if !review.isEmpty {
            queue.append(contentsOf: review)
            advanceReview()
        }
        let count = added.count + newRoutines.count
        guard count > 0 else { return review.isEmpty ? nil : String(localized: "请确认这条怎么记") }
        let elsewhere = Set(added.compactMap { $0.schedule?.dayOnly }).subtracting([defaultDay.dayOnly]).count
        let text = String(localized: "已整理成 \(count) 件") + (elsewhere > 0 ? String(localized: "，其中 \(elsewhere) 天在别处") : "")
            + (newRoutines.isEmpty ? "" : String(localized: "，\(newRoutines.count) 个每日"))
            + (keptNotes > 0 ? String(localized: "，\(keptNotes) 行笔记留在页面") : "")
        announce(text) {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) {
                added.forEach(context.delete)
                newRoutines.forEach(context.delete)
                persist()
            }
        }
        return text
    }

    // MARK: Commands ("把理发挪到明天下午三点", "删掉看房", "健身做完了")

    /// What a command would do, for the bar's preview. Nil when it matches nothing.
    private func describe(_ command: PlannerCommand) -> String? {
        guard let task = commandTarget(command) else { return String(localized: "没找到「\(command.target)」") }
        switch command {
        case .move(_, let date, _):
            let time = date.hour.map { String(format: " %02d:%02d", $0, date.minute ?? 0) } ?? ""
            return String(localized: "把「\(task.title)」移到 \(friendlyDay(date.dayOnly))\(time)")
        case .delete: return String(localized: "删除「\(task.title)」")
        case .complete: return String(localized: "完成「\(task.title)」")
        case .rename(_, let title): return String(localized: "「\(task.title)」改名为「\(title)」")
        }
    }

    private func commandTarget(_ command: PlannerCommand) -> TaskRecord? {
        let candidates = localItems.filter { !$0.calendarLinked && ($0.completed == false || {
            if case .delete = command { return true } else { return false }
        }()) }
        return PlannerCommand.bestMatch(command.target, among: candidates, title: \.title,
                                        day: \.schedule, today: clock.today)
    }

    private func run(_ command: PlannerCommand) -> String? {
        guard let task = commandTarget(command) else {
            announce(String(localized: "没找到「\(command.target)」"))
            return nil
        }
        switch command {
        case .move(_, let date, let end):
            let previous = (task.schedule, task.endMinute)
            var target = date
            if target.hour == nil, target.day != nil { target.hour = task.schedule?.hour; target.minute = task.schedule?.minute }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                task.schedule = target
                task.endMinute = date.hour == nil ? task.endMinute : end
                task.carriedFrom = nil
                for child in family(of: task).dropFirst() { child.schedule = Self.place(child.schedule, on: target.dayOnly) }
                persist()
            }
            let time = target.hour.map { String(format: " %02d:%02d", $0, target.minute ?? 0) } ?? ""
            let text = String(localized: "「\(task.title)」已移到 \(friendlyDay(target.dayOnly))\(time)")
            announce(text) {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                    task.schedule = previous.0
                    task.endMinute = previous.1
                    persist()
                }
            }
            return text
        case .delete:
            deleteTask(task)
            return String(localized: "已删除「\(task.title)」")
        case .complete:
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { task.completed = true; persist() }
            let text = String(localized: "已完成「\(task.title)」")
            announce(text) { task.completed = false; persist() }
            return text
        case .rename(_, let title):
            let old = task.title
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { task.title = title; persist() }
            let text = String(localized: "「\(old)」改名为「\(title)」")
            announce(text) { task.title = old; persist() }
            return text
        }
    }

    // MARK: Routines

    private func routineInstances(on day: PlanDate) -> [RoutineInstance] {
        routineInstances(on: day, marks: Dictionary(routineMarks.map { ($0.routineID.uuidString + "|" + $0.dayKey, $0) },
                                                    uniquingKeysWith: { first, _ in first }))
    }

    private func routineInstances(on day: PlanDate, marks: [String: RoutineMark]) -> [RoutineInstance] {
        let calendar = clock.calendar
        return routines.filter { $0.applies(to: day, calendar: calendar) }.compactMap { routine in
            let mark = marks[routine.id.uuidString + "|" + day.key]
            if mark?.skipped == true { return nil }
            return RoutineInstance(routine: routine, day: day, done: mark != nil)
        }
        .sorted { ($0.routine.startMinute ?? 9999, $0.routine.order) < ($1.routine.startMinute ?? 9999, $1.routine.order) }
    }

    /// Routines sit in the day like any other item, in time order, marked with a small "每天"/"每周…" tag.
    private func merged(_ entries: [TimelineEntry], routinesOn day: PlanDate) -> [TimelineEntry] {
        let calendar = clock.calendar
        let daily = routineInstances(on: day).map { instance -> TimelineEntry in
            let routine = instance.routine
            let start = routine.startMinute.flatMap { minute -> Date? in
                var at = day.dayOnly
                at.hour = minute / 60
                at.minute = minute % 60
                return at.date(in: calendar)
            }
            return TimelineEntry(id: "routine-\(routine.id.uuidString)-\(day.key)", title: routine.title, detail: "",
                                 start: start, end: routine.endMinute.flatMap { endDate(day, minute: $0) },
                                 completed: instance.done, toggle: { toggleRoutine(instance) },
                                 edit: { editingRoutine = routine },
                                 timeEdit: TimelineTimeEdit(selection: .init(start: routine.startMinute, end: routine.endMinute)) {
                                     try saveRoutineTime(routine, $0)
                                 },
                                 delete: { skipRoutine(instance) },
                                 rename: { updateRoutine(routine, title: $0, weekdays: routine.weekdays) },
                                 tag: routine.ruleLabel,
                                 editTag: { editingRoutine = routine })
        }
        guard !daily.isEmpty else { return entries }
        let timed = (entries + daily).filter { $0.start != nil }.sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
        let untimed = daily.filter { $0.start == nil } + entries.filter { $0.start == nil }
        return timed + untimed
    }

    private func routineMark(_ instance: RoutineInstance) -> RoutineMark? {
        routineMarks.first { $0.routineID == instance.routine.id && $0.dayKey == instance.day.key }
    }

    private func toggleRoutine(_ instance: RoutineInstance) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) {
            // Done → not done; anything else (nothing, or skipped) → done.
            let wasDone = instance.done
            if let mark = routineMark(instance) { context.delete(mark) }
            if !wasDone { context.insert(RoutineMark(routineID: instance.routine.id, dayKey: instance.day.key, skipped: false)) }
            persist()
        }
    }

    private func skipRoutine(_ instance: RoutineInstance) {
        if let mark = routineMark(instance) { context.delete(mark) }
        let skip = RoutineMark(routineID: instance.routine.id, dayKey: instance.day.key, skipped: true)
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
            context.insert(skip)
            persist()
        }
        announce(String(localized: "「\(instance.routine.title)」这天跳过")) {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                context.delete(skip)
                persist()
            }
        }
    }

    private func saveRoutineTime(_ routine: RoutineRecord, _ selection: PlannerTimeSelection) throws {
        routine.startMinute = selection.start
        routine.endMinute = selection.start == nil ? nil : selection.end
        do { try context.save() }
        catch { context.rollback(); throw error }
    }

    private func updateRoutine(_ routine: RoutineRecord, title: String, weekdays: Set<Int>) {
        routine.title = title
        routine.weekdays = weekdays
        persist()
    }

    /// A repeating item stops from a given day on (deleted from that day's page). The notice can undo it, or
    /// turn it into skipping just that day.
    private func stopRoutine(_ routine: RoutineRecord, from day: PlanDate, instance: RoutineInstance) {
        let title = routine.title
        let key = day.dayOnly.key
        let label = String(localized: "\(day.month)月\(day.day ?? 1)日")
        if routine.startDay >= key {
            let snapshot = (title: routine.title, weekdays: routine.weekdays, monthDay: routine.monthDay, start: routine.startMinute,
                            end: routine.endMinute, startDay: routine.startDay, order: routine.order, id: routine.id)
            context.delete(routine)
            persist()
            let bringBack = {
                let restored = RoutineRecord(title: snapshot.title, weekdays: snapshot.weekdays, monthDay: snapshot.monthDay, startMinute: snapshot.start,
                                             endMinute: snapshot.end, startDay: snapshot.startDay, order: snapshot.order)
                restored.id = snapshot.id
                context.insert(restored)
                persist()
            }
            announce(String(localized: "「\(title)」不再重复"), undo: bringBack)
        } else {
            let previous = routine.endDay
            routine.endDay = key
            persist()
            announce(String(localized: "「\(title)」从\(label)起不再重复"), undo: {
                routine.endDay = previous
                persist()
            }, other: (label: String(localized: "只跳过这天"), action: {
                routine.endDay = previous
                persist()
                skipRoutine(instance)
            }))
        }
    }

    private func stopRoutine(_ routine: RoutineRecord) {
        let today = clock.today.key
        let title = routine.title
        if routine.startDay >= today {
            let snapshot = (title: routine.title, weekdays: routine.weekdays, monthDay: routine.monthDay, start: routine.startMinute,
                            end: routine.endMinute, startDay: routine.startDay, order: routine.order)
            context.delete(routine)
            persist()
            announce(String(localized: "「\(title)」不再重复")) {
                context.insert(RoutineRecord(title: snapshot.title, weekdays: snapshot.weekdays, monthDay: snapshot.monthDay, startMinute: snapshot.start,
                                             endMinute: snapshot.end, startDay: snapshot.startDay, order: snapshot.order))
                persist()
            }
        } else {
            routine.endDay = today
            persist()
            announce(String(localized: "「\(title)」从今天起不再重复")) {
                routine.endDay = nil
                persist()
            }
        }
    }

    private func deleteAction(_ task: TaskRecord) -> (() -> Void)? { task.calendarLinked ? nil : { deleteTask(task) } }
    private func renameAction(_ task: TaskRecord) -> ((String) -> Void)? { task.calendarLinked ? nil : { renameTask(task, $0) } }
    private func routineAction(_ task: TaskRecord) -> (() -> Void)? {
        task.calendarLinked || task.parentID != nil ? nil : { makeRoutine(from: task) }
    }

    private func makeRoutine(from task: TaskRecord) {
        let start = task.schedule?.hour.map { $0 * 60 + (task.schedule?.minute ?? 0) }
        let routine = RoutineRecord(title: task.title, weekdays: Set(1...7), startMinute: start,
                                    endMinute: start == nil ? nil : task.endMinute,
                                    startDay: (task.schedule?.dayOnly ?? clock.today).key,
                                    order: (routines.map(\.order).max() ?? 0) + 1)
        let snapshot = (id: task.id, title: task.title, schedule: task.schedule, end: task.endMinute, created: task.createdAt)
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
            context.insert(routine)
            context.delete(task)
            persist()
        }
        announce(String(localized: "「\(snapshot.title)」设为每天重复，点它旁边的「每天」可以改")) {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
                context.delete(routine)
                let restored = TaskRecord(id: snapshot.id, title: snapshot.title, schedule: snapshot.schedule,
                                          endMinute: snapshot.end)
                restored.createdAt = snapshot.created
                context.insert(restored)
                persist()
            }
        }
    }

    /// An item turned into a repeating one (its line got a repeat rule). Undo brings the item back.
    private func makeRoutine(from task: TaskRecord, rule: RoutineDraft, day: PlanDate) {
        let routine = RoutineRecord(title: rule.title, weekdays: rule.weekdays, monthDay: rule.monthDay, startMinute: rule.startMinute,
                                    endMinute: rule.endMinute, startDay: day.dayOnly.key,
                                    order: (routines.map(\.order).max() ?? 0) + 1)
        let snapshot = (id: task.id, title: task.title, schedule: task.schedule, end: task.endMinute, created: task.createdAt)
        context.insert(routine)
        context.delete(task)
        persist()
        announce(String(localized: "「\(rule.title)」改成\(RoutineParser.label(rule.weekdays, monthDay: rule.monthDay))重复")) {
            context.delete(routine)
            let back = TaskRecord(id: snapshot.id, title: snapshot.title, note: "", schedule: snapshot.schedule, endMinute: snapshot.end)
            back.createdAt = snapshot.created
            context.insert(back)
            persist()
        }
    }

    private func addRoutine(_ text: String) -> Bool {
        let source = text.trimmed
        guard !source.isEmpty else { return false }
        // Typed into the 每日 field, plain text means every day.
        let draft = RoutineParser.parse(source, clock: clock) ?? RoutineParser.parse("每天" + source, clock: clock)
        guard let draft else { return false }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
            context.insert(RoutineRecord(title: draft.title, weekdays: draft.weekdays, monthDay: draft.monthDay, startMinute: draft.startMinute,
                                         endMinute: draft.endMinute, startDay: clock.today.key,
                                         order: (routines.map(\.order).max() ?? 0) + 1))
            persist()
        }
        return true
    }

    // MARK: Delete, roll-over, focus

    /// A task and all its subtasks, parent first.
    private func family(of task: TaskRecord) -> [TaskRecord] {
        var result = [task]
        var index = 0
        while index < result.count, result.count < 200 {
            let parent = result[index].id
            result += tasks.filter { $0.parentID == parent && !result.contains($0) }
            index += 1
        }
        return result
    }

    /// Ways to bring back items deleted this session, by id (see deleteTask).
    @MainActor private static var deletedStore: [UUID: () -> Void] = [:]
    private var deletedTasks: [UUID: () -> Void] {
        get { Self.deletedStore }
        nonmutating set { Self.deletedStore = newValue }
    }

    private func deleteTask(_ task: TaskRecord) {
        let removed = family(of: task)
        let snapshots = removed.map { item in
            (id: item.id, title: item.title, note: item.note, schedule: item.schedule, endMinute: item.endMinute,
             completed: item.completed, source: item.sourceText, carried: item.carriedFrom, created: item.createdAt,
             parent: item.parentID)
        }
        let title = task.title
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
            removed.forEach(context.delete)
            persist()
        }
        // Kept so ⌘Z on the page (which brings the deleted line back) can bring the item back too.
        deletedTasks[task.id] = { [self] in
            for restore in snapshots where !tasks.contains(where: { $0.id == restore.id }) {
                let task = TaskRecord(id: restore.id, title: restore.title, note: restore.note,
                                      schedule: restore.schedule, endMinute: restore.endMinute)
                task.completed = restore.completed
                task.sourceText = restore.source
                task.carriedFrom = restore.carried
                task.createdAt = restore.created
                task.parentID = restore.parent
                context.insert(task)
            }
            persist()
        }
        announce(String(localized: "已删除「\(title)」") + (removed.count > 1 ? String(localized: "和 \(removed.count - 1) 个子任务") : "")) {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                for restore in snapshots where !tasks.contains(where: { $0.id == restore.id }) {
                    let task = TaskRecord(id: restore.id, title: restore.title, note: restore.note,
                                          schedule: restore.schedule, endMinute: restore.endMinute)
                    task.completed = restore.completed
                    task.sourceText = restore.source
                    task.carriedFrom = restore.carried
                    task.createdAt = restore.created
                    task.parentID = restore.parent
                    context.insert(task)
                }
                persist()
            }
        }
    }

    // MARK: Subtasks

    /// Puts subtasks right under their parent (indented), keeping everything else in time order.
    private func nested(_ entries: [TimelineEntry]) -> [TimelineEntry] {
        let byID = Dictionary(tasks.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        let present = Set(entries.map(\.id))
        var children: [String: [TimelineEntry]] = [:]
        var roots: [TimelineEntry] = []
        for entry in entries {
            if let parent = byID[entry.id]?.parentID?.uuidString, present.contains(parent) {
                children[parent, default: []].append(entry)
            } else {
                roots.append(entry)
            }
        }
        var ordered: [TimelineEntry] = []
        func visit(_ entry: TimelineEntry, depth: Int) {
            var item = entry
            item.depth = min(depth, 2)
            ordered.append(item)
            for child in children[entry.id] ?? [] where ordered.count < 500 { visit(child, depth: depth + 1) }
        }
        roots.forEach { visit($0, depth: 0) }
        // Tab: become a child of the nearest line above at the same level. Shift-Tab: move up a level.
        for index in ordered.indices {
            guard let task = byID[ordered[index].id], !task.calendarLinked else { continue }
            let depth = ordered[index].depth
            if depth < 2, let above = ordered[..<index].last(where: { $0.depth <= depth }),
               above.depth == depth, let parent = byID[above.id] {
                ordered[index].indent = { setParent(task, parent.id) }
            }
            if task.parentID != nil {
                let grand = task.parentID.flatMap { id in tasks.first { $0.id == id } }?.parentID
                ordered[index].outdent = { setParent(task, grand) }
            }
        }
        return ordered
    }

    private func setParent(_ task: TaskRecord, _ parent: UUID?) {
        guard parent != task.id else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) {
            task.parentID = parent
            persist()
        }
    }

    private func renameTask(_ task: TaskRecord, _ title: String) {
        // Typing a time into the title ("理发 下午三点") also sets the time, the same as when capturing.
        let parsed = CaptureParser.manual(title, clock: clock, selectedDay: task.schedule?.dayOnly)
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) {
            if let schedule = parsed.schedule, schedule.hour != nil, parsed.title != title, !task.calendarLinked {
                task.title = Dictation.cleanTitle(parsed.title)
                task.schedule = schedule
                task.endMinute = parsed.endMinute
            } else {
                task.title = title
            }
            persist()
        }
    }

    /// Unfinished tasks from the past month move to today, remembering the day they were planned for.
    /// Imported history, calendar-linked items and month-level plans stay where they are.
    private func rollOverdueTasks() {
        let calendar = clock.calendar
        let today = clock.today
        guard let start = today.date(in: calendar),
              let floorDate = calendar.date(byAdding: .day, value: -30, to: start) else { return }
        let floor = PlanDate.from(floorDate, calendar: calendar)
        var moved = 0
        // Something already on today with the same words isn't rolled again (no duplicate "做 rebuttal").
        var todayTitles = Set(tasks.filter { $0.schedule?.dayOnly == today }.map { $0.title.trimmed.lowercased() })
        for task in tasks where !task.completed && task.importKey == nil && !task.calendarLinked
            && task.pendingReminder == nil {
            guard let plan = task.schedule, plan.day != nil else { continue }
            let day = plan.dayOnly
            guard day < today, day >= floor else { continue }
            // An appointment at a time that has passed isn't a to-do left undone.
            guard plan.hour == nil else { continue }
            guard todayTitles.insert(task.title.trimmed.lowercased()).inserted else { continue }
            if task.carriedFrom == nil { task.carriedFrom = day.key }
            task.schedule = today
            task.endMinute = nil
            moved += 1
        }
        guard moved > 0 else { return }
        persist()
        announce(String(localized: "\(moved) 件没做完的事已顺延到今天"))
    }

    /// Where today stands: the next timed thing, and how much is done. Shown in today's heading (progress)
    /// and in the floating 今天 pill (next) — no separate strip.
    private var todayStatus: (next: String?, done: Int, total: Int, carried: Int) {
        let today = clock.today
        let now = clock.now
        let calendar = clock.calendar
        let open = localItems.filter { !$0.completed && $0.schedule?.dayOnly == today }
        let reminders = system.reminders.filter { !$0.completed && $0.schedule?.dayOnly == today }
        let events = (journalEvents.days[today] ?? []).filter { $0.importantKind == nil && !$0.allDay && $0.end > now }
        var upcoming: [(Date, String)] = events.map { ($0.start, $0.title) }
        upcoming += open.compactMap { task in task.schedule?.hour == nil ? nil : task.schedule?.date(in: calendar).map { ($0, task.title) } }
            .filter { $0.0 > now.addingTimeInterval(-30 * 60) }
        upcoming += reminders.compactMap { task in task.schedule?.hour == nil ? nil : task.schedule?.date(in: calendar).map { ($0, task.title) } }
            .filter { $0.0 > now.addingTimeInterval(-30 * 60) }
        upcoming += routineInstances(on: today).filter { !$0.done }.compactMap { instance in
            guard let minute = instance.routine.startMinute, var day = Optional(today) else { return nil }
            day.hour = minute / 60
            day.minute = minute % 60
            return day.date(in: calendar).map { ($0, instance.routine.title) }
        }.filter { $0.0 > now.addingTimeInterval(-30 * 60) }
        let next = upcoming.min { $0.0 < $1.0 }
        let carried = open.filter { $0.carriedFrom != nil }.count
        let daily = routineInstances(on: today)
        // Everything planned for today, done or not, so the line can say plainly where the day stands.
        let allTasks = localItems.filter { $0.schedule?.dayOnly == today && !$0.calendarLinked }
        let allReminders = system.reminders.filter { $0.schedule?.dayOnly == today }
        let total = allTasks.count + allReminders.count + daily.count
        let done = allTasks.filter(\.completed).count + allReminders.filter(\.completed).count + daily.filter(\.done).count
        _ = carried
        let nextLabel = next.map { DayTimeline.time($0.0, calendar: calendar) + " " + $0.1 }
        return (nextLabel, done, total, carried)
    }

    // MARK: Drag to reschedule

    /// Handles a drop on a day: ASMO items move there, plain text from elsewhere becomes tasks on that day.
    private func dropOnDay(_ payloads: [String], day: PlanDate) -> Bool {
        let target = day.dayOnly
        let moved = payloads.compactMap(PlannerDrag.id(from:))
        if !moved.isEmpty {
            for id in moved { moveItem(id, to: target) }
            return true
        }
        let titles = payloads.flatMap(PlannerDrag.titles(from:))
        guard !titles.isEmpty else { return false }
        let added = titles.map { TaskRecord(title: $0, schedule: target) }
        added.forEach(context.insert)
        persist()
        announce(String(localized: "已添加 \(added.count) 条到 \(target.month) 月 \(target.day ?? 1) 日")) {
            added.forEach(context.delete)
            persist()
        }
        return true
    }

    private func moveItem(_ id: String, to day: PlanDate, undoable: Bool = true) {
        if let uuid = UUID(uuidString: id), let task = tasks.first(where: { $0.id == uuid }) {
            moveLocal(task, to: day, undoable: undoable)
        } else if let reminder = system.reminders.first(where: { $0.id == id }) {
            moveReminder(reminder, to: day, undoable: undoable)
        } else if let event = journalEvents.days.values.joined().first(where: { $0.id == id })
                    ?? monthEvents.days.values.joined().first(where: { $0.id == id }) {
            moveEvent(event, to: day, undoable: undoable)
        }
    }

    private func moveLocal(_ task: TaskRecord, to day: PlanDate, undoable: Bool) {
        guard !task.calendarLinked else {
            announce(String(localized: "这条正在与日历同步，稍后再拖动"))
            return
        }
        let previous = task.schedule
        guard previous?.dayOnly != day else { return }
        // Subtasks travel with their parent.
        let moving = family(of: task).filter { !$0.calendarLinked }
        let before = moving.map { ($0, $0.schedule) }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
            for item in moving { item.schedule = Self.place(item.schedule ?? previous, on: day) }
            persist()
        }
        guard undoable else { return }
        announce(String(localized: "「\(task.title)」已移到 \(friendlyDay(day))")) {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                for (item, schedule) in before { item.schedule = schedule }
                persist()
            }
        }
    }

    private func moveReminder(_ reminder: SystemTask, to day: PlanDate, undoable: Bool) {
        guard let previous = reminder.schedule, previous.dayOnly != day || previous.day == nil else { return }
        let from = previous.dayOnly
        var alert = reminder.alertAt
        if let current = alert, previous.day != nil, let delta = dayDelta(from, day) {
            alert = clock.calendar.date(byAdding: .day, value: delta, to: current)
        }
        if let value = alert, value <= .now { alert = nil }
        Task {
            await report {
                try await system.editReminder(reminder, title: reminder.title, note: reminder.note,
                                              schedule: Self.place(previous, on: day),
                                              endMinute: reminder.endMinute, alert: alert)
            }
            guard undoable, previous.day != nil else { return }
            announce(String(localized: "「\(reminder.title)」已移到 \(movedLabel(day))")) {
                moveItem(reminder.id, to: from, undoable: false)
            }
        }
    }

    private func moveEvent(_ event: SystemEvent, to day: PlanDate, undoable: Bool) {
        let calendar = clock.calendar
        let from = PlanDate.from(event.start, calendar: calendar)
        guard event.writable, let delta = dayDelta(from, day), delta != 0,
              let start = calendar.date(byAdding: .day, value: delta, to: event.start),
              let end = calendar.date(byAdding: .day, value: delta, to: event.end) else { return }
        let linked = event.asmoID.flatMap { id in tasks.first { $0.id == id && $0.calendarLinked } }
        Task {
            do {
                try await system.saveEvent(id: event.asmoID ?? UUID(), title: event.title, start: start, end: end,
                                           allDay: event.allDay, note: event.note, alertLead: event.alertLead,
                                           existing: event)
            } catch {
                self.error = error.localizedDescription
                return
            }
            if let linked {
                linked.schedule = Self.place(linked.schedule, on: day)
                linked.linkedEventStart = start
                persist()
            }
            await refresh()
            guard undoable else { return }
            // EventKit snapshots are keyed by item identifier plus start, so rebuild the moved snapshot for undo.
            let suffix = "-\(event.start.timeIntervalSinceReferenceDate)"
            guard event.id.hasSuffix(suffix) else { return }
            let movedID = String(event.id.dropLast(suffix.count)) + "-\(start.timeIntervalSinceReferenceDate)"
            let moved = SystemEvent(id: movedID, asmoID: event.asmoID, title: event.title, note: event.note,
                                    calendarID: event.calendarID, calendarTitle: event.calendarTitle,
                                    writable: event.writable, start: start, end: end, allDay: event.allDay,
                                    alertLead: event.alertLead, importantKind: event.importantKind)
            announce(String(localized: "「\(event.title)」已移到 \(movedLabel(day))")) {
                moveEvent(moved, to: from, undoable: false)
            }
        }
    }

    /// Keeps the time of day (if any) and moves the date.
    private static func place(_ schedule: PlanDate?, on day: PlanDate) -> PlanDate {
        var placed = day.dayOnly
        placed.hour = schedule?.hour
        placed.minute = schedule?.minute
        return placed
    }

    private func dayDelta(_ from: PlanDate, _ to: PlanDate) -> Int? {
        guard let start = from.dayOnly.date(in: clock.calendar), let end = to.dayOnly.date(in: clock.calendar) else { return nil }
        return clock.calendar.dateComponents([.day], from: start, to: end).day
    }

    private func movedLabel(_ day: PlanDate) -> String {
        let today = clock.today
        if day == today { return String(localized: "今天") }
        if dayDelta(today, day) == 1 { return String(localized: "明天") }
        return String(localized: "\(day.month) 月 \(day.day ?? 1) 日 \(journalWeekday(day))")
    }

    private func friendlyDay(_ day: PlanDate) -> String {
        guard let delta = dayDelta(clock.today, day) else { return day.label }
        switch delta {
        case 0: return String(localized: "今天")
        case 1: return String(localized: "明天")
        case 2: return String(localized: "后天")
        case -1: return String(localized: "昨天")
        default:
            let weekday = journalWeekday(day)
            guard let today = clock.today.date(in: clock.calendar), let target = day.date(in: clock.calendar) else { return day.label }
            let thisWeek = clock.calendar.isDate(today, equalTo: target, toGranularity: .weekOfYear)
            if delta > 0 && thisWeek { return weekday }
            if delta > 0 && delta < 14, let next = clock.calendar.date(byAdding: .weekOfYear, value: 1, to: today),
               clock.calendar.isDate(next, equalTo: target, toGranularity: .weekOfYear) {
                return String(localized: "下\(weekday) \(day.month)/\(day.day ?? 1)")
            }
            return "\(day.month)/\(day.day ?? 1) \(weekday)"
        }
    }

    private func announce(_ text: String, undo: (() -> Void)? = nil, other: (label: String, action: () -> Void)? = nil) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
            notice = PlannerNotice(text: text, undo: undo, other: other)
        }
    }

    private func quickAddToCalendar(_ title: String, _ day: PlanDate) throws {
        context.insert(TaskRecord(title: title, schedule: day.dayOnly))
        do { try context.save() }
        catch { context.rollback(); throw error }
    }

    private func desktopCalendarItems(_ month: CalendarMonth, calendar: Calendar) -> [PlanDate: [CalendarDayItem]] {
        #if DEBUG
        let started = Date.now
        defer { PerfLog.note("calendarItems", since: started) }
        #endif
        let clock = self.clock
        let scheduled = Dictionary(grouping: localItems.filter { $0.schedule?.day != nil }) { $0.schedule?.dayOnly }
        let reminders = Dictionary(grouping: system.reminders.filter { $0.schedule?.day != nil }) { $0.schedule?.dayOnly }
        let recordedNotes = Dictionary(grouping: notes.filter { !$0.body.trimmed.isEmpty }, by: \.dayKey)
        let edits = Dictionary(journalEdits.map { ($0.recordKey, $0.body) }, uniquingKeysWith: { newest, _ in newest })
        let promoted = Set(tasks.compactMap(\.importKey))
        let linkedTasks = Dictionary(tasks.lazy.filter(\.calendarLinked).map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
        let fixedDates = Dictionary(grouping: importantDates.filter { $0.rule.system == .gregorian }) {
            DateComponents(month: $0.month, day: $0.day)
        }
        let lunarDates = importantDates.filter { $0.rule.system == .lunar }

        return Dictionary(uniqueKeysWithValues: month.days.map { day in
            let dayEvents = monthEvents.days[day] ?? []
            let linked = Set(dayEvents.compactMap(\.asmoID))
            let occasions = (fixedDates[DateComponents(month: day.month, day: day.day)] ?? []) + lunarDates
            var items = occasions.filter { $0.rule.matches(day, calendar: calendar) }.map { record in
                let canGreet = canPlanGreeting(for: record, on: day, clock: clock)
                return CalendarDayItem(id: "occasion-\(record.id)", title: record.title, detail: record.rule.label,
                                       kind: .occasion, open: {
                    if canGreet { planGreeting(for: record, on: day) }
                    else { editOccasion(record) }
                }, openHint: canGreet ? String(localized: "安排生日祝福") : String(localized: "编辑日期与时区"))
            }
            var uniqueOccasions = Set(items.map(\.title))
            for event in dayEvents {
                let kind: CalendarDayItem.Kind = event.importantKind == nil ? .event : .occasion
                if kind == .occasion && !uniqueOccasions.insert(event.title).inserted { continue }
                let start = event.allDay ? nil : PlanDate.from(event.start, calendar: calendar, includeTime: true).minuteOfDay
                let task = event.asmoID.flatMap { linkedTasks[$0] }
                let toggle: (() -> Void)? = task.map { record in { record.completed.toggle(); persist() } }
                items.append(CalendarDayItem(id: event.id, title: event.title, detail: event.calendarTitle,
                                             kind: kind, startMinute: start, completed: task?.completed ?? false,
                                             toggle: toggle, open: { navigateAgenda(to: day); edit(event, task: task) },
                                             dragID: kind == .event && event.writable ? event.id : nil))
            }
            // Every day's routines, at their time, checked per day.
            for instance in routineInstances(on: day) {
                let routine = instance.routine
                items.append(CalendarDayItem(id: "routine-" + instance.id, title: routine.title, kind: .task,
                                             startMinute: routine.startMinute, completed: instance.done,
                                             toggle: { toggleRoutine(instance) }, open: { openDocument(day) }))
            }
            // Subtasks live with their parent in 逐日; a month cell lists the top-level things.
            let dayTasks = scheduled[day] ?? []
            let dayIDs = Set(dayTasks.map(\.id))
            for task in dayTasks where !linked.contains(task.id) && !monthEvents.linked.contains(task.id)
                && !(task.parentID.map(dayIDs.contains) ?? false) {
                items.append(CalendarDayItem(id: task.id.uuidString, title: task.title, kind: .task,
                                             startMinute: task.schedule?.minuteOfDay, completed: task.completed,
                                             toggle: { task.completed.toggle(); persist() },
                                             timeEdit: task.schedule.flatMap { agendaTimeEdit(for: task, plan: $0) },
                                             open: { navigateAgenda(to: day); edit(task) },
                                             dragID: task.calendarLinked ? nil : task.id.uuidString,
                                             delete: task.calendarLinked ? nil : { deleteTask(task) }))
            }
            for task in reminders[day] ?? [] {
                items.append(CalendarDayItem(id: task.id, title: task.title, kind: .task,
                                             startMinute: task.schedule?.minuteOfDay, completed: task.completed,
                                             toggle: { Task { await report { try await system.toggle(task) } } },
                                             open: { navigateAgenda(to: day); edit(task) }, dragID: task.id))
            }
            if let note = recordedNotes[day.key]?.first {
                items.append(CalendarDayItem(id: "note-\(day.key)", title: String(localized: "日备注"), detail: note.body, kind: .note,
                                             open: { navigateAgenda(to: day); journalNoteDate = day }))
            }
            let currentTitles = Set(items.map { $0.title.trimmed })
            var historyIndex: [String: Int] = [:]
            for item in archivedDays[day] ?? [] where !item.entry.body.trimmed.isEmpty && !promoted.contains(item.entry.id) {
                let text = JournalArchiveText(edits[item.recordKey] ?? item.entry.body)
                let key = text.text.trimmed
                guard !key.isEmpty, !currentTitles.contains(key) else { continue }
                let row = CalendarDayItem(id: "archive-\(item.recordKey)", title: String(localized: "历史归档"), detail: text.text,
                                          kind: .archive, completed: text.completed,
                                          open: { openArchive(item, day: day) }, openHint: String(localized: "查看归档原文"))
                if let index = historyIndex[key] {
                    if row.completed && !items[index].completed { items[index] = row }
                } else {
                    historyIndex[key] = items.endIndex
                    items.append(row)
                }
            }
            // Timed first, then open, finished last — the lines that fit show what's still ahead.
            // Routines sit among the other items in time order, like everywhere else; what's done goes last.
            func rank(_ item: CalendarDayItem) -> Int { item.completed ? 1 : 0 }
            return (day, items.sorted { (rank($0), $0.sortGroup, $0.startMinute ?? 0)
                < (rank($1), $1.sortGroup, $1.startMinute ?? 0) })
        })
    }

    private func indexArchiveDays() async {
        #if DEBUG
        let started = Date.now
        defer { PerfLog.note("indexArchive", since: started) }
        #endif
        #if os(macOS)
        // Imported history is stored once as each day's own page, like any saved document: nothing is parsed at
        // launch. Only a document imported since (not yet in the pages) is read, then written into its days.
        let movedKey = "archiveInPages." + (ProcessInfo.processInfo.environment["ASMO_TEST_STORE"] ?? "main")
        var moved = Set(UserDefaults.standard.stringArray(forKey: movedKey) ?? [])
        let fresh = archives.filter { !moved.contains($0.digest + ":" + String($0.defaultYear)) }
        guard !fresh.isEmpty else {
            if !archivedDays.isEmpty { archivedDays = [:]; ArchiveIndexCache.clear() }
            return
        }
        let freshSources = fresh.map { (raw: $0.raw, year: $0.defaultYear, digest: $0.digest) }
        let parseClock = clock
        let parsed = await Task.detached(priority: .utility) {
            var days: [PlanDate: [ArchivedDayEntry]] = [:]
            for source in freshSources {
                for entry in ArchiveParser.parse(source.raw, defaultYear: source.year, clock: parseClock).entries {
                    guard let day = entry.schedule?.dayOnly, day.day != nil,
                          !days[day, default: []].contains(where: { $0.entry.id == entry.id }) else { continue }
                    days[day, default: []].append(ArchivedDayEntry(documentDigest: source.digest, defaultYear: source.year, entry: entry))
                }
            }
            return days
        }.value
        guard !Task.isCancelled else { return }
        writeHistoryPages(parsed)
        moved.formUnion(fresh.map { $0.digest + ":" + String($0.defaultYear) })
        UserDefaults.standard.set(Array(moved), forKey: movedKey)
        archivedDays = [:]
        ArchiveIndexCache.clear()
        archiveRevision += 1
        pageRebuild += 1
        return
        #else
        let stamp = archives.map { $0.digest + ":" + String($0.defaultYear) }.sorted().joined(separator: ",")
        let stampKey = "archiveIndexStamp." + (ProcessInfo.processInfo.environment["ASMO_TEST_STORE"] ?? "main")
        if !archivedDays.isEmpty, UserDefaults.standard.string(forKey: stampKey) == stamp {
            if earliestArchiveDay == nil { earliestArchiveDay = archivedDays.keys.min() }
            return
        }
        let sources = archives.map { (raw: $0.raw, year: $0.defaultYear, digest: $0.digest) }
        let capturedClock = clock
        let result = await Task.detached(priority: .utility) {
            var days: [PlanDate: [ArchivedDayEntry]] = [:]
            for source in sources {
                for entry in ArchiveParser.parse(source.raw, defaultYear: source.year, clock: capturedClock).entries {
                    guard let day = entry.schedule?.dayOnly, day.day != nil,
                          !days[day, default: []].contains(where: { $0.entry.id == entry.id }) else { continue }
                    days[day, default: []].append(ArchivedDayEntry(documentDigest: source.digest,
                                                                   defaultYear: source.year, entry: entry))
                }
            }
            ArchiveIndexCache.save(days)
            return days
        }.value
        if !Task.isCancelled {
            archivedDays = result
            earliestArchiveDay = result.keys.min()
            archiveRevision += 1
            UserDefaults.standard.set(stamp, forKey: stampKey)
        }
        #endif
    }

    #if os(macOS)
    /// Writes imported history into each day's page, as ordinary text (struck lines stay struck), above whatever
    /// the page already has. Lines that became items, or that repeat an item's title, aren't written twice.
    private func writeHistoryPages(_ days: [PlanDate: [ArchivedDayEntry]]) {
        let promoted = Set(tasks.compactMap(\.importKey))
        let edits = Dictionary(journalEdits.map { ($0.recordKey, $0.body) }, uniquingKeysWith: { newest, _ in newest })
        var pages = Dictionary(((try? context.fetch(FetchDescriptor<DayPage>())) ?? []).map { ($0.dayKey, $0) }, uniquingKeysWith: { first, _ in first })
        let titles = Dictionary(grouping: tasks.filter { $0.schedule?.dayOnly.day != nil }) { $0.schedule!.dayOnly }
        let font = NSFont.systemFont(ofSize: 15)
        for (day, entries) in days {
            var seen = Set((titles[day] ?? []).map { $0.title.trimmed })
            let text = NSMutableAttributedString()
            for item in entries where !item.entry.body.trimmed.isEmpty && !promoted.contains(item.entry.id) {
                let entry = JournalArchiveText(edits[item.recordKey] ?? item.entry.body)
                guard seen.insert(entry.text.trimmed).inserted else { continue }
                for line in entry.text.components(separatedBy: .newlines).map(\.trimmed) where !line.isEmpty {
                    var attributes: [NSAttributedString.Key: Any] = [.font: font]
                    if entry.completed { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    text.append(NSAttributedString(string: line + "\n", attributes: attributes))
                }
            }
            guard text.length > 0 else { continue }
            let page = pages[day.key]
            if let data = page?.rtfd, let old = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil) {
                text.append(old)
            }
            guard let data = try? text.data(from: NSRange(location: 0, length: text.length),
                                            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) else { continue }
            if let page { page.rtfd = data; page.updatedAt = .now }
            else {
                let made = DayPage(dayKey: day.key, rtfd: data)
                context.insert(made)
                pages[day.key] = made
            }
        }
        persist()
    }
    #endif

    private var jumpSheet: some View {
        #if os(macOS)
        let size = CGSize(width: 372, height: 370)
        #else
        let size = CGSize(width: 400, height: 130)
        #endif
        return PlannerPanel(title: String(localized: "跳转到日期"), width: size.width, height: size.height, close: closePanel) {
            #if os(macOS)
            DesktopCalendarPicker(date: $jumpDate, theme: theme, openTypedDate: jumpToDate)
            #else
            DatePicker(String(localized: "日期"), selection: $jumpDate, displayedComponents: .date)
                .datePickerStyle(.compact)
                .modifier(PlannerFieldStyle(theme: theme))
            #endif
        } footer: {
            if !isToday {
                Button("回到今天") { showToday(); closePanel() }.buttonStyle(PlannerActionStyle(theme: theme))
            }
            Button(page == .month ? "跳到月份" : "打开当天") { jumpToDate(jumpDate) }
                .buttonStyle(PlannerActionStyle(theme: theme, primary: true))
        }
    }

    private func jumpToDate(_ date: Date) {
        let day = PlanDate.from(date, calendar: clock.calendar)
        #if os(macOS)
        if page == .month { selected = day; monthCursor = day; monthDetail = nil }
        else { navigateAgenda(to: day) }
        #else
        selected = day
        if page != .month { page = .day }
        #endif
        closePanel()
    }

    private var captureSchedule: PlanDate? {
        #if os(macOS)
        if let desktopDraft { return desktopDraft.schedule }
        #endif
        return defaultSchedule
    }

    private var defaultSchedule: PlanDate? {
        switch page {
        case .day: selected
        case .month: PlanDate(year: selected.year, month: selected.month)
        case .inbox: nil
        }
    }

    private func isBeforeToday(_ schedule: PlanDate?) -> Bool {
        guard let schedule, schedule.day != nil else { return false }
        return schedule.dayOnly < clock.today
    }

    /// Coming back after a while (20 min): the planner is on today again, unless you were writing.
    /// nil while today is in view; otherwise where it is (see TodayButton).
    private var todayDirection: Int? {
        if page == .month {
            let today = clock.today
            return monthCursor.year == today.year && monthCursor.month == today.month ? nil : 0
        }
        return todayOffscreen == 0 ? nil : todayOffscreen
    }

    private func returnAfterAway() {
        defer { leftAt = nil }
        updateCurrentDay()
        guard let leftAt, Date.now.timeIntervalSince(leftAt) > 20 * 60, sheet == nil else { return }
        #if os(macOS)
        // Back after a while: the calendar shows this month again (unless a page is open).
        if Self.calendarHome { if documentDay == nil { monthCursor = clock.today; selected = clock.today }; return }
        #endif
        guard editingDay == nil else { return }
        showToday()
    }

    private func showToday() {
        #if os(macOS)
        paperFocus = nil
        paperJump += 1
        #else
        if let current = editingDay {
            if current != clock.today { openDocument(clock.today) }
            return
        }
        if page == .month {
            selected = clock.today
            monthDetail = nil
            monthCursor = clock.today
        } else {
            navigateAgenda(to: clock.today)
        }
        #endif
    }

    private func updateCurrentDay() {
        let today = clock.today
        guard today != lastKnownToday else { return }
        if page == .day, selected == lastKnownToday {
            navigateAgenda(to: today)
        }
        lastKnownToday = today
        rollOverdueTasks()
    }

    private func shift(_ offset: Int) {
        guard let date = selected.date(in: clock.calendar),
              let next = clock.calendar.date(byAdding: page == .month ? .month : .day, value: offset, to: date) else { return }
        let day = PlanDate.from(next, calendar: clock.calendar)
        #if os(macOS)
        if page == .day { navigateAgenda(to: day); return }
        #endif
        selected = day
    }

    private func addTyped() {
        let input = entry.trimmed
        guard !input.isEmpty else { return }
        let drafts = input.components(separatedBy: .newlines).filter { !$0.trimmed.isEmpty }.map {
            CaptureParser.manual($0, clock: clock, selectedDay: captureSchedule)
        }
        capture(drafts, forceReview: false)
    }

    private func record() {
        guard !processing else { return }
        Task {
            if voice.recording {
                let recordedClock = clock
                let schedule = captureSchedule
                let locale = Locale(identifier: voiceLocale)
                let timer = ContinuousClock.now
                voiceSampleTime = nil
                voiceSampleCanPass = false
                do {
                    status = String(localized: "正在转写…")
                    let transcript = try await voice.finish(locale: locale)
                    let previousEntry = entry
                    entry = [previousEntry, transcript].filter { !$0.trimmed.isEmpty }.joined(separator: "\n")
                    if !previousEntry.trimmed.isEmpty { status = String(localized: "已将口述加到输入框"); return }
                    processing = true
                    defer { processing = false }
                    let extracted = try? await TaskExtraction.onDevice(transcript, locale: locale)
                    if let parsed = extracted, !parsed.isEmpty {
                        guard entry == transcript else { status = String(localized: "口述文字已保留"); return }
                        let drafts = CaptureParser.validated(parsed, original: transcript, clock: recordedClock,
                                                             selectedDay: schedule)
                        voiceSampleCanPass = true
                        capture(drafts, forceReview: !verifiedVoiceAutoSave)
                    } else {
                        status = String(localized: "转写完成，可以编辑后保存")
                    }
                    let elapsed = timer.duration(to: .now).components
                    voiceSampleTime = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                } catch {
                    status = ""
                    self.error = error.localizedDescription
                    let elapsed = timer.duration(to: .now).components
                    voiceSampleTime = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                }
            } else {
                await report { try await voice.start(); status = String(localized: "正在录音，点停止后转写") }
            }
        }
    }

    private func organizeTyped() {
        let original = entry
        let selected = defaultSchedule
        let clock = clock
        guard !original.trimmed.isEmpty, !processing else { return }
        processing = true
        Task {
            defer { processing = false }
            let locale = Locale(identifier: voiceLocale)
            guard let parsed = try? await TaskExtraction.onDevice(original, locale: locale) else {
                status = String(localized: "端侧智能整理暂不可用，可以直接保存文字")
                return
            }
            guard original == entry else { return }
            capture(CaptureParser.validated(parsed, original: original, clock: clock, selectedDay: selected),
                    forceReview: !verifiedVoiceAutoSave)
        }
    }

    private func rateVoice(correct: Bool, seconds: Double) {
        voiceSampleCount += 1
        voiceSampleCorrect += correct ? 1 : 0
        voiceSampleSeconds += seconds
        voiceSampleTime = nil
        if voiceSampleCorrect * 10 < voiceSampleCount * 9 { verifiedVoiceAutoSave = false }
    }

    private func capture(_ drafts: [CaptureDraft], forceReview: Bool) {
        let ready = forceReview ? [] : drafts.filter { !$0.requiresReview }
        let review = forceReview ? drafts : drafts.filter(\.requiresReview)
        for draft in ready {
            let task = TaskRecord(id: draft.id, title: draft.title, schedule: draft.schedule, endMinute: draft.endMinute)
            task.sourceText = draft.original == draft.title ? nil : draft.original
            context.insert(task)
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            self.error = error.localizedDescription
            return
        }
        entry = ""
        undoIDs = Set(ready.map(\.id))
        status = ready.isEmpty ? "" : String(localized: "已记下 \(ready.count) 条")
        #if os(macOS)
        desktopFallbackAvailable = false
        // Like a document: after Enter the cursor stays on a fresh line for the next thing.
        if desktopEntryOpen { entryFocused = true }
        if ready.count == 1, let date = ready.first?.schedule, date.dayOnly != selected {
            status = String(localized: "已记到 \(date.label)")
        }
        #else
        if let date = ready.first?.schedule, ready.count == 1, review.isEmpty {
            if date.day == nil {
                selected = PlanDate(year: date.year, month: date.month, day: 1)
                page = .month
            } else {
                selected = date.dayOnly
                page = .day
            }
        }
        #endif
        queue.append(contentsOf: review)
        advanceReview()
    }

    private func originalNote(_ draft: CaptureDraft) -> String {
        draft.original == draft.title ? "" : draft.original
    }

    private func advanceReview() {
        guard sheet == nil, !queue.isEmpty else { return }
        let draft = queue.removeFirst()
        editor = EditorInput(id: draft.id, title: draft.title, note: originalNote(draft), schedule: draft.schedule,
                             action: draft.action, endMinute: draft.endMinute,
                             eventAlertLead: draft.alertLead == -1 ? nil : (draft.alertLead ?? 15), reviewing: true)
        sheet = .editor
    }

    private func edit(_ task: TaskRecord) {
        editor = EditorInput(id: task.id, title: task.title, note: task.note, schedule: task.schedule,
                             action: task.pendingReminder == nil ? .task : .reminder,
                             alert: task.pendingReminder, endMinute: task.endMinute, calendarLink: task.calendarLinked, record: task)
        sheet = .editor
    }

    private func edit(_ task: SystemTask) {
        editor = EditorInput(id: task.asmoID ?? UUID(), title: task.title, note: task.note, schedule: task.schedule,
                             action: .reminder, alert: task.alertAt, endMinute: task.endMinute, external: task)
        sheet = .editor
    }

    private func edit(_ event: SystemEvent, task: TaskRecord?) {
        let schedule = PlanDate.from(event.start, calendar: clock.calendar, includeTime: !event.allDay)
        let end = clock.calendar.dateComponents([.hour, .minute], from: event.end)
        let dayOffset = clock.calendar.dateComponents([.day], from: clock.calendar.startOfDay(for: event.start),
                                                       to: clock.calendar.startOfDay(for: event.end)).day ?? 0
        editor = EditorInput(id: event.asmoID ?? UUID(), title: event.title, note: event.note, schedule: schedule,
                             action: task == nil ? .event : .task,
                             endMinute: event.allDay ? nil : dayOffset * 1440 + (end.hour ?? 0) * 60 + (end.minute ?? 0),
                             calendarLink: task != nil, calendarID: event.calendarID,
                             eventAlertLead: event.alertLead, event: event, record: task)
        sheet = .editor
    }

    private func saveEditor(_ change: EditorInput) async throws {
        if let external = change.external {
            try await system.editReminder(external, title: change.title, note: change.note,
                                          schedule: change.schedule, endMinute: change.endMinute, alert: change.alert)
            return
        }

        if change.action == .event || change.calendarLink {
            guard let plan = change.schedule, let date = plan.date(in: clock.calendar) else { throw EditorError.date }
            let allDay = plan.hour == nil
            let start = allDay ? clock.calendar.startOfDay(for: date) : date
            let end: Date
            if allDay {
                let days = change.event.flatMap {
                    clock.calendar.dateComponents([.day], from: $0.start, to: $0.end).day
                } ?? 1
                guard let finish = clock.calendar.date(byAdding: .day, value: max(1, days), to: start) else { throw EditorError.range }
                end = finish
            } else {
                guard let finish = endDate(plan, minute: change.endMinute), finish > start else { throw EditorError.range }
                end = finish
            }
            try await system.saveEvent(id: change.id, title: change.title, start: start, end: end,
                                       allDay: allDay, note: change.note, alertLead: change.eventAlertLead,
                                       calendarID: change.calendarID, existing: change.event,
                                       previousStart: change.record?.linkedEventStart, linkTask: change.calendarLink)
            if change.action == .event {
                await refresh()
                return
            }
        }

        let task = change.record ?? tasks.first { $0.id == change.id } ??
            TaskRecord(id: change.id, title: change.title, schedule: change.schedule)
        task.title = change.title
        task.note = change.note
        task.schedule = change.schedule
        task.endMinute = change.endMinute
        task.calendarLinked = change.calendarLink
        task.linkedEventStart = change.calendarLink ? change.schedule?.date(in: clock.calendar) : nil
        task.pendingReminder = change.action == .reminder ? change.alert : nil
        if task.modelContext == nil { context.insert(task) }
        do { try context.save() }
        catch { context.rollback(); throw error }
        if change.calendarLink { await refresh() }
        if change.action == .reminder, let alert = change.alert {
            transferringIDs.insert(change.id)
            defer { transferringIDs.remove(change.id) }
            do {
                try await system.putReminder(id: task.id, title: task.title, note: task.note, schedule: task.schedule,
                                             endMinute: task.endMinute, at: alert, completed: task.completed)
                context.delete(task)
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    private func deleteEditor(_ change: EditorInput) async throws {
        if change.event != nil || change.calendarLink {
            try system.deleteEvent(change.event, id: change.id, previousStart: change.record?.linkedEventStart)
            await refresh()
        }
        if let task = change.record {
            context.delete(task)
            do { try context.save() }
            catch { context.rollback(); throw error }
        }
        if let external = change.external { try await system.delete(external) }
    }

    private func undo() {
        for task in tasks where undoIDs.contains(task.id) { context.delete(task) }
        persist()
        undoIDs = []
        status = String(localized: "已撤销本次新增")
    }

    private func saveNote(_ body: String) { saveNote(body, on: selected) }

    private func saveNote(_ body: String, on day: PlanDate) {
        let key = day.key
        if let note = notes.first(where: { $0.dayKey == key }) {
            guard note.body != body else { return }
            note.body = body
            note.updatedAt = .now
        } else if !body.trimmed.isEmpty {
            context.insert(DayNote(dayKey: key, body: body))
        }
        persist()
    }

    private func refresh() async {
        system.refreshCalendars()
        await system.refreshReminders()
        let recovered = tasks.filter {
            $0.pendingReminder != nil && linkedIDs.contains($0.id) && !transferringIDs.contains($0.id)
        }
        if !recovered.isEmpty {
            for task in recovered { context.delete(task) }
            persist()
        }
    }

    private func report(_ action: () async throws -> Void) async {
        do { try await action() }
        catch { self.error = error.localizedDescription }
    }

    private func persist() {
        do { try context.save() }
        catch { context.rollback(); self.error = error.localizedDescription }
    }
}

private struct DayNoteEditor: View {
    let key: String
    let saved: String
    let save: (String) -> Void
    let theme: PlannerTheme
    let autoFocus: Bool
    let dismissEditor: (() -> Void)?
    @State private var draft: String
    @FocusState private var focused: Bool

    init(key: String, saved: String, save: @escaping (String) -> Void, theme: PlannerTheme,
         autoFocus: Bool = false, dismissEditor: (() -> Void)? = nil) {
        self.key = key
        self.saved = saved
        self.save = save
        self.theme = theme
        self.autoFocus = autoFocus
        self.dismissEditor = dismissEditor
        _draft = State(initialValue: saved)
    }

    var body: some View {
        #if os(macOS)
        let prompt = String(localized: "记点不需要勾掉的事…")
        #else
        let prompt = String(localized: "今天还有什么想记的？")
        #endif
        TextField("日备注", text: $draft, prompt: Text(prompt).foregroundStyle(theme.quiet), axis: .vertical)
            .focused($focused)
            .lineLimit(2...7)
            #if os(macOS)
            .frame(minHeight: 52, alignment: .topLeading)
            #endif
            .font(.subheadline)
            .modifier(PlannerFieldStyle(theme: theme))
            .accessibilityLabel("日备注")
            #if os(macOS)
            .task {
                guard autoFocus else { return }
                try? await Task.sleep(for: .milliseconds(45))
                if !Task.isCancelled { focused = true }
            }
            .onKeyPress(.escape) {
                guard let dismissEditor else { return .ignored }
                dismissEditor()
                return .handled
            }
            #endif
            .onChange(of: draft) { _, value in if value != saved { save(value) } }
            .onChange(of: saved) { _, value in if !focused { draft = value } }
    }
}

#if DEBUG
/// Debug timing: slow steps (over 4 ms) go to Caches/asmo-perf.txt.
enum PerfLog {
    /// When a day was clicked open (the page's first draw reports the time since).
    nonisolated(unsafe) static var opened: Date?
    nonisolated(unsafe) private static var last = Date.now
    nonisolated(unsafe) private static var timer: Timer?

    /// Logs every main-thread stall over 80 ms (a hitch the user would feel).
    static func watch() {
        guard timer == nil else { return }
        last = .now
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            let gap = Date.now.timeIntervalSince(last)
            if gap > 0.08 { note("STALL", since: last.addingTimeInterval(0.02)) }
            last = .now
        }
    }
    static func say(_ text: String) {
        let url = AppPaths.caches.appendingPathComponent("asmo-perf.txt")
        let line = String(format: "%.3f ", Date.now.timeIntervalSince1970) + text + "\n"
        if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    static func note(_ name: String, since start: Date) {
        let ms = Date.now.timeIntervalSince(start) * 1000
        guard ms > 4 else { return }
        let url = AppPaths.caches.appendingPathComponent("asmo-perf.txt")
        let line = String(format: "%.3f %@ %.1fms\n", Date.now.timeIntervalSince1970, name, ms)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
#endif

/// Draws the calendar only when its fingerprint changes: SwiftUI otherwise re-diffs the whole month on every
/// change anywhere in the planner (opening a day, each keystroke on its page).
struct CalendarHost<Content: View>: View, Equatable {
    let key: Int
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
}

#if os(macOS)
final class PaperContentsModel: ObservableObject {
    /// The first written day of every month that has one, oldest first.
    @Published var months: [PlanDate] = []
    /// The month at the top of the document's window.
    @Published var visible: PlanDate?
}

/// Contents: every month with something written, oldest first like the document; the month on screen is
/// highlighted and kept in view, and a click goes there.
struct PaperContentsSidebar: View {
    @ObservedObject var model: PaperContentsModel
    let theme: PlannerTheme
    let thisYear: Int
    let today: PlanDate

    /// "11月" in Chinese, "November" in English (the year is the heading the month sits under).
    static func label(_ month: PlanDate) -> String {
        guard Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true else { return "\(month.month)月" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        return (1...12).contains(month.month) ? formatter.monthSymbols[month.month - 1] : "\(month.month)"
    }
    let reduceMotion: Bool
    let pick: (PlanDate) -> Void
    let close: () -> Void

    /// Years the reader opened or closed by hand (true = open). The others follow the rule in `isOpen`.
    @State private var chosen: [Int: Bool] = [:]

    /// A year is open when it is this year or the one on screen, unless the reader folded or unfolded it.
    private func isOpen(_ year: Int) -> Bool {
        chosen[year] ?? (year == thisYear || year == (model.visible ?? today).year)
    }

    private var years: [(year: Int, months: [PlanDate])] {
        Dictionary(grouping: model.months) { $0.year }.keys.sorted().map { year in (year, model.months.filter { $0.year == year }) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("目录").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.quiet)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.quiet)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("收起目录")
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(years, id: \.year) { group in
                            let open = isOpen(group.year)
                            let onScreen = (model.visible ?? today).year == group.year
                            // The year: a click folds or unfolds its months.
                            Button {
                                withAnimation(reduceMotion ? nil : .smooth(duration: 0.18)) { chosen[group.year] = !open }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                                        .rotationEffect(.degrees(open ? 90 : 0))
                                        .foregroundStyle(theme.quiet.opacity(0.8))
                                        .frame(width: 10)
                                    Text(verbatim: String(group.year))
                                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(onScreen && !open ? theme.accent : theme.quiet)
                                    Spacer()
                                }
                                .padding(.horizontal, 14).frame(height: 30).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(verbatim: String(group.year)))
                            .accessibilityValue(open ? Text("已展开") : Text("已折叠"))
                            .id(group.year)
                            if open {
                                ForEach(group.months, id: \.self) { first in
                                    let month = PlanDate(year: first.year, month: first.month)
                                    let current = (model.visible ?? today) == month
                                    Button { pick(first) } label: {
                                        Text(Self.label(first))
                                            .font(.system(size: 13, weight: current ? .semibold : .regular))
                                            .foregroundStyle(current ? theme.accent : theme.ink.opacity(0.62))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.leading, 30).padding(.trailing, 16).frame(height: 28).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .id(month)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.never)
                .onChange(of: model.visible) { old, month in
                    guard let month else { return }
                    // Scrolling into another year opens it again (a fold made by hand lasts while the year is off screen).
                    if old?.year != month.year, chosen[month.year] == false { chosen[month.year] = nil }
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { reader.scrollTo(month, anchor: .center) }
                }
                .onChange(of: model.months) { _, _ in
                    reader.scrollTo(model.visible ?? today, anchor: .center)
                }
                .onAppear { reader.scrollTo(model.visible ?? today, anchor: .center) }
            }
        }
        .frame(width: 150)
    }
}
#endif
