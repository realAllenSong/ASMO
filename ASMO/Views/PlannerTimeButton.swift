import SwiftUI

struct PlannerTimeButton: View {
    let selection: PlannerTimeSelection
    let theme: PlannerTheme
    var label = String(localized: "时段")
    var fallbackStart = 9 * 60
    var allowsEnd = true
    var requiresEnd = false
    var allowsClear = true
    var compact = false
    /// 逐日's left time column: the start time as plain text (end time small underneath), no chip.
    var column = false
    let save: (PlannerTimeSelection) throws -> Void

    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            if column { columnLabel } else { chipLabel }
        }
        .buttonStyle(.plain)
        .help(label.localized)
        .accessibilityLabel(label.localized)
        .accessibilityValue(selection.label ?? String(localized: "未设时段"))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            PlannerTimePopover(selection: selection, fallbackStart: fallbackStart, allowsEnd: allowsEnd,
                               requiresEnd: requiresEnd, allowsClear: allowsClear, theme: theme) {
                try save($0)
                showing = false
            }
            // iPhone: a small bubble next to the time, not a full-height sheet.
            .presentationCompactAdaptation(.popover)
        }
    }

    @ViewBuilder
    private var columnLabel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let start = selection.start {
                Text(Self.clock(start))
                    .font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
                    .foregroundStyle(theme.accent)
                if let end = selection.end {
                    Text("–" + Self.clock(end))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(theme.quiet)
                }
            } else {
                Image(systemName: "clock").font(.caption.weight(.medium)).foregroundStyle(theme.quiet)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .contentShape(Rectangle())
    }

    private static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60 % 24, minutes % 60)
    }

    private var chipLabel: some View {
            HStack(spacing: 6) {
                Image(systemName: "clock").font(.caption.weight(.medium)).accessibilityHidden(true)
                if let time = selection.label {
                    Text(time).monospacedDigit()
                } else if !compact {
                    Text("选时间")
                }
            }
            .font(compact ? .caption.weight(.medium) : .subheadline.weight(.medium))
            .foregroundStyle(selection.start == nil ? theme.quiet : theme.accent)
            .padding(.horizontal, compact ? 7 : 10)
            .frame(minHeight: compact ? 29 : 36)
            .background(selection.start != nil ? theme.wash : compact ? .clear : theme.surface,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
    }
}

private struct PlannerTimePopover: View {
    private enum Field: Hashable { case start, end }

    let allowsEnd: Bool
    let requiresEnd: Bool
    let allowsClear: Bool
    let hadStart: Bool
    let theme: PlannerTheme
    let apply: (PlannerTimeSelection) throws -> Void

    @State private var startText: String
    @State private var endText: String
    @State private var endDayOffset: Int
    @State private var active = Field.start
    @State private var error: String?
    @FocusState private var focus: Field?

    init(selection: PlannerTimeSelection, fallbackStart: Int, allowsEnd: Bool, requiresEnd: Bool,
         allowsClear: Bool, theme: PlannerTheme, apply: @escaping (PlannerTimeSelection) throws -> Void) {
        self.allowsEnd = allowsEnd
        self.requiresEnd = requiresEnd
        self.allowsClear = allowsClear
        self.theme = theme
        self.apply = apply
        hadStart = selection.start != nil
        _startText = State(initialValue: PlannerClockTime.label(selection.start ?? fallbackStart))
        _endText = State(initialValue: selection.end.map(PlannerClockTime.label) ?? "")
        _endDayOffset = State(initialValue: (selection.end ?? 0) / PlannerClockTime.minutesPerDay)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                input(allowsEnd ? String(localized: "开始") : String(localized: "时间"), text: $startText, field: .start)
                if allowsEnd {
                    Text("–").foregroundStyle(theme.quiet).padding(.top, 19)
                    input(String(localized: "结束"), text: $endText, field: .end)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("小时").font(.caption).foregroundStyle(theme.quiet)
                choices(Array(0..<24), columns: 8, selected: activeMinute / 60, component: String(localized: "小时")) {
                    setActive($0 * 60 + activeMinute % 60)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("分钟").font(.caption).foregroundStyle(theme.quiet)
                    Spacer()
                    Menu("其他分钟") {
                        ForEach(0..<60, id: \.self) { minute in
                            Button(twoDigits(minute)) { setActive(activeMinute / 60 * 60 + minute) }
                        }
                    }
                    .font(.caption)
                    .fixedSize()
                }
                choices(Array(stride(from: 0, to: 60, by: 5)), columns: 6,
                        selected: activeMinute % 60, component: String(localized: "分钟")) {
                    setActive(activeMinute / 60 * 60 + $0)
                }
            }

            if allowsEnd {
                HStack(spacing: 6) {
                    ForEach([30, 60, 120], id: \.self) { duration in
                        Button(duration < 60 ? "30 分钟" : "\(duration / 60) 小时") { setDuration(duration) }
                            .buttonStyle(PlannerActionStyle(theme: theme))
                    }
                }
                if !endText.isEmpty && (endDayOffset > 0 || (start ?? 0) >= (end ?? Int.max)) {
                    PlannerToggle(title: endDayOffset > 1 ? String(localized: "+\(endDayOffset) 天结束") : String(localized: "次日结束"),
                                  selected: Binding(get: { endDayOffset > 0 }, set: { endDayOffset = $0 ? 1 : 0 }),
                                  theme: theme)
                        .onChange(of: endDayOffset) { _, _ in error = nil }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if allowsClear && hadStart {
                    Button("清除时段") { commit(.init()) }
                        .buttonStyle(.plain).font(.subheadline).foregroundStyle(theme.quiet)
                }
                Spacer()
                Button("确定", action: confirm)
                    .buttonStyle(PlannerActionStyle(theme: theme, primary: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(15)
        .frame(width: 316)
        .background(theme.paper)
        .foregroundStyle(theme.ink)
        .tint(theme.accent)
        .onChange(of: focus) { _, field in
            if let field { active = field }
        }
        .onChange(of: startText) { _, _ in error = nil }
        .onChange(of: endText) { _, _ in error = nil }
    }

    private var start: Int? { PlannerClockTime.parse(startText) }
    private var end: Int? { PlannerClockTime.parse(endText) }
    private var activeMinute: Int { active == .end ? (end ?? start ?? 540) : (start ?? 540) }

    private func input(_ title: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { active = field; focus = nil } label: {
                Text(title.localized + (active == field ? "  ·" : ""))
                    .font(.caption.weight(active == field ? .semibold : .regular))
                    .foregroundStyle(active == field ? theme.accent : theme.quiet)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "选择\(title.localized)"))
            .accessibilityAddTraits(active == field ? [.isSelected] : [])
            TextField(field == .end ? "可留空" : "09:00", text: text)
                .textFieldStyle(.plain)
                .font(.system(.title3).monospacedDigit())
                .padding(.horizontal, 8)
                .frame(height: 36)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(active == field ? theme.accent.opacity(0.7) : theme.line)
                        .allowsHitTesting(false)
                }
                .focused($focus, equals: field)
                .accessibilityLabel(title.localized)
                .accessibilityIdentifier(field == .start ? "plannerTimeStart" : "plannerTimeEnd")
        }
    }

    private func choices(_ values: [Int], columns: Int, selected: Int, component: String,
                         choose: @escaping (Int) -> Void) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
            ForEach(values, id: \.self) { value in
                Button { choose(value) } label: {
                    Text(twoDigits(value))
                        .font(.subheadline.monospacedDigit())
                        .frame(maxWidth: .infinity, minHeight: 29)
                        .background(value == selected ? theme.wash : theme.surface,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(value == selected ? theme.accent : theme.ink)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(value) \(component.localized)")
                .accessibilityAddTraits(value == selected ? [.isSelected] : [])
            }
        }
    }

    private func twoDigits(_ number: Int) -> String { String(format: "%02d", number) }

    private func setActive(_ minute: Int) {
        if active == .start { startText = PlannerClockTime.label(minute) }
        else { endText = PlannerClockTime.label(minute) }
        focus = nil
    }

    private func setDuration(_ duration: Int) {
        guard let start else {
            error = String(localized: "请先选择开始时间。")
            return
        }
        let finish = start + duration
        endText = PlannerClockTime.label(finish)
        endDayOffset = finish / PlannerClockTime.minutesPerDay
        active = .end
        focus = nil
    }

    private func confirm() {
        guard let start else { error = String(localized: "请输入有效的开始时间。"); return }
        var finish: Int?
        if allowsEnd && (requiresEnd || !endText.trimmed.isEmpty) {
            guard let end else { error = String(localized: "请选择有效的结束时间。"); return }
            let minute = end + endDayOffset * PlannerClockTime.minutesPerDay
            guard minute > start else { error = String(localized: "结束时间要晚于开始时间。"); return }
            finish = minute
        }
        commit(.init(start: start, end: finish))
    }

    private func commit(_ selection: PlannerTimeSelection) {
        do { try apply(selection) }
        catch { self.error = error.localizedDescription }
    }
}
