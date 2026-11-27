import SwiftUI

@MainActor
struct PlannerSettings: View {
    @Bindable var system: SystemPlanner
    var openArchive: (() -> Void)? = nil
    var openImportant: (() -> Void)? = nil
    var openOnboarding: (() -> Void)? = nil
    @Environment(\.closePlannerPanel) private var closePanel
    @Environment(\.colorScheme) private var scheme
    @AppStorage("voiceLocale") private var voiceLocale = "zh-Hans-CN"
    @AppStorage("verifiedVoiceAutoSave") private var verifiedVoiceAutoSave = false
    @AppStorage("voiceSampleCount") private var voiceSampleCount = 0
    @AppStorage("voiceSampleCorrect") private var voiceSampleCorrect = 0
    @AppStorage("voiceSampleSeconds") private var voiceSampleSeconds = 0.0
    @State private var error: String?
    @AppStorage("desktopAppearance") private var appearance: DesktopAppearance = .system
    @State private var language = AppLanguage.choice
    #if os(macOS)
    @State private var agents: AgentSetup.Status?
    @State private var updater = Updater.shared
    #endif

    var body: some View {
        PlannerPanel(title: String(localized: "设置"), width: 560, height: 560, close: close) {
            VStack(alignment: .leading, spacing: 17) {
                if let openOnboarding {
                    Button { openOnboarding() } label: {
                        Label("新手引导：日历、笔记、生日一步步设置", systemImage: "sparkles")
                    }.buttonStyle(PlannerActionStyle(theme: theme))
                }
                group("外观") {
                    HStack(spacing: 4) {
                        ForEach(DesktopAppearance.allCases, id: \.self) { option in
                            Button { appearance = option } label: {
                                Text(option.label).font(.subheadline.weight(appearance == option ? .semibold : .medium))
                                    .foregroundStyle(appearance == option ? theme.accent : theme.quiet)
                                    .padding(.horizontal, 12).frame(minHeight: 29)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(DesktopButtonStyle(theme: theme, selected: appearance == option))
                            .accessibilityAddTraits(appearance == option ? [.isSelected] : [])
                        }
                    }
                    .padding(4)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
                }
                group("语言") {
                    HStack(spacing: 4) {
                        ForEach(AppLanguage.Choice.allCases, id: \.self) { option in
                            Button { language = option; AppLanguage.choice = option } label: {
                                Text(option.label).font(.subheadline.weight(language == option ? .semibold : .medium))
                                    .foregroundStyle(language == option ? theme.accent : theme.quiet)
                                    .padding(.horizontal, 12).frame(minHeight: 29)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(DesktopButtonStyle(theme: theme, selected: language == option))
                            .accessibilityAddTraits(language == option ? [.isSelected] : [])
                        }
                    }
                    .padding(4)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
                    if language != AppLanguage.launchedWith {
                        Text("重新打开逐日后生效。").font(.footnote).foregroundStyle(theme.quiet)
                    }
                }
                #if os(macOS)
                group("AI 助手") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let agents {
                            agentRow("命令行 asmo", agents.command)
                            agentRow("Claude Code", agents.claudeCode)
                            agentRow("Codex", agents.codex)
                            agentRow("Claude 桌面版（MCP）", agents.claudeDesktop)
                        }
                        Text("逐日会自动连好装在这台 Mac 上的助手。打开它们，直接说要安排什么。").font(.footnote).foregroundStyle(theme.quiet)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .task { agents = await Task.detached { AgentSetup.run() }.value }
                }
                group("更新") {
                    HStack(spacing: 10) {
                        Text(String(localized: "当前版本 \(Updater.currentVersion)")).font(.subheadline)
                        Spacer()
                        if let release = updater.available {
                            Button(String(localized: "更新到 \(release.version)")) { updater.install() }
                                .buttonStyle(PlannerActionStyle(theme: theme))
                        } else {
                            Button("检查更新") { Task { await updater.check() } }
                                .buttonStyle(PlannerActionStyle(theme: theme))
                                .disabled(updater.state == .checking)
                        }
                    }
                    if let note = updateNote {
                        Text(note).font(.footnote).foregroundStyle(theme.quiet)
                    }
                }
                #endif
                group("Apple 日历") {
                    if system.canReadEvents {
                        ForEach(system.calendars) { calendar in
                            PlannerToggle(title: calendar.title, selected: calendarSelection(calendar.id, important: false), theme: theme)
                        }
                        Menu("默认写入日历：\(system.calendars.first { $0.id == system.destinationID }?.title ?? "选择日历")") {
                            ForEach(system.calendars.filter(\.writable)) { calendar in
                                Button(calendar.title) { system.destinationID = calendar.id }
                            }
                        }.buttonStyle(PlannerActionStyle(theme: theme))
                        DisclosureGroup("在日期标题显示全天事件") {
                            ForEach(system.calendars) { calendar in
                                PlannerToggle(title: calendar.title, selected: calendarSelection(calendar.id, important: true), theme: theme)
                            }
                        }.font(.subheadline)
                    } else {
                        Button("允许访问 Apple 日历") { authorize { try await system.authorizeEvents() } }
                            .buttonStyle(PlannerActionStyle(theme: theme))
                    }
                }
                group("提醒事项") {
                    if system.canReadReminders {
                        Text("带通知的待办保存在 iCloud「ASMO」列表。").font(.subheadline).foregroundStyle(theme.quiet)
                    } else {
                        Button("允许访问提醒事项") { authorize { try await system.authorizeReminders() } }
                            .buttonStyle(PlannerActionStyle(theme: theme))
                    }
                }
                #if os(iOS)
                group("语音") {
                    Menu(voiceLocale == "en-US" ? "English (US)" : "中文（普通话）") {
                        Button("中文（普通话）") { voiceLocale = "zh-Hans-CN" }
                        Button("English (US)") { voiceLocale = "en-US" }
                    }.buttonStyle(PlannerActionStyle(theme: theme))
                    .accessibilityLabel("主要识别语言")
                    .onChange(of: voiceLocale) { _, _ in
                        verifiedVoiceAutoSave = false
                        voiceSampleCount = 0
                        voiceSampleCorrect = 0
                        voiceSampleSeconds = 0
                    }
                    if voiceSampleCount >= 40 && voiceSampleCorrect * 10 >= voiceSampleCount * 9 {
                        PlannerToggle(title: "自动保存已验证的普通语音待办", selected: $verifiedVoiceAutoSave, theme: theme)
                    }
                    Text("本设备口述验证：\(voiceSampleCorrect) 条准确 / \(voiceSampleCount) 条已评分。至少 40 条且准确率达到 90% 后，可启用自动保存。")
                        .font(.footnote).foregroundStyle(theme.quiet)
                    if voiceSampleCount > 0 {
                        Text("平均耗时 \((voiceSampleSeconds / Double(voiceSampleCount)).formatted(.number.precision(.fractionLength(1)))) 秒")
                            .font(.footnote).foregroundStyle(theme.quiet)
                    }
                }
                #endif
                group("存储") {
                    Text(ASMOStore.cloudID.isEmpty ? "此构建保存在本设备。" : "使用当前 Apple 账户的私有 iCloud 容器。")
                        .font(.subheadline).foregroundStyle(theme.quiet)
                    if let openArchive, let openImportant {
                        HStack(spacing: 8) {
                            Button("历史归档", action: openArchive)
                            Button("生日与纪念日", action: openImportant)
                        }
                        .buttonStyle(PlannerActionStyle(theme: theme))
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
        } footer: {
            Button("完成", action: close).buttonStyle(PlannerActionStyle(theme: theme, primary: true))
        }
    }

    private var theme: PlannerTheme { PlannerTheme(dark: scheme == .dark) }

    private func close() { closePanel?() }

    #if os(macOS)
    private func agentRow(_ name: String, _ connected: Bool?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: connected == true ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(connected == true ? theme.accent : theme.quiet)
            Text(name.localized).font(.subheadline)
            Spacer()
            Text(connected == nil ? String(localized: "未安装") : connected == true ? String(localized: "已连接") : String(localized: "未连接"))
                .font(.caption).foregroundStyle(theme.quiet)
        }
    }

    private var updateNote: String? {
        switch updater.state {
        case .checking: String(localized: "正在检查…")
        case .upToDate: String(localized: "已经是最新版本。")
        case .downloading: String(localized: "正在下载新版本…")
        case .installing: String(localized: "正在安装，逐日会重新打开。")
        case .failed(let reason): reason
        case .idle: updater.available.map { String(localized: "新版本 \($0.version) 可以安装。") }
        }
    }
    #endif

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.localized).font(.headline)
            content()
            Rectangle().fill(theme.line).frame(height: 1)
        }
    }

    private func calendarSelection(_ id: String, important: Bool) -> Binding<Bool> {
        Binding(get: { (important ? system.importantCalendars : system.visibleCalendars).contains(id) }, set: { visible in
            var selected = important ? system.importantCalendars : system.visibleCalendars
            if visible { selected.insert(id) } else { selected.remove(id) }
            if important { system.importantCalendars = selected } else { system.visibleCalendars = selected }
        })
    }

    private func authorize(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action(); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
}
