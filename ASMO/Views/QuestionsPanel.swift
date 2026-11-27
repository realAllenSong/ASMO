#if os(macOS)
import AppKit
import SwiftUI

/// The small window beside the planner where agents' questions wait (`asmo ask`), like a sticky note: each card says
/// what is to be decided, why it is asked and what the agent suggests, with ✗ and ✓ under it. It shows while 逐日 is
/// the active app and hides with it, so it never sits over other apps; the Dock icon carries the count meanwhile.
@MainActor
final class QuestionsPanel: NSObject, NSWindowDelegate {
    static let shared = QuestionsPanel()

    private var panel: NSPanel?
    /// Closed by the person: it stays closed until a new question comes (or they open it from the rail).
    private var dismissed = false
    private var watching = false

    /// Called once the app is up: the panel comes forward with the app when questions wait.
    func start() {
        guard !watching else { return }
        watching = true
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { QuestionsPanel.shared.showIfWaiting() }
        }
        // The light/dark setting of the planner applies here too.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { QuestionsPanel.shared.applyAppearance() }
        }
        showIfWaiting()
    }

    func questionsArrived() {
        dismissed = false
        if NSApp.isActive { show() }
    }

    func showIfWaiting() {
        if !dismissed, !QuestionDesk.shared.open.isEmpty { show() }
    }

    func show() {
        let panel = panel ?? make()
        self.panel = panel
        applyAppearance()
        if !panel.isVisible { place(panel) }
        panel.orderFront(nil)
    }

    func close() {
        dismissed = true
        panel?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    func applyAppearance() {
        let setting = UserDefaults.standard.string(forKey: "desktopAppearance") ?? DesktopAppearance.light.rawValue
        let name: NSAppearance.Name? = setting == DesktopAppearance.dark.rawValue ? .darkAqua
            : setting == DesktopAppearance.light.rawValue ? .aqua : nil
        if panel?.appearance?.name != name { panel?.appearance = name.flatMap(NSAppearance.init(named:)) }
    }

    #if DEBUG
    /// The panel as a picture (script/snapshot.sh --questions), drawn off screen: the app stays in the background.
    func snapshot(to url: URL, dark: Bool) {
        let panel = panel ?? make()
        self.panel = panel
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        guard let view = panel.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        applyAppearance()
    }
    #endif

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 372, height: 560),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
                            backing: .buffered, defer: true)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.title = String(localized: "待你确认")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = NSSize(width: 320, height: 240)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: QuestionsView())
        panel.setFrameAutosaveName("ASMOQuestions")
        return panel
    }

    /// Beside the planner's right edge, near its top (unless the person moved it before: the autosaved frame wins).
    private func place(_ panel: NSPanel) {
        if UserDefaults.standard.string(forKey: "NSWindow Frame ASMOQuestions") != nil { return }
        let main = NSApp.windows.first { $0.isVisible && $0.frame.width > 400 && !($0 is NSPanel) }
        guard let frame = main?.frame, let screen = (main?.screen ?? NSScreen.main)?.visibleFrame else { panel.center(); return }
        let size = panel.frame.size
        var x = frame.maxX - size.width - 18
        if frame.maxX + size.width + 12 <= screen.maxX { x = frame.maxX + 12 }  // room beside it: don't cover the page
        let y = min(frame.maxY - size.height - 56, screen.maxY - size.height)
        panel.setFrameOrigin(NSPoint(x: max(screen.minX, x), y: max(screen.minY, y)))
    }
}

struct QuestionsView: View {
    @Environment(\.colorScheme) private var scheme
    private var desk: QuestionDesk { QuestionDesk.shared }

    var body: some View { content }

    private var theme: PlannerTheme { PlannerTheme(dark: scheme == .dark) }

    private var content: some View {
        let open = desk.open
        let answered = desk.recentlyAnswered
        let askers = Array(Set(open.map(\.from))).sorted()
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("待你确认").font(.system(size: 20, weight: .semibold)).foregroundStyle(theme.ink)
                if !open.isEmpty {
                    Text("\(open.count)").font(.system(size: 11, weight: .bold)).foregroundStyle(theme.onAccent)
                        .padding(.horizontal, 7).frame(minHeight: 18).background(theme.accent, in: Capsule())
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
            }
            .padding(.top, 30)
            Text(askers.isEmpty ? String(localized: "agent 有问题要你拍板时，会出现在这里")
                 : String(localized: "来自 \(askers.joined(separator: "、"))"))
                .font(.system(size: 12)).foregroundStyle(theme.quiet).padding(.top, 2)

            if open.contains(where: { $0.suggest != nil }) {
                HStack {
                    Text("每条都写了建议，你只需要点一下").font(.system(size: 12)).foregroundStyle(theme.ink.opacity(0.8))
                    Spacer(minLength: 8)
                    Button("全部按建议") { withAnimation(.easeOut(duration: 0.2)) { desk.answerAsSuggested() } }
                        .buttonStyle(FilledQuestionButton(theme: theme))
                        .help("每条按卡片上写的建议处理；没有建议的留着")
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(theme.wash, in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 12)
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(open) { QuestionCard(question: $0, theme: theme) }
                    ForEach(answered) { AnsweredLine(question: $0, theme: theme) }
                    if open.isEmpty && answered.isEmpty {
                        Text("没有待确认的事").font(.system(size: 13)).foregroundStyle(theme.quiet)
                            .frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollIndicators(.never)

            Rectangle().fill(theme.line).frame(height: 1).padding(.horizontal, -14)
            Text("点了就生效，提问的 agent 会在后台读到。没点的会一直留在这里。")
                .font(.system(size: 11)).foregroundStyle(theme.quiet).padding(.top, 8).padding(.bottom, 12)
        }
        .padding(.horizontal, 14)
        .frame(minWidth: 320, maxWidth: .infinity, minHeight: 240, maxHeight: .infinity, alignment: .top)
        .background(theme.paper)
    }
}

private struct QuestionCard: View {
    let question: AgentQuestion
    let theme: PlannerTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !question.tags.isEmpty {
                HStack(spacing: 5) {
                    ForEach(question.tags, id: \.self) { tag in
                        Text(tag).font(.system(size: 11)).foregroundStyle(theme.quiet)
                            .padding(.horizontal, 6).frame(height: 18)
                            .background(theme.dark ? theme.line : theme.surface, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
            Text(question.title).font(.system(size: 14, weight: .medium)).foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let why = question.why, !why.isEmpty {
                Text(String(localized: "为什么问：\(why)")).font(.system(size: 12.5)).foregroundStyle(theme.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let suggest = question.suggest {
                (Text(suggest == .yes ? String(localized: "建议\(yesLabel)") : String(localized: "建议\(noLabel)"))
                    .fontWeight(.semibold).foregroundColor(theme.accent)
                 + Text(question.reason.map { "  " + $0 } ?? "").foregroundColor(theme.ink.opacity(0.85)))
                    .font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Spacer()
                answerButton(.no, "xmark", noLabel)
                answerButton(.yes, "checkmark", yesLabel)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(theme.dark ? theme.surface : theme.sheet, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line, lineWidth: 1))
    }

    private var yesLabel: String { question.yesLabel ?? String(localized: "是") }
    private var noLabel: String { question.noLabel ?? String(localized: "否") }

    private func answerButton(_ answer: AgentQuestion.Answer, _ symbol: String, _ label: String) -> some View {
        let suggested = question.suggest == answer
        return Button {
            withAnimation(.easeOut(duration: 0.2)) { QuestionDesk.shared.answer(question.id, answer) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                Text(label).font(.system(size: 13, weight: suggested ? .semibold : .regular))
                if suggested {
                    Text("建议").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 4).frame(height: 15)
                        .background(theme.wash, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .foregroundStyle(suggested ? theme.accent : theme.ink)
            .padding(.horizontal, 11).frame(height: 28)
            .background(theme.dark ? theme.paper : theme.sheet, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(suggested ? theme.accent : theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(answer == .yes ? String(localized: "\(label)（✓）") : String(localized: "\(label)（✗）"))
    }
}

private struct AnsweredLine: View {
    let question: AgentQuestion
    let theme: PlannerTheme

    var body: some View {
        let label = question.answer == .yes ? (question.yesLabel ?? String(localized: "是")) : (question.noLabel ?? String(localized: "否"))
        HStack(spacing: 8) {
            Image(systemName: question.answer == .yes ? "checkmark" : "xmark").font(.system(size: 10, weight: .bold))
            Text(String(localized: "已\(label)")).font(.system(size: 12.5))
            Text(question.title).font(.system(size: 12.5)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Button("撤销") { withAnimation(.easeOut(duration: 0.2)) { QuestionDesk.shared.answer(question.id, nil) } }
                .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(theme.accent)
        }
        .foregroundStyle(theme.quiet)
        .padding(.horizontal, 12).frame(height: 34)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

private struct FilledQuestionButton: ButtonStyle {
    let theme: PlannerTheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.onAccent)
            .padding(.horizontal, 10).frame(height: 24)
            .background(theme.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 6))
    }
}
#endif
