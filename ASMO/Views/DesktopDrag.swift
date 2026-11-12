import SwiftUI

/// Drag payloads for moving planner items between days. Items carry a private prefix so drops can tell
/// a moved ASMO item apart from plain text dragged in from another app, which becomes new tasks instead.
enum PlannerDrag {
    private static let prefix = "asmo-item:"

    static func payload(_ id: String) -> String { prefix + id }

    static func id(from payload: String) -> String? {
        payload.hasPrefix(prefix) ? String(payload.dropFirst(prefix.count)) : nil
    }

    /// Lines of dropped external text, with list markers removed.
    static func titles(from text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { line in
            var value = String(line).trimmed
            for marker in ["- [ ] ", "- [x] ", "[ ] ", "- ", "• ", "* ", "· "] where value.hasPrefix(marker) {
                value = String(value.dropFirst(marker.count)).trimmed
                break
            }
            return value
        }.filter { !$0.isEmpty }
    }
}

struct PlannerDragPreview: View {
    let title: String
    let theme: PlannerTheme

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(theme.accent).frame(width: 6, height: 6)
            Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(theme.ink)
        .padding(.horizontal, 12).frame(height: 30)
        .background(theme.paper, in: Capsule())
        .overlay { Capsule().strokeBorder(theme.accent.opacity(0.45)) }
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        .frame(maxWidth: 280)
    }
}

extension View {
    /// Lets a planner row be picked up and dropped on another day. A no-op when `id` is nil.
    @ViewBuilder
    func plannerDraggable(_ id: String?, title: String, theme: PlannerTheme) -> some View {
        if let id {
            draggable(PlannerDrag.payload(id)) { PlannerDragPreview(title: title, theme: theme) }
                .help("拖到另一天即可改期")
        } else {
            self
        }
    }

    /// Accepts planner items (moved) and plain text (added as tasks) on a given day.
    func plannerDayDrop(_ day: PlanDate, target: Binding<PlanDate?>,
                        perform: @escaping ([String], PlanDate) -> Bool) -> some View {
        dropDestination(for: String.self) { items, _ in
            target.wrappedValue = nil
            return perform(items, day)
        } isTargeted: { active in
            if active { target.wrappedValue = day }
            else if target.wrappedValue == day { target.wrappedValue = nil }
        }
    }
}

/// Short confirmation that appears after a move or drop, with an optional undo.
struct PlannerNotice: Identifiable {
    let id = UUID()
    let text: String
    var undo: (() -> Void)? = nil
    /// A second choice next to 撤销 ("只跳过这天").
    var other: (label: String, action: () -> Void)? = nil
}

struct PlannerNoticeBar: View {
    let notice: PlannerNotice
    let theme: PlannerTheme
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(notice.text).font(.system(size: 12.5, weight: .medium))
            if let undo = notice.undo {
                Button("撤销") { undo(); dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .keyboardShortcut("z", modifiers: .command)
                    .accessibilityIdentifier("noticeUndo")
            }
            if let other = notice.other {
                Button(other.label) { other.action(); dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .accessibilityIdentifier("noticeOther")
            }
        }
        .foregroundStyle(theme.ink)
        .padding(.horizontal, 16).frame(height: 36)
        .background(theme.paper, in: Capsule())
        .overlay { Capsule().strokeBorder(theme.line) }
        .shadow(color: .black.opacity(theme.dark ? 0.35 : 0.12), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("plannerNotice")
        .task(id: notice.id) {
            try? await Task.sleep(for: .seconds(notice.undo == nil ? 2.4 : 5))
            if !Task.isCancelled { dismiss() }
        }
    }
}

#if os(macOS)
/// Calls `action` when the user clicks anywhere outside this view while `active` is true.
/// Needed because clicking empty space on macOS does not move keyboard focus, so blur alone never fires.
struct OutsideClick: ViewModifier {
    let active: Bool
    let action: () -> Void
    @State private var frame: CGRect = .zero
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { frame = proxy.frame(in: .global) }
                        .onChange(of: proxy.frame(in: .global)) { _, value in frame = value }
                }
            }
            .onChange(of: active) { _, on in on ? start() : stop() }
            .onAppear { if active { start() } }
            .onDisappear(perform: stop)
    }

    private func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            guard let height = event.window?.contentView?.bounds.height, event.window?.isKeyWindow == true else { return event }
            let point = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
            if !frame.insetBy(dx: -4, dy: -4).contains(point) {
                DispatchQueue.main.async(execute: action)
            }
            return event
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension View {
    func onOutsideClick(active: Bool, perform action: @escaping () -> Void) -> some View {
        modifier(OutsideClick(active: active, action: action))
    }
}
#else
extension View {
    /// iPhone: there is no "click outside"; the page closes with 完成 or by tapping another day.
    func onOutsideClick(active: Bool, perform action: @escaping () -> Void) -> some View { self }
}
#endif
