import SwiftUI

struct TimelineTimeEdit {
    let selection: PlannerTimeSelection
    let save: (PlannerTimeSelection) throws -> Void
}

struct TimelineEntry: Identifiable {
    let id: String
    let title: String
    let detail: String
    let start: Date?
    let end: Date?
    let completed: Bool
    let toggle: (() -> Void)?
    let edit: () -> Void
    var timeEdit: TimelineTimeEdit? = nil
    /// Set when the entry can be dragged to another day.
    var dragID: String? = nil
    /// Set when the entry can be removed with one click (local tasks).
    var delete: (() -> Void)? = nil
    /// Set when the title can be edited in place (local tasks).
    var rename: ((String) -> Void)? = nil
    var depth = 0
    var indent: (() -> Void)? = nil
    var outdent: (() -> Void)? = nil
    /// A small label beside the title ("每天", "每周一四"); tapping it runs `editTag`.
    var tag: String? = nil
    var editTag: (() -> Void)? = nil
    /// Turns a one-off task into a 每日 routine.
    var makeRoutine: (() -> Void)? = nil
    var titleStyle: String? = nil

    var isTask: Bool { toggle != nil }
}

@MainActor
struct DayTimeline {
    #if !os(macOS)
    let entries: [TimelineEntry]
    let selected: PlanDate
    let theme: PlannerTheme
    @ScaledMetric(relativeTo: .caption) private var timeWidth = 52.0

    var body: some View {
        TimelineView(.everyMinute) { tick in
            let clock = CaptureClock(now: tick.date)
            let now = selected == clock.today && !entries.isEmpty ? tick.date : nil
            let insertion = now.flatMap { instant in
                entries.firstIndex { ($0.start ?? .distantPast) > instant } ?? entries.count
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, item in
                    if insertion == index { pointer(tick.date, calendar: clock.calendar) }
                    row(item, calendar: clock.calendar)
                }
                if insertion == entries.count { pointer(tick.date, calendar: clock.calendar) }
            }
        }
    }

    private func row(_ item: TimelineEntry, calendar: Calendar) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.start.map { Self.time($0, calendar: calendar) } ?? "全天")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                if let end = item.end {
                    Text("到 \(Self.time(end, calendar: calendar))").font(.caption2.monospacedDigit())
                        .foregroundStyle(theme.quiet).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            .frame(width: timeWidth, alignment: .leading)
            ZStack {
                Rectangle().fill(theme.line).frame(width: 1)
                if item.isTask && item.end != nil {
                    Capsule().fill(theme.accent).frame(width: 3, height: 23)
                } else {
                    Circle().fill(theme.paper)
                        .overlay { Circle().strokeBorder(item.isTask ? theme.accent : theme.quiet, lineWidth: 1) }
                        .frame(width: 7, height: 7)
                }
            }
            .frame(width: 15)
            HStack(spacing: 8) {
                if let toggle = item.toggle {
                    Button(action: toggle) {
                        ASMOCheckbox(complete: item.completed, theme: theme)
                            .frame(width: 32).frame(minHeight: 44)
                            .contentShape(Rectangle())
                            .foregroundStyle(item.completed ? theme.accent : theme.quiet)
                    }
                    .accessibilityLabel(item.completed ? "恢复 \(item.title)" : "完成 \(item.title)")
                } else {
                    ASMOIcon(mark: .calendar, size: 16)
                        .frame(width: 25).foregroundStyle(theme.quiet).accessibilityHidden(true)
                }
                Button(action: item.edit) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.subheadline.weight(.semibold)).strikethrough(item.completed)
                            .foregroundStyle(item.completed ? theme.quiet : theme.ink)
                        if !item.detail.isEmpty {
                            Text(item.detail).font(.caption).foregroundStyle(theme.quiet).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(item.isTask && item.end != nil ? theme.wash : theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(theme.line) }
            .padding(.vertical, 4)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func pointer(_ now: Date, calendar: Calendar) -> some View {
        HStack(spacing: 8) {
            Text(Self.time(now, calendar: calendar)).font(.caption.weight(.semibold).monospacedDigit())
                .frame(width: timeWidth, alignment: .leading)
            ZStack {
                Rectangle().fill(theme.line).frame(width: 1)
                ASMOIcon(mark: .pointer, size: 15)
                    .background(theme.paper, in: Circle())
            }
            .frame(width: 15)
            Text("现在").font(.caption2.weight(.semibold))
            Rectangle().fill(LinearGradient(colors: [theme.accent.opacity(0.7), .clear],
                                             startPoint: .leading, endPoint: .trailing)).frame(height: 1)
        }
        .foregroundStyle(theme.accent)
        .frame(height: 29)
        .accessibilityElement(children: .combine)
    }

    #endif

    static func time(_ date: Date, calendar: Calendar) -> String {
        let time = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", time.hour ?? 0, time.minute ?? 0)
    }
}

#if !os(macOS)
extension DayTimeline: View {}
#endif
