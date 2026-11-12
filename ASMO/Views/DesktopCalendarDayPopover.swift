import SwiftUI

struct DesktopCalendarDayPopover: View {
    let date: PlanDate
    let items: [CalendarDayItem]
    let theme: PlannerTheme
    let close: () -> Void
    let openDay: () -> Void
    let add: (String) throws -> Void
    @State private var composing = false
    @State private var title = ""
    @State private var error: String?
    @State private var hoveredItem: String?
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(AppLanguage.dayTitle(month: date.month, day: date.day ?? 1))
                    .font(.system(size: 19, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: close) {
                    ASMOIcon(mark: .close, size: 13).foregroundStyle(theme.quiet)
                        .frame(width: 27, height: 27).contentShape(Rectangle())
                }
                .buttonStyle(DesktopButtonStyle(theme: theme))
                .accessibilityLabel("关闭日期详情")
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 10)

            if items.isEmpty {
                Text("这天还没有安排").font(.subheadline).foregroundStyle(theme.quiet)
                    .padding(.horizontal, 15).padding(.bottom, 12)
            } else {
                ViewThatFits(in: .vertical) {
                    rows
                    ScrollView { rows }
                }
                .frame(maxHeight: 278)
                .padding(.horizontal, 9)
                .padding(.bottom, 8)
            }

            Rectangle().fill(theme.line).frame(height: 1)
            if composing {
                HStack(spacing: 8) {
                    TextField("待办标题", text: $title, prompt: Text("记一件事…"))
                        .textFieldStyle(.plain)
                        .modifier(PlannerFieldStyle(theme: theme))
                        .focused($typing)
                        .onSubmit(commit)
                        .accessibilityIdentifier("calendarQuickTitle")
                        .task { typing = true }
                    Button("添加", action: commit)
                        .buttonStyle(DesktopButtonStyle(theme: theme))
                        .foregroundStyle(theme.accent)
                        .disabled(title.trimmed.isEmpty)
                }
                .padding(.horizontal, 14).padding(.top, 10)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 14).padding(.top, 8)
            }
            HStack(spacing: 8) {
                Button {
                    if composing { composing = false; typing = false }
                    else { composing = true }
                } label: {
                    HStack(spacing: 4) {
                        if !composing { ASMOIcon(mark: .plus, size: 12) }
                        Text(composing ? "取消" : "添加待办")
                    }
                    .foregroundStyle(theme.quiet)
                    .padding(.horizontal, 6).frame(height: 30).contentShape(Rectangle())
                }
                .buttonStyle(DesktopButtonStyle(theme: theme))
                Spacer(minLength: 0)
                Button(action: openDay) {
                    HStack(spacing: 4) {
                        Text("在逐日中编辑")
                        ASMOIcon(mark: .right, size: 12)
                    }
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 6).frame(height: 30).contentShape(Rectangle())
                }
                .buttonStyle(DesktopButtonStyle(theme: theme))
                .accessibilityIdentifier("calendarOpenJournal")
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 9).padding(.vertical, 6)
        }
        .frame(width: 332)
        .background(theme.paper)
        .foregroundStyle(theme.ink)
    }

    private var rows: some View {
        VStack(spacing: 2) {
            ForEach(items) { item in
                HStack(spacing: 3) {
                    if let toggle = item.toggle {
                        Button(action: toggle) {
                            ASMOCheckbox(complete: item.completed, theme: theme)
                                .frame(width: 29, height: 32).contentShape(Rectangle())
                        }
                        .buttonStyle(DesktopButtonStyle(theme: theme))
                        .accessibilityLabel((item.completed ? "恢复 " : "完成 ") + item.title)
                    } else {
                        ASMOIcon(mark: item.icon, size: 14).frame(width: 29)
                            .foregroundStyle(item.kind == .occasion ? theme.accent : theme.quiet)
                    }
                    if let open = item.open {
                        // Plain text with a tap, not a button, so the row can also be dragged to another day.
                        rowLabel(item)
                            .onTapGesture { close(); open() }
                            .accessibilityAddTraits(.isButton)
                            .help((item.openHint ?? String(localized: "在逐日中打开")) + String(localized: " · 拖到日历上的另一天即可改期"))
                    } else {
                        rowLabel(item)
                    }
                    if let timeEdit = item.timeEdit {
                        PlannerTimeButton(selection: timeEdit.selection, theme: theme, label: String(localized: "编辑\(item.title)的时段"),
                                          compact: true, save: timeEdit.save)
                    } else if let start = item.startMinute {
                        Text(PlannerClockTime.label(start)).font(.caption.monospacedDigit())
                            .foregroundStyle(theme.quiet).padding(.trailing, 6)
                    }
                }
                .frame(minHeight: 34)
                .overlay(alignment: .trailing) {
                    if let delete = item.delete, hoveredItem == item.id {
                        PlannerDeleteButton(title: item.title, theme: theme, visible: true, action: delete)
                            .background(theme.paper, in: Circle())
                    }
                }
                .onHover { inside in
                    if inside { hoveredItem = item.id } else if hoveredItem == item.id { hoveredItem = nil }
                }
                .plannerDraggable(item.dragID, title: item.title, theme: theme)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func rowLabel(_ item: CalendarDayItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title).font(.subheadline).strikethrough(item.completed)
                .foregroundStyle(item.kind == .occasion ? theme.accent : item.completed ? theme.quiet : theme.ink)
            if let detail = item.detail {
                Text(detail).font(.caption).foregroundStyle(theme.quiet)
                    .lineLimit(item.kind == .archive || item.kind == .note ? 4 : 2)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func commit() {
        guard !title.trimmed.isEmpty else { return }
        do {
            try add(title.trimmed)
            title = ""
            error = nil
            typing = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}
