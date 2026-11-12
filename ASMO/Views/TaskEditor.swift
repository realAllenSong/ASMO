import SwiftUI

struct EditorInput {
    var id: UUID
    var title: String
    var note: String
    var schedule: PlanDate?
    var action: CaptureAction
    var alert: Date?
    var endMinute: Int?
    var calendarLink = false
    var calendarID: String?
    var eventAlertLead: Int? = 15
    var event: SystemEvent?
    var reviewing = false
    var record: TaskRecord?
    var external: SystemTask?
}

enum EditorError: LocalizedError {
    case date, time, clock, range, calendarRange
    var errorDescription: String? {
        switch self {
        case .date: String(localized: "请选择具体日期。")
        case .time: String(localized: "请设置提醒时间。")
        case .clock: String(localized: "请输入有效的时间，例如 15:30。")
        case .range: String(localized: "结束时间要晚于开始时间。")
        case .calendarRange: String(localized: "写入日历前，请设置开始和结束时间。")
        }
    }
}

@MainActor
struct TaskEditor: View {
    enum Precision: String, CaseIterable {
        case none = "未安排", month = "月份", day = "日期", time = "时间"
    }

    let input: EditorInput
    let system: SystemPlanner
    let save: (EditorInput) async throws -> Void
    let delete: (EditorInput) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closePlannerPanel) private var closePanel
    @Environment(\.colorScheme) private var scheme
    @State private var change: EditorInput
    @State private var precision: Precision
    @State private var date: Date
    @State private var startText: String
    @State private var endText: String
    @State private var hasAlarm: Bool
    @State private var alarm: Date
    @State private var busy = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var editedEndDayOffset: Int?
    #if os(macOS)
    @State private var aiEditExpanded = false
    @State private var aiInstruction = ""
    @State private var aiFeedback = ""
    #endif

    init(input: EditorInput, system: SystemPlanner, save: @escaping (EditorInput) async throws -> Void,
         delete: @escaping (EditorInput) async throws -> Void) {
        self.input = input
        self.system = system
        self.save = save
        self.delete = delete
        let clock = CaptureClock()
        let date = input.schedule?.date(in: clock.calendar) ?? clock.now
        _date = State(initialValue: date)
        _precision = State(initialValue: input.schedule == nil ? .none :
                            input.schedule?.day == nil ? .month : input.schedule?.hour == nil ? .day : .time)
        var value = input
        if value.calendarID == nil {
            value.calendarID = !system.destinationID.isEmpty ? system.destinationID :
                system.calendars.first { $0.writable }?.id
        }
        _change = State(initialValue: value)
        _startText = State(initialValue: DayTimeline.time(date, calendar: clock.calendar))
        _endText = State(initialValue: input.endMinute.map { String(format: "%02d:%02d", ($0 / 60) % 24, $0 % 60) } ?? "")
        _hasAlarm = State(initialValue: input.external == nil || input.alert != nil)
        let possible = input.schedule?.hour == nil ? nil : input.schedule?.date(in: clock.calendar)
        _alarm = State(initialValue: input.alert ?? (possible.flatMap { $0 > clock.now ? $0 : nil }) ??
                       clock.now.addingTimeInterval(3600))
    }

    var body: some View {
        PlannerPanel(title: input.reviewing ? String(localized: "确认这一条") : (input.event != nil ? String(localized: "编辑日历事件") : String(localized: "编辑待办")),
                     width: 520, height: 440, close: close) {
            VStack(alignment: .leading, spacing: 15) {
                field(String(localized: "标题")) {
                    TextField("标题", text: $change.title, axis: .vertical)
                        .lineLimit(1...3).modifier(PlannerFieldStyle(theme: theme))
                        .accessibilityIdentifier("taskTitle")
                }
                #if os(macOS)
                if (input.record != nil || input.external != nil || input.event != nil) && input.event?.writable != false {
                    aiEditControl
                }
                #endif
                field(String(localized: "备注")) {
                    TextField("添加备注…", text: $change.note, axis: .vertical)
                        .lineLimit(1...4).modifier(PlannerFieldStyle(theme: theme))
                }
                HStack(alignment: .top, spacing: 12) {
                    if input.external == nil && input.event == nil && !input.calendarLink {
                        let actions: [(String, CaptureAction)] = [(String(localized: "待办"), .task), (String(localized: "Apple 提醒事项"), .reminder)] +
                            (input.record == nil ? [(String(localized: "Apple 日历"), .event)] : [])
                        field(String(localized: "保存到")) { options($change.action, choices: actions, label: String(localized: "保存到")) }
                    }
                    field(String(localized: "安排方式")) {
                        let choices = Precision.allCases.filter {
                            switch change.action {
                            case .task: true
                            case .event: $0 == .day || $0 == .time
                            case .reminder: $0 != .month
                            }
                        }.map { ($0.rawValue, $0) }
                        options($precision, choices: choices, label: String(localized: "安排方式"))
                    }
                }
                if precision == .month {
                    HStack {
                        Stepper(String(localized: "\(String(month.year)) 年"), value: year, in: 1900...2200)
                        options(monthNumber, choices: (1...12).map { (String(localized: "\($0) 月"), $0) }, label: String(localized: "月份"))
                    }
                } else if precision != .none {
                    #if os(macOS)
                    field(String(localized: "日期")) { DesktopDateField(date: $date, theme: theme) }
                    #else
                    HStack(spacing: 12) {
                        Text("日期").font(.caption.weight(.medium)).foregroundStyle(theme.quiet)
                        DatePicker(String(localized: "日期"), selection: $date, displayedComponents: .date)
                            .labelsHidden().datePickerStyle(.compact)
                        Spacer(minLength: 0)
                    }
                    #endif
                }
                if precision == .time || precision == .day {
                    timeSelection
                }
                if change.action == .reminder {
                    divider
                    if input.external != nil { PlannerToggle(title: "到点通知", selected: $hasAlarm, theme: theme) }
                    if hasAlarm {
                        field(String(localized: "提醒时间")) {
                            DatePicker(String(localized: "提醒时间"), selection: $alarm, displayedComponents: [.date, .hourAndMinute])
                                .labelsHidden().datePickerStyle(.compact).modifier(PlannerFieldStyle(theme: theme))
                        }
                        if !system.canReadReminders {
                            Button("允许访问提醒事项") { run { try await system.authorizeReminders() } }
                                .buttonStyle(PlannerActionStyle(theme: theme))
                        }
                    }
                }
                if input.external == nil && (change.action == .task || change.action == .event) {
                    divider
                    if change.action == .task {
                        PlannerToggle(title: "写入 Apple 日历", selected: $change.calendarLink, theme: theme)
                            .disabled(input.calendarLink)
                    }
                    if change.action == .event || change.calendarLink { eventOptions }
                }
                if input.record != nil || input.external != nil || input.event?.writable == true {
                    divider
                    Button(deleteLabel, role: .destructive) { confirmDelete = true }
                        .buttonStyle(.plain).foregroundStyle(.red)
                }
                if let error { Text(error).font(.callout).foregroundStyle(.red) }
            }
        } footer: {
            Button(input.reviewing ? "跳过" : "取消", action: close).buttonStyle(PlannerActionStyle(theme: theme)).disabled(busy)
            Button(saveLabel) { run { try await commit(); close() } }
                .buttonStyle(PlannerActionStyle(theme: theme, primary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(change.title.trimmed.isEmpty || busy || input.event?.writable == false)
                .opacity(change.title.trimmed.isEmpty || busy || input.event?.writable == false ? 0.55 : 1)
        }
        .onAppear(perform: normalizePrecision)
        .onChange(of: change.action) { _, _ in normalizePrecision() }
        .onChange(of: change.calendarLink) { _, linked in
            if linked && precision != .time { precision = .time }
        }
        .confirmationDialog(deleteLabel + "？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { run { try await delete(change); close() } }
        }
    }

    #if os(macOS)
    private var aiEditControl: some View {
        DisclosureGroup("一句话改期", isExpanded: $aiEditExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    TextField("例如：改到周一下午两点", text: $aiInstruction)
                        .modifier(PlannerFieldStyle(theme: theme))
                        .accessibilityLabel("修改指令")
                        .accessibilityIdentifier("taskEditInstruction")
                    Button("预览修改", action: requestAIEdit)
                        .buttonStyle(PlannerActionStyle(theme: theme))
                        .disabled(aiInstruction.trimmed.isEmpty)
                }
                if !aiFeedback.isEmpty {
                    Text(aiFeedback).font(.caption).foregroundStyle(theme.quiet)
                }
            }
            .padding(.top, 6)
        }
        .font(.subheadline)
    }

    private func requestAIEdit() {
        let instruction = aiInstruction.trimmed
        guard !instruction.isEmpty else { return }
        let originalDate = date
        let originalPrecision = precision
        let originalStart = startText
        let originalEnd = endText
        let originalEndOffset = endDayOffset
        let clock = CaptureClock()
        let anchor = PlanDate.from(originalDate, calendar: clock.calendar)
        do {
            var changed = false
            // Read by the rules: "改到周一下午两点", or just the date and time.
            let phrase = instruction.match(#"^(?:请\s*)?(?:改到|移到|推迟到|提前到|改为)\s*(.+)$"#)?[1]
            let proposed = [phrase, instruction].compactMap { $0 }.compactMap {
                CaptureParser.explicitSchedule($0, clock: clock, selectedDay: anchor)
            }.first
            if let (plan, end) = proposed, let newDate = plan.date(in: clock.calendar) {
                let canSetMonth = change.action == .task && !change.calendarLink
                if plan.day != nil || canSetMonth {
                    date = newDate
                    if let hour = plan.hour {
                        let start = hour * 60 + (plan.minute ?? 0)
                        let duration: Int? = PlannerClockTime.parse(originalStart).flatMap { oldStart in
                            PlannerClockTime.parse(originalEnd).map { $0 + originalEndOffset * 1440 - oldStart }
                        }
                        let finish = end ?? duration.flatMap { $0 > 0 ? start + $0 : nil }
                        precision = .time
                        startText = String(format: "%02d:%02d", hour, plan.minute ?? 0)
                        editedEndDayOffset = finish.map { $0 / 1440 } ?? 0
                        endText = finish.map { String(format: "%02d:%02d", ($0 / 60) % 24, $0 % 60) } ?? ""
                    } else if plan.day == nil {
                        precision = .month
                    } else if originalPrecision != .time {
                        precision = .day
                    }
                    changed = true
                }
            }
            aiFeedback = changed ? String(localized: "已填入编辑器。确认后点保存。") : String(localized: "没找到明确的日期或时间。")
        }
    }
    #endif

    private var theme: PlannerTheme { PlannerTheme(dark: scheme == .dark) }
    private var divider: some View { Rectangle().fill(theme.line).frame(height: 1) }

    private var deleteLabel: String {
        if input.calendarLink { return String(localized: "删除待办和日历事件") }
        return input.event == nil ? String(localized: "删除待办") : String(localized: "删除日历事件")
    }

    private func close() {
        if let closePanel { closePanel() } else { dismiss() }
    }

    private func field<Control: View>(_ title: String, @ViewBuilder content: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.localized).font(.caption.weight(.medium)).foregroundStyle(theme.quiet)
            content()
        }
    }

    private func options<Value: Equatable>(_ selection: Binding<Value>, choices: [(String, Value)], label: String) -> some View {
        Menu {
            ForEach(Array(choices.enumerated()), id: \.offset) { option in
                Button(option.element.0.localized) { selection.wrappedValue = option.element.1 }
            }
        } label: {
            HStack {
                Text(choices.first { $0.1 == selection.wrappedValue }?.0.localized ?? String(localized: "请选择"))
                Spacer()
                ASMOIcon(mark: .down, size: 13).foregroundStyle(theme.quiet)
            }
            .modifier(PlannerFieldStyle(theme: theme))
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(label.localized)
    }

    @ViewBuilder
    private var eventOptions: some View {
        if !system.canReadEvents {
            Button("允许访问 Apple 日历") {
                run {
                    try await system.authorizeEvents()
                    if change.calendarID == nil { change.calendarID = system.calendars.first { $0.writable }?.id }
                }
            }.buttonStyle(PlannerActionStyle(theme: theme))
        } else if input.event?.writable == false {
            Text(input.event?.calendarTitle ?? "只读日历").foregroundStyle(theme.quiet)
        } else {
            field(String(localized: "写入日历")) {
                let choices: [(String, String?)] = [(String(localized: "请选择"), nil)] + system.calendars.filter(\.writable).map { ($0.title, $0.id) }
                options($change.calendarID, choices: choices, label: String(localized: "写入日历"))
            }
        }
        field(String(localized: "日历提醒")) {
            let choices: [(String, Int?)] = [(String(localized: "无提醒"), nil)] + alertOptions.map { (alertLabel($0), $0) }
            options($change.eventAlertLead, choices: choices, label: String(localized: "日历提醒"))
        }
        if precision == .time, let lead = change.eventAlertLead, let start = time(startText, on: date) {
            let alert = start.addingTimeInterval(-Double(lead) * 60)
            Text("\(DayTimeline.time(alert, calendar: clock.calendar)) 提醒")
                .font(.caption).foregroundStyle(theme.accent)
        }
    }

    private var alertOptions: [Int] {
        let options = [0, 5, 15, 30, 60, 1440]
        return Array(Set(options + (change.eventAlertLead.map { [$0] } ?? []))).sorted()
    }

    private func alertLabel(_ value: Int) -> String {
        if value == 0 { return String(localized: "开始时") }
        if value == 1440 { return String(localized: "提前 1 天") }
        if value == 60 { return String(localized: "提前 1 小时") }
        return String(localized: "提前 \(value) 分钟")
    }

    private var saveLabel: String {
        if change.calendarLink && !input.calendarLink { return String(localized: "保存并写入日历") }
        return String(localized: "保存")
    }

    private var clock: CaptureClock { CaptureClock() }
    private var endDayOffset: Int {
        editedEndDayOffset ?? (input.endMinute ?? 0) / PlannerClockTime.minutesPerDay
    }

    private var timeSelection: some View {
        let start = PlannerClockTime.parse(startText)
        let finish = PlannerClockTime.parse(endText).map { $0 + endDayOffset * PlannerClockTime.minutesPerDay }
        let timed = precision == .time
        let linked = change.action == .event || change.calendarLink
        return PlannerTimeButton(selection: .init(start: timed ? start : nil, end: timed ? finish : nil),
                                 theme: theme, label: String(localized: "设置时段"), fallbackStart: timed ? (start ?? 540) : 540,
                                 requiresEnd: linked, allowsClear: !change.calendarLink) { value in
            guard let minute = value.start else {
                precision = .day
                endText = ""
                editedEndDayOffset = 0
                return
            }
            startText = PlannerClockTime.label(minute)
            endText = value.end.map(PlannerClockTime.label) ?? ""
            editedEndDayOffset = (value.end ?? 0) / PlannerClockTime.minutesPerDay
            precision = .time
        }
    }
    private var month: PlanDate { PlanDate.from(date, calendar: clock.calendar) }
    private var year: Binding<Int> {
        Binding(get: { month.year }, set: { setMonth(year: $0, month: month.month) })
    }
    private var monthNumber: Binding<Int> {
        Binding(get: { month.month }, set: { setMonth(year: month.year, month: $0) })
    }

    private func setMonth(year: Int, month: Int) {
        if let target = PlanDate(year: year, month: month, day: 1).date(in: clock.calendar) { date = target }
    }

    private func normalizePrecision() {
        if change.action == .event && (precision == .month || precision == .none) { precision = .day }
        if change.action == .reminder && precision == .month { precision = .none }
    }

    private func time(_ text: String, on date: Date) -> Date? {
        guard let minute = PlannerClockTime.parse(text) else { return nil }
        var plan = PlanDate.from(date, calendar: clock.calendar)
        plan.hour = minute / 60
        plan.minute = minute % 60
        return plan.date(in: clock.calendar)
    }

    private func commit() async throws {
        change.title = change.title.trimmed
        change.endMinute = nil
        switch precision {
        case .none: change.schedule = nil
        case .month: change.schedule = PlanDate(year: month.year, month: month.month)
        case .day: change.schedule = PlanDate.from(date, calendar: clock.calendar)
        case .time:
            guard let start = time(startText, on: date), let startMinute = PlannerClockTime.parse(startText) else { throw EditorError.clock }
            change.schedule = PlanDate.from(start, calendar: clock.calendar, includeTime: true)
            if !endText.trimmed.isEmpty {
                guard let finish = PlannerClockTime.parse(endText).map({ $0 + endDayOffset * 1440 }), finish > startMinute else {
                    throw EditorError.range
                }
                change.endMinute = finish
            }
        }
        if (change.calendarLink || change.action == .event && precision == .time),
           (precision != .time || change.endMinute == nil) { throw EditorError.calendarRange }
        change.alert = change.action == .reminder && hasAlarm ? alarm : nil
        if change.action == .event && change.schedule?.day == nil { throw EditorError.date }
        if change.action == .reminder && input.external == nil && change.alert == nil { throw EditorError.time }
        try await save(change)
    }

    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { try await action() }
            catch { self.error = error.localizedDescription }
        }
    }
}
