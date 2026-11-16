import SwiftUI

/// One routine as it appears on one day.
struct RoutineInstance: Identifiable {
    let routine: RoutineRecord
    let day: PlanDate
    let done: Bool
    var id: String { routine.id.uuidString + "|" + day.key }
}

/// The "每日" group inside an expanded day: repeating items, checked per day, skipped per day with ×.
struct DesktopRoutineSection: View {
    let instances: [RoutineInstance]
    let theme: PlannerTheme
    let adding: Bool
    let toggle: (RoutineInstance) -> Void
    let skip: (RoutineInstance) -> Void
    let saveTime: (RoutineRecord, PlannerTimeSelection) throws -> Void
    let update: (RoutineRecord, String, Set<Int>) -> Void
    let stop: (RoutineRecord) -> Void
    let add: (String) -> Bool
    let endAdding: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("每日").font(.caption.weight(.semibold)).foregroundStyle(theme.quiet)
                if !instances.isEmpty {
                    Text("\(instances.filter(\.done).count)/\(instances.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(theme.quiet.opacity(0.8))
                }
                Rectangle().fill(theme.line).frame(height: 1)
            }
            .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 2)
            ForEach(instances) { instance in
                DesktopRoutineRow(instance: instance, theme: theme, toggle: { toggle(instance) },
                                  skip: { skip(instance) }, saveTime: { try saveTime(instance.routine, $0) },
                                  update: { update(instance.routine, $0, $1) }, stop: { stop(instance.routine) })
            }
            if adding {
                RoutineAddField(theme: theme, add: add, end: endAdding)
            }
        }
        .padding(.bottom, 6)
    }
}

private struct DesktopRoutineRow: View {
    let instance: RoutineInstance
    let theme: PlannerTheme
    let toggle: () -> Void
    let skip: () -> Void
    let saveTime: (PlannerTimeSelection) throws -> Void
    let update: (String, Set<Int>) -> Void
    let stop: () -> Void
    @State private var hovering = false
    @State private var editing = false

    var body: some View {
        let routine = instance.routine
        HStack(spacing: 6) {
            Button(action: toggle) {
                ASMOCheckbox(complete: instance.done, theme: theme)
                    .frame(width: 34, height: 34).contentShape(Rectangle())
            }
            .buttonStyle(DesktopButtonStyle(theme: theme))
            .accessibilityLabel((instance.done ? "恢复 " : "完成 ") + routine.title)
            Button { editing = true } label: {
                HStack(spacing: 8) {
                    Text(routine.title)
                        .strikethrough(instance.done)
                        .foregroundStyle(instance.done ? theme.quiet : theme.ink)
                    Text(routine.ruleLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(theme.quiet)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay { Capsule().strokeBorder(theme.line) }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4).padding(.trailing, 8)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(DesktopButtonStyle(theme: theme))
            .help("修改名称和重复的日子")
            .popover(isPresented: $editing, arrowEdge: .bottom) {
                RoutineEditor(routine: routine, theme: theme, save: { title, days in update(title, days); editing = false },
                              stop: { editing = false; stop() })
                    .presentationCompactAdaptation(.popover)
            }
            PlannerTimeButton(selection: .init(start: routine.startMinute, end: routine.endMinute), theme: theme,
                              label: String(localized: "\(routine.title)的固定时间（每天都用）"), compact: true, save: saveTime)
            PlannerDeleteButton(title: routine.title, theme: theme, visible: hovering, action: skip)
                .help("今天跳过（不影响其他天）")
        }
        .onHover { hovering = $0 }
    }
}

private struct RoutineAddField: View {
    let theme: PlannerTheme
    let add: (String) -> Bool
    let end: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "repeat").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.accent).frame(width: 22)
            TextField("新的每日任务", text: $text, prompt: Text("例如「每天八点 大眼操」「每周一四 练胸和肩」"))
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit {
                    if add(text) { text = "" }
                    focused = true
                }
                .onKeyPress(.escape) { end(); return .handled }
                .task { focused = true }
                .accessibilityIdentifier("routineInput")
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 38)
        .background(alignment: .bottom) {
            Rectangle().fill(focused ? theme.accent.opacity(0.5) : theme.line).frame(height: 1).padding(.leading, 40)
        }
    }
}

struct RoutineEditor: View {
    let routine: RoutineRecord
    let theme: PlannerTheme
    let save: (String, Set<Int>) -> Void
    let stop: () -> Void
    @State private var title = ""
    @State private var days: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("名称", text: $title)
                .textFieldStyle(.plain)
                .font(.headline)
                .modifier(PlannerFieldStyle(theme: theme))
                .onSubmit(commit)
            HStack(spacing: 5) {
                ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                    let on = days.contains(day)
                    Button {
                        if on, days.count > 1 { days.remove(day) } else { days.insert(day) }
                    } label: {
                        Text(["", "日", "一", "二", "三", "四", "五", "六"][day])
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(on ? theme.onAccent : theme.quiet)
                            .frame(width: 30, height: 30)
                            .background(on ? theme.accent : theme.surface, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "周") + ["", String(localized: "日"), String(localized: "一"), String(localized: "二"), String(localized: "三"), String(localized: "四"), String(localized: "五"), String(localized: "六")][day])
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            HStack {
                Button("不再重复", role: .destructive, action: stop)
                    .buttonStyle(.plain).font(.caption).foregroundStyle(theme.quiet)
                    .help("从今天起不再出现；以前的记录保留")
                Spacer()
                Button("保存", action: commit)
                    .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(theme.accent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 290)
        .background(theme.paper)
        .onAppear { title = routine.title; days = routine.weekdays }
    }

    private func commit() {
        guard !title.trimmed.isEmpty, !days.isEmpty else { return }
        save(title.trimmed, days)
    }
}
