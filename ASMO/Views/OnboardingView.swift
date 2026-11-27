#if os(macOS)
import AppKit
import EventKit
import SwiftData
import SwiftUI

/// The welcome a new user goes through once (and can open again from Settings): what 逐日 is, Calendar and
/// Reminders (asked for here, saying why, and which of their own calendars to show), where the notes are (their
/// Obsidian vault as it is, another folder or a new one), birthdays and anniversaries, and the few keys worth knowing.
struct OnboardingView: View {
    @Bindable var system: SystemPlanner
    @ObservedObject var library: NotesLibrary
    let openImportant: () -> Void
    let finish: () -> Void
    @Binding var step: Int

    @Query private var dates: [ImportantDateRecord]
    @Environment(\.colorScheme) private var scheme
    @State private var asking = false
    @State private var problem: String?
    @State private var vaults: [(url: URL, count: Int)] = []

    private var theme: PlannerTheme { PlannerTheme(dark: scheme == .dark) }
    private let steps = 5

    var body: some View {
        PlannerPanel(title: String(localized: "欢迎使用逐日"), width: 600, height: 520, close: finishNow) {
            VStack(alignment: .leading, spacing: 18) {
                progress
                switch step {
                case 0: welcome
                case 1: calendars
                case 2: notes
                case 3: occasions
                default: ready
                }
            }
        } footer: {
            if step > 0 {
                Button("上一步") { step -= 1 }.buttonStyle(PlannerActionStyle(theme: theme))
            }
            if step < steps - 1 {
                Button("跳过") { step += 1 }.buttonStyle(PlannerActionStyle(theme: theme))
                Button(step == 0 ? "开始设置" : "下一步") { step += 1 }
                    .buttonStyle(PlannerActionStyle(theme: theme, primary: true))
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("开始使用") { finishNow() }
                    .buttonStyle(PlannerActionStyle(theme: theme, primary: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .task { loadVaults() }
    }

    // MARK: Steps

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(0..<steps, id: \.self) { index in
                Capsule().fill(index <= step ? theme.accent : theme.line).frame(height: 3)
            }
        }
        .accessibilityLabel(String(localized: "第 \(step + 1) 步，共 \(steps) 步"))
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("逐日是一份按天往下写的文档，旁边放着你的笔记。")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.ink)
            point("text.alignleft", "像写文档一样写每一天", "写下的行会自己整理：带时间的进日程，其余是待办，按时间排好。")
            point("doc.text", "笔记就在旁边", "直接用你现在的 Obsidian 笔记库，文件原样不动；也可以新建一个。")
            point("iphone", "手机上不用装 App", "待办和日程同步到 Apple 的提醒事项和日历，iPhone 和手表会准时提醒。")
            point("sparkles", "AI 助手可以直接帮你安排", "Claude Code、Codex 等已经自动连好，让它们加事项、写笔记就行。")
        }
    }

    private var calendars: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("连上 Apple 日历和提醒事项").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.ink)
            Text("逐日会在 iCloud 里建一个「逐日」日历和一个「逐日」提醒事项列表：有时间的事放日历，其余放提醒事项。登录同一个 Apple ID 的 iPhone、iPad、手表都能收到。在手机上打勾、改时间，逐日这边几秒内跟着变。")
                .font(.system(size: 13)).foregroundStyle(theme.quiet).fixedSize(horizontal: false, vertical: true)
            if system.canReadEvents && system.canReadReminders {
                Label("已经可以访问日历和提醒事项", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.green)
                if !hasICloud {
                    Label("这台 Mac 上还没有 iCloud 日历：要同步到手机，请在 系统设置 › Apple 账户 › iCloud 里打开「日历」和「提醒事项」。",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if !system.calendars.isEmpty {
                    Text("在逐日里一起显示这些日历（只读，比如节假日、航班、别人发来的邀请）：")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(theme.ink.opacity(0.8))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(system.calendars) { calendar in
                                PlannerToggle(title: calendar.title, selected: shown(calendar.id), theme: theme)
                            }
                        }
                    }
                    .frame(maxHeight: 170)
                }
            } else {
                Button {
                    ask()
                } label: {
                    HStack(spacing: 6) {
                        if asking { ProgressView().controlSize(.small) }
                        Text("允许访问日历和提醒事项")
                    }
                }
                .buttonStyle(PlannerActionStyle(theme: theme, primary: true))
                .disabled(asking)
                Text("点了之后 macOS 会问两次（日历、提醒事项），都选「允许」。不想同步也可以跳过，以后在设置里再打开。")
                    .font(.system(size: 12)).foregroundStyle(theme.quiet).fixedSize(horizontal: false, vertical: true)
                if let problem {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(problem).font(.system(size: 12.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        Button("打开系统设置里的隐私设置") { openPrivacy() }.buttonStyle(PlannerActionStyle(theme: theme))
                    }
                }
            }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("笔记放在哪里").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.ink)
            Text("逐日直接读写一个文件夹里的 Markdown 文件，不复制、不转换，Obsidian 也照常能打开。如果这个文件夹是 Git 仓库，逐日会自动提交和同步。")
                .font(.system(size: 13)).foregroundStyle(theme.quiet).fixedSize(horizontal: false, vertical: true)
            if let root = library.root {
                Label("正在用：\(root.lastPathComponent)（\(library.notes.count) 篇）", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.green)
                Text(root.path).font(.system(size: 11.5)).foregroundStyle(theme.quiet).lineLimit(1).truncationMode(.middle)
            }
            if !vaults.isEmpty {
                Text("在这台 Mac 上找到的 Obsidian 笔记库：").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.ink.opacity(0.8))
                ForEach(vaults, id: \.url) { vault in
                    HStack(spacing: 10) {
                        Image(systemName: "folder").foregroundStyle(theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(vault.url.lastPathComponent).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(theme.ink)
                            Text("\(vault.count) 篇 · \(vault.url.deletingLastPathComponent().path)")
                                .font(.system(size: 11.5)).foregroundStyle(theme.quiet).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button(library.root?.standardizedFileURL == vault.url.standardizedFileURL ? "正在用" : "用这个") { library.choose(vault.url) }
                            .buttonStyle(PlannerActionStyle(theme: theme, primary: library.root == nil))
                            .disabled(library.root?.standardizedFileURL == vault.url.standardizedFileURL)
                    }
                    .padding(10)
                    .background(theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            HStack(spacing: 8) {
                Button("选择其他文件夹…") { pickFolder() }.buttonStyle(PlannerActionStyle(theme: theme))
                Button("新建「逐日笔记」文件夹") {
                    let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/逐日笔记", isDirectory: true)
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    library.choose(folder)
                }.buttonStyle(PlannerActionStyle(theme: theme))
            }
        }
    }

    private var occasions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("生日和纪念日").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.ink)
            Text("每年这一天会出现在日程里，并在 iPhone 上提醒。支持农历；家人在另一个时区的话，可以按那边的日子开始时提醒（比如北京时间 0 点，就是纽约前一天中午）。")
                .font(.system(size: 13)).foregroundStyle(theme.quiet).fixedSize(horizontal: false, vertical: true)
            if !dates.isEmpty {
                Label("已经有 \(dates.count) 个日期", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.green)
            }
            Button("添加生日和纪念日") { openImportant() }.buttonStyle(PlannerActionStyle(theme: theme, primary: dates.isEmpty))
            point("plus.circle", "一条一条加", "写名字、选日期、选每年重复，还能选农历和时区。")
            point("doc.on.clipboard", "一次粘贴一串", "比如从备忘录复制「11.22 妈生日」这样的一列，逐日认出日期再让你确认。")
            point("number", "写日程时顺手加", "在某天写一行，打 # 选「生日」或「纪念日」，这一天就每年提醒。")
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("都准备好了").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.ink)
            status(system.canReadEvents && system.canReadReminders, "日历和提醒事项", system.canReadEvents ? "已连接" : "未连接，可以在设置里打开")
            status(library.root != nil, "笔记", library.root.map { "\($0.lastPathComponent) · \(library.notes.count) 篇" } ?? "还没选，可以在笔记里随时选")
            status(!dates.isEmpty, "生日和纪念日", dates.isEmpty ? "还没加" : "\(dates.count) 个")
            Rectangle().fill(theme.line).frame(height: 1)
            Text("几个常用的").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.ink.opacity(0.8))
            point("keyboard", "⌘1 日程 · ⌘2 笔记 · ⌘P 搜索一切", "搜索同时找笔记和日程里的事项。")
            point("number", "在一行里打 #", "让它每天、每周重复，存成生日，或者连到一篇笔记。")
            point("gearshape", "设置里随时可以改", "也能从设置重新打开这份引导。")
        }
    }

    // MARK: Parts

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(theme.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(theme.ink)
                Text(detail).font(.system(size: 12.5)).foregroundStyle(theme.quiet).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func status(_ ok: Bool, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? .green : theme.quiet)
            Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(theme.ink)
            Spacer()
            Text(detail).font(.system(size: 12.5)).foregroundStyle(theme.quiet)
        }
    }

    private func shown(_ id: String) -> Binding<Bool> {
        Binding(get: { system.visibleCalendars.contains(id) }, set: { on in
            var set = system.visibleCalendars
            if on { set.insert(id) } else { set.remove(id) }
            system.visibleCalendars = set
        })
    }

    /// An iCloud account holds calendars on this Mac (what reaches the phone).
    private var hasICloud: Bool {
        EKEventStore().sources.contains { $0.sourceType == .calDAV && $0.title.localizedCaseInsensitiveContains("icloud") }
    }

    private func ask() {
        asking = true
        problem = nil
        Task { @MainActor in
            defer { asking = false }
            do {
                try await system.authorizeEvents()
                try await system.authorizeReminders()
                CalendarMirror.shared.schedule(after: 0.5)
            } catch {
                problem = String(localized: "没有拿到权限。可以在 系统设置 › 隐私与安全性 › 日历 和 提醒事项 里给「逐日」打开「完全访问」。")
            }
        }
    }

    private func openPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { NSWorkspace.shared.open(url) }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "用这个文件夹")
        if panel.runModal() == .OK, let url = panel.url { library.choose(url) }
    }

    private func loadVaults() {
        Task.detached(priority: .userInitiated) {
            let found = NotesLibrary.vaults().map { (url: $0, count: NotesLibrary.noteCount(in: $0)) }
            await MainActor.run { vaults = found }
        }
    }

    private func finishNow() {
        Onboarding.finish()
        finish()
    }
}
#endif
