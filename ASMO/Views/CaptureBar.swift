#if os(macOS)
import AppKit
#endif
import SwiftUI

/// The floating capture bar near the bottom of the window. Collapsed it is a small round mic;
/// one click expands it into a rounded field for typing or speaking. Enter files everything, with today as the default day.
struct CaptureBar: View {
    @Binding var text: String
    @Binding var expanded: Bool
    let preview: [DictatedItem]
    /// When the text is an instruction about an existing item, what it will do.
    let command: String?
    let recording: Bool
    let transcribing: Bool
    let theme: PlannerTheme
    let today: PlanDate
    /// Friendly day names: 今天 / 明天 / 后天 / 周二 / 下周二 / 11/20.
    let dayName: (PlanDate) -> String
    let toggleVoice: () -> Void
    let submit: () -> Void
    @FocusState private var focused: Bool
    @State private var frame: CGRect = .zero
    @State private var clickMonitor: Any?

    var body: some View {
        VStack(spacing: 8) {
            if expanded && !recording, let command {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars").foregroundStyle(theme.accent)
                    Text(command).font(.subheadline)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
                .frame(maxWidth: 620, alignment: .leading)
                .background(theme.paper.opacity(0.97), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.line) }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .accessibilityIdentifier("captureBarCommand")
            } else if expanded && !preview.isEmpty && !recording {
                previewCard.transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if expanded { bar } else { collapsed }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: expanded)
        .animation(.smooth(duration: 0.18), value: preview.count)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { frame = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, value in frame = value }
            }
        }
        .onChange(of: expanded) { _, open in open ? watchOutsideClicks() : stopWatching() }
        .onAppear { if expanded { watchOutsideClicks() } }
        .onDisappear(perform: stopWatching)
    }

    /// Any click outside the bar (and its preview) folds it back into the small button, like a popover.
    /// Clicks on empty areas don't move keyboard focus on macOS, so focus alone can't tell us.
    private func watchOutsideClicks() {
        #if os(macOS)
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            guard let height = event.window?.contentView?.bounds.height else { return event }
            let point = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
            if !frame.insetBy(dx: -6, dy: -6).contains(point), !recording, !transcribing {
                expanded = false
            }
            return event
        }
        #endif
    }

    private func stopWatching() {
        #if os(macOS)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        #endif
    }

    /// Collapsed: a quiet floating pill that says what it does (write or speak one thing), not a bare icon.
    private var collapsed: some View {
        Button {
            expanded = true
        } label: {
            HStack(spacing: 8) {
                #if os(iOS)
                // On iPhone it's for typing (the keyboard has its own dictation key).
                Image(systemName: "square.and.pencil").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text(text.trimmed.isEmpty ? "记一件事" : "继续草稿")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.ink.opacity(0.82))
                #else
                ASMOIcon(mark: .mic, size: 15)
                    .foregroundStyle(theme.accent)
                Text(text.trimmed.isEmpty ? "写或说" : "继续草稿")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.ink.opacity(0.82))
                #endif
                #if os(macOS)
                Text("⌘K")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.quiet)
                    .padding(.horizontal, 5).frame(height: 18)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                #endif
            }
            .padding(.leading, 16).padding(.trailing, Self.trailingInset)
            .frame(height: 42)
            .floatingSurface(theme)
            .contentShape(Capsule())
        }
        .buttonStyle(FloatingPressStyle())
        .help("写或说一件事 · ⌘K")
        .accessibilityLabel("打开快速记录")
        .accessibilityIdentifier("captureBarOpen")
    }

    #if os(macOS)
    private static let hint = String(localized: "写或说：明天下午三点开会 · 把理发挪到周二 · 删掉看房")
    #else
    private static let hint = String(localized: "明天下午三点开会…")
    #endif

    #if os(macOS)
    private static let trailingInset: CGFloat = 10
    #else
    private static let trailingInset: CGFloat = 18
    #endif

    private var bar: some View {
        HStack(spacing: 10) {
            if recording {
                Circle().fill(Color(red: 0.93, green: 0.36, blue: 0.2)).frame(width: 9, height: 9)
                    .phaseAnimator([0.8, 1.3]) { $0.scaleEffect($1) } animation: { _ in .easeInOut(duration: 0.55) }
                    .padding(.leading, 4)
            }
            #if os(iOS)
            // Put the keyboard away (the draft stays).
            Button { focused = false; expanded = false } label: {
                Image(systemName: "chevron.down").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.quiet)
                    .frame(width: 30, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("收起")
            .accessibilityIdentifier("captureBarClose")
            #endif
            TextField("快速记录", text: $text,
                      prompt: Text(recording ? "正在听… 再点一下麦克风结束" : transcribing ? "正在转写…"
                                   : Self.hint),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...4)
                .focused($focused)
                .accessibilityIdentifier("captureBarField")
                .onKeyPress(.return, phases: .down) { press in
                    guard !press.modifiers.contains(.shift) else { return .ignored }
                    submit()
                    return .handled
                }
                .onKeyPress(.escape) {
                    focused = false
                    expanded = false
                    return .handled
                }
                .accessibilityIdentifier("captureBarInput")
                #if os(iOS)
                // The on-screen keyboard's return types a newline in a multi-line field: treat it as 发送.
                .submitLabel(.send)
                .onChange(of: text) { _, value in
                    guard value.hasSuffix("\n") else { return }
                    text = String(value.dropLast())
                    submit()
                }
                #endif
            #if os(macOS)
            Button { focused = true; toggleVoice() } label: {
                ASMOIcon(mark: recording ? .stop : .mic, size: 15)
                    .foregroundStyle(recording ? theme.onAccent : theme.accent)
                    .frame(width: 32, height: 32)
                    .background(recording ? theme.accent : theme.wash.opacity(0.6),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(transcribing)
            .help(recording ? "结束并转写" : "语音输入")
            .accessibilityLabel(recording ? "结束录音" : "语音输入")
            .accessibilityIdentifier("captureBarMic")
            #endif
            if !text.trimmed.isEmpty && !recording {
                Button(action: submit) {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.onAccent)
                        .frame(width: 32, height: 32)
                        .background(theme.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("记下 · ↵")
                .accessibilityLabel("记下")
                .accessibilityIdentifier("captureBarSend")
            }
        }
        .padding(.leading, 18).padding(.trailing, 7).padding(.vertical, 7)
        .frame(minHeight: 46)
        .frame(maxWidth: 620)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.paper)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(focused ? theme.accent.opacity(0.55) : theme.line)
                }
                .shadow(color: .black.opacity(theme.dark ? 0.45 : 0.16), radius: 18, y: 6)
        }
        .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
        // Focus once the bar has appeared (asking during its animation is ignored on iPhone).
        .task { try? await Task.sleep(for: .milliseconds(120)); focused = true }
        .onChange(of: expanded) { _, open in if open { focused = true } }
        .onChange(of: focused) { was, isFocused in
            // Only losing focus folds it: a focus request that hasn't landed yet is not a click elsewhere.
            guard was, !isFocused else { return }
            // Clicking anywhere else folds the bar back into the small button (the draft stays).
            // A short grace period lets clicks on the bar's own buttons keep it open.
            Task {
                try? await Task.sleep(for: .milliseconds(160))
                if !focused && !recording && !transcribing { expanded = false }
            }
        }
    }

    /// Shows how the text will be filed before Enter: one line per item, with its day and time.
    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(preview.prefix(6).enumerated()), id: \.offset) { _, item in
                HStack(spacing: 10) {
                    Text(when(item))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(theme.accent)
                        .frame(minWidth: 92, alignment: .leading)
                    Text(title(item)).font(.subheadline).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            if preview.count > 6 {
                Text("还有 \(preview.count - 6) 条").font(.caption).foregroundStyle(theme.quiet)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .frame(maxWidth: 620, alignment: .leading)
        .background(theme.paper.opacity(0.97), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.line) }
        .shadow(color: .black.opacity(theme.dark ? 0.35 : 0.1), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("captureBarPreview")
    }

    private func when(_ item: DictatedItem) -> String {
        switch item {
        case .routine(let routine):
            return RoutineParser.label(routine.weekdays) + (routine.startMinute.map { " " + PlannerClockTime.label($0) } ?? "")
        case .task(let draft):
            guard let schedule = draft.schedule else { return String(localized: "未安排") }
            guard schedule.day != nil else { return String(localized: "\(schedule.month) 月") }
            return dayName(schedule.dayOnly) + (schedule.hour.map { String(format: " %02d:%02d", $0, schedule.minute ?? 0) } ?? "")
        }
    }

    private func title(_ item: DictatedItem) -> String {
        switch item {
        case .routine(let routine): routine.title
        case .task(let draft): draft.title
        }
    }
}

/// The floating controls' shared surface: a capsule of frosted paper with a hairline and a soft shadow.
extension View {
    func floatingSurface(_ theme: PlannerTheme) -> some View {
        background {
            Capsule().fill(.regularMaterial)
                .overlay { Capsule().fill(theme.paper.opacity(theme.dark ? 0.55 : 0.7)) }
                .overlay { Capsule().strokeBorder(theme.line) }
                .shadow(color: .black.opacity(theme.dark ? 0.35 : 0.1), radius: 16, y: 6)
        }
    }
}

struct FloatingPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// Appears beside the capture pill only when today is out of view; the arrow points to where it is.
struct TodayButton: View {
    /// -1: today is above, 1: below, 0: elsewhere (another month).
    let direction: Int
    /// The next timed thing today ("13:30 理发"), so the pill also answers "what's next".
    var next: String? = nil
    #if os(iOS)
    private static let nextWidth: CGFloat = 110
    #else
    private static let nextWidth: CGFloat = 220
    #endif
    let theme: PlannerTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: direction < 0 ? "arrow.up" : direction > 0 ? "arrow.down" : "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .semibold))
                Text("今天").font(.system(size: 14, weight: .medium))
                if let next {
                    Text(next)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.ink.opacity(0.75))
                        .lineLimit(1)
                        .frame(maxWidth: Self.nextWidth, alignment: .leading)
                }
            }
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 15)
            .frame(height: 42)
            .floatingSurface(theme)
            .contentShape(Capsule())
        }
        .buttonStyle(FloatingPressStyle())
        .help("回到今天 · ⇧⌘T")
        .accessibilityLabel("回到今天")
        .accessibilityIdentifier("returnToday")
    }
}
