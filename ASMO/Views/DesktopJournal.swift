import SwiftUI

struct DesktopJournalSection<Content: View>: View {
    let date: PlanDate
    let weekday: String
    let isToday: Bool
    let showYear: Bool
    let theme: PlannerTheme
    let expanded: Bool
    var motion: DesktopTaskMotion? = nil
    /// Today only: done / total, a small ring beside the heading.
    var progress: (done: Int, total: Int)? = nil
    let toggleDay: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: toggleDay) {
            HStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: expanded ? 12 : 8) {
                    let label = Text(expanded ? "\(date.month) 月 \(date.day ?? 1) 日" : String(format: "%02d.%02d", date.month, date.day ?? 1))
                        .font(.system(size: expanded ? 34 : 17, weight: .semibold).monospacedDigit())
                        .tracking(expanded ? -0.7 : 0)
                        .foregroundStyle(expanded || !isToday ? theme.ink : theme.accent)
                        .lineLimit(1)
                        .fixedSize()
                    if let motion { motion.label(label, id: "day-" + date.key) } else { label }
                    Text(dateContext)
                        .font(.system(size: expanded ? 13 : 11, weight: isToday ? .medium : .regular))
                        .foregroundStyle(isToday ? theme.accent : theme.quiet)
                        .fixedSize()
                }
                .frame(minWidth: 135, alignment: .leading)
                HStack(spacing: 7) { content }
                    .font(.subheadline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if expanded, let progress {
                    ProgressRing(done: progress.done, total: progress.total, theme: theme)
                }
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.quiet)
                    .frame(width: 22)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: expanded ? 76 : 45, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(DesktopButtonStyle(theme: theme))
        .accessibilityLabel("\(expanded ? "收起" : "展开")\(date.label)")
        .accessibilityIdentifier(expanded ? "agendaDate-\(date.key)" : "journalDay-\(date.key)")
        .help(expanded ? "收起当天" : "展开当天")
    }

    private var dateContext: String {
        if isToday { return weekday + String(localized: " · 今天") }
        if showYear { return "\(date.year) · " + weekday }
        return weekday
    }
}

struct DesktopJournalTask: View {
    let entry: TimelineEntry
    let calendar: Calendar
    let theme: PlannerTheme
    var motion: DesktopTaskMotion?
    /// Drawn at rest in the writing view: time inline before the title on one line, a click does nothing to
    /// the text (double-clicking the day opens it for writing), the checkbox still works.
    var frozen = false
    @State private var hovering = false
    @State private var draft: String?
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let toggle = entry.toggle {
                Button(action: toggle) {
                    ASMOCheckbox(complete: entry.completed, theme: theme)
                        .frame(width: 34, height: frozen ? 30 : 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(DesktopButtonStyle(theme: theme))
                .accessibilityLabel((entry.completed ? "恢复 " : "完成 ") + entry.title)
            } else {
                ASMOIcon(mark: .calendar, size: 15)
                    .frame(width: 34)
                    .foregroundStyle(theme.quiet)
            }

            // Time first, in its own column: the day reads top to bottom like a schedule.
            if frozen {
                frozenTitle
            } else {
            timeColumn
            }
            if frozen {
            } else if entry.rename != nil {
                inlineTitle
            } else {
            Button(action: entry.edit) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        let title = Text(entry.title)
                            .font(.body)
                            .strikethrough(entry.completed)
                            .foregroundStyle(entry.completed ? theme.quiet : theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if let motion { motion.label(title, id: entry.id) }
                        else { title }
                        if !entry.completed && !entry.detail.isEmpty {
                            Text(entry.detail)
                                .font(.caption)
                                .foregroundStyle(theme.quiet)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(DesktopButtonStyle(theme: theme))
            .accessibilityHint("打开编辑")
            }
            if hovering, let makeRoutine = entry.makeRoutine {
                Button(action: makeRoutine) {
                    Image(systemName: "repeat")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(theme.quiet)
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("设为每日任务（每天这个时间都出现）")
                .accessibilityLabel("把 \(entry.title) 设为每日任务")
            }
            #if os(macOS)
            if let delete = entry.delete {
                PlannerDeleteButton(title: entry.title, theme: theme, visible: hovering, action: delete)
            }
            #endif
        }
        .padding(.leading, CGFloat(entry.depth) * (frozen ? 26 : Self.indent))
        .onHover { hovering = $0 }
        #if os(iOS)
        // Touch: no hover controls; the row's actions live in a long-press menu.
        .contextMenu {
            if let makeRoutine = entry.makeRoutine {
                Button("设为每日", systemImage: "repeat", action: makeRoutine)
            }
            if let delete = entry.delete {
                Button("删除", systemImage: "trash", role: .destructive, action: delete)
            }
        }
        #endif
    }

    #if os(iOS)
    private static let indent: CGFloat = 24
    #else
    private static let indent: CGFloat = 30
    #endif

    /// The title is plain text you click to edit, like a line in a document. Enter or clicking away saves,
    /// Esc cancels, Tab makes it a subtask of the line above, Shift-Tab moves it back out.
    @ViewBuilder
    private var inlineTitle: some View {
        if let current = draft {
            TextField("待办", text: Binding(get: { draft ?? current }, set: { draft = $0 }))
                .textFieldStyle(.plain)
                .font(.body)
                .focused($editing)
                .onSubmit(commit)
                .onKeyPress(.escape) { draft = nil; return .handled }
                .onKeyPress(.tab, phases: .down) { press in
                    commit()
                    if press.modifiers.contains(.shift) { entry.outdent?() } else { entry.indent?() }
                    return .handled
                }
                .onChange(of: editing) { _, focused in if !focused { commit() } }
                .task { editing = true }
                .padding(.vertical, 4).padding(.trailing, 8)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .accessibilityIdentifier("taskTitleField")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                let link = TextLinks.first(in: entry.title)
                let shown = link.map { entry.title.replacingCharacters(in: $0.range, with: "").trimmed } ?? entry.title
                let styled = entry.completed ? Text(shown.isEmpty ? entry.title : shown)
                    : Text(shown.isEmpty ? entry.title : shown).titleStyle(entry.titleStyle)
                let title = styled
                    .font(.body)
                    .strikethrough(entry.completed)
                    .foregroundStyle(entry.completed ? theme.quiet : theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let motion { motion.label(title, id: entry.id) }
                    else { title }
                    if let link, !shown.isEmpty { LinkChip(url: link.url, theme: theme) }
                    if let tag = entry.tag {
                        Text(tag)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(theme.quiet)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay { Capsule().strokeBorder(theme.line) }
                            .contentShape(Capsule())
                            .onTapGesture { entry.editTag?() }
                            .help("改成每周哪几天重复，或不再重复")
                    }
                }
                if !entry.completed && !entry.detail.isEmpty {
                    Text(entry.detail).font(.caption).foregroundStyle(theme.quiet).lineLimit(1)
                }
            }
            .padding(.vertical, 4).padding(.trailing, 8)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { draft = entry.title }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("点一下修改文字，拖动可以改到别的日子")
            .help("点一下修改 · 拖到别的日子改期 · Tab 变成子任务")
        }
    }

    /// At rest: "14:00–14:30 自重深蹲  # 每天" on one line, like the page it came from.
    private var frozenTitle: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let timeLabel, entry.start != nil {
                Text(timeLabel)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(entry.completed ? theme.quiet : theme.accent)
                    .fixedSize()
            }
            let link = TextLinks.first(in: entry.title)
            let shown = link.map { entry.title.replacingCharacters(in: $0.range, with: "").trimmed } ?? entry.title
            (entry.completed ? Text(shown.isEmpty ? entry.title : shown) : Text(shown.isEmpty ? entry.title : shown).titleStyle(entry.titleStyle))
                .font(.system(size: 14.5))
                .strikethrough(entry.completed)
                .foregroundStyle(entry.completed ? theme.quiet : theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                // Italic for Chinese is a slant (its fonts have no italic face).
                .transformEffect((entry.titleStyle ?? "").split(separator: " ").contains("i") && !entry.completed
                                 ? CGAffineTransform(a: 1, b: 0, c: -0.18, d: 1, tx: 3, ty: 0) : .identity)
            if let link, !shown.isEmpty { LinkChip(url: link.url, theme: theme) }
            if let tag = entry.tag {
                Text("# " + tag)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.accent.opacity(entry.completed ? 0.55 : 0.95))
                    .padding(.horizontal, 7).padding(.vertical, 2.5)
                    .background(theme.accent.opacity(0.13), in: Capsule())
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
    }

    private func commit() {
        guard let value = draft else { return }
        draft = nil
        let title = value.trimmed
        if !title.isEmpty && title != entry.title { entry.rename?(title) }
    }

    @ViewBuilder
    private var timeColumn: some View {
        #if os(iOS)
        // Phone width: untimed rows give the space to the title; a time sits before it when there is one.
        if entry.start != nil || timeLabel != nil { timeCell.frame(width: 50, alignment: .leading) }
        #else
        timeCell.frame(width: 54, alignment: .leading)
        #endif
    }

    @ViewBuilder
    private var timeCell: some View {
        Group {
            if let timeEdit = entry.timeEdit {
                PlannerTimeButton(selection: timeEdit.selection, theme: theme, label: String(localized: "编辑\(entry.title)的时段"),
                                  compact: true, column: true, save: timeEdit.save)
                    .accessibilityIdentifier("agenda-time-" + entry.id)
                    // No time yet: the clock only shows on hover, so untimed rows stay quiet.
                    .opacity(entry.start != nil || hovering ? 1 : 0)
            } else if let timeLabel {
                let parts = timeLabel.components(separatedBy: "–")
                VStack(alignment: .leading, spacing: 0) {
                    Text(parts[0])
                        .font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
                        .foregroundStyle(entry.start == nil ? theme.quiet : theme.ink.opacity(0.8))
                    if parts.count > 1 {
                        Text("–" + parts[1]).font(.caption2.monospacedDigit()).foregroundStyle(theme.quiet)
                    }
                }
                .fixedSize()
            }
        }
    }

    private var timeLabel: String? {
        if let start = entry.start {
            let startText = DayTimeline.time(start, calendar: calendar)
            return entry.end.map { startText + "–" + DayTimeline.time($0, calendar: calendar) } ?? startText
        }
        return entry.isTask ? nil : String(localized: "全天")
    }
}

/// A quiet × that appears on hover and removes the row outright (not the same as completing it).
struct PlannerDeleteButton: View {
    let title: String
    let theme: PlannerTheme
    let visible: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(hovering ? theme.ink : theme.quiet)
                .frame(width: 26, height: 26)
                .background(hovering ? theme.surface : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(visible || hovering ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: visible)
        .onHover { hovering = $0 }
        .help("删除这条（可撤销）")
        .accessibilityLabel(String(localized: "删除 ") + title)
        .accessibilityIdentifier("delete-" + title)
    }
}

struct DesktopJournalText: View {
    let value: JournalArchiveText
    let label: String
    let theme: PlannerTheme
    let save: (JournalArchiveText) -> Void
    var original: (() -> Void)? = nil
    var startsEditing = false
    var endEditing: (() -> Void)? = nil
    @State private var draft: JournalArchiveText?
    @FocusState private var focused: Bool

    var body: some View {
        Group {
        if let current = draft {
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: Binding(get: { draft?.text ?? "" }, set: { draft?.text = $0 }))
                    .font(.subheadline)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 74, maxHeight: 128)
                    .modifier(PlannerFieldStyle(theme: theme))
                    .focused($focused)
                    .accessibilityLabel(label)
                    .task {
                        try? await Task.sleep(for: .milliseconds(45))
                        if !Task.isCancelled { focused = true }
                    }
                HStack(spacing: 8) {
                    if original != nil {
                        Button(current.completed ? "取消划线" : "标记完成") { draft?.completed.toggle() }
                            .buttonStyle(.plain).foregroundStyle(theme.quiet)
                    }
                    Spacer()
                    Button("取消") { draft = nil; endEditing?() }.buttonStyle(.plain)
                    Button("保存") { if let draft { save(draft) }; self.draft = nil }
                        .buttonStyle(.plain).foregroundStyle(theme.accent)
                }
                .font(.caption.weight(.medium))
            }
        } else {
            Button { draft = value } label: {
                Text(value.text.isEmpty ? "编辑\(label)…" : value.text)
                    .font(.subheadline)
                    .strikethrough(value.completed)
                    .foregroundStyle(value.completed || value.text.isEmpty ? theme.quiet : theme.ink)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2).contentShape(Rectangle())
            }
            .buttonStyle(DesktopButtonStyle(theme: theme))
            .accessibilityHint("编辑\(label)")
            .contextMenu {
                Button("编辑\(label)") { draft = value }
                if let original {
                    Button("查看石墨原文", action: original)
                    Button(value.completed ? "取消划线" : "标记完成") {
                        var changed = value
                        changed.completed.toggle()
                        save(changed)
                    }
                }
            }
        }
        }
        .onAppear { if startsEditing { draft = value } }
    }
}

/// Today's progress beside the heading: a thin ring that fills as items are checked, and "3/6".
struct ProgressRing: View {
    let done: Int
    let total: Int
    let theme: PlannerTheme

    var body: some View {
        let fraction = total == 0 ? 0 : Double(done) / Double(total)
        HStack(spacing: 7) {
            ZStack {
                Circle().stroke(theme.line, lineWidth: 2.5)
                Circle().trim(from: 0, to: fraction)
                    .stroke(theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 15, height: 15)
            Text(done == total ? "全部完成" : "\(done)/\(total)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(done == total ? theme.accent : theme.quiet)
                .contentTransition(.numericText())
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: done)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("今天完成 \(done) / \(total)")
    }
}
