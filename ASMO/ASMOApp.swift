import SwiftData
import SwiftUI

@main
struct ASMOApp: App {
    private let storage = Result { try ASMOStore.open() }
    @State private var system = SystemPlanner()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(DesktopDelegate.self) private var desktop
    #endif
    @AppStorage("desktopAppearance") private var appearance: DesktopAppearance = .light

    init() {
        // 纸面 (the paper look) became the design on 2026-11-08: switch to it once; Settings can change it back.
        let defaults = UserDefaults.standard
        AppLanguage.keepChineseForEarlierUsers(defaults)
        if !defaults.bool(forKey: "paperLookApplied") {
            defaults.set(DesktopAppearance.light.rawValue, forKey: "desktopAppearance")
            defaults.set(true, forKey: "paperLookApplied")
        }
        #if os(macOS)
        // Coding agents reach the app through the `asmo` command.
        if case .success(let container) = storage { AgentBridge.start(container) }
        #endif
    }

    var body: some Scene {
        WindowGroup(AppName.window, id: "planner") {
            switch storage {
            case .success(let container):
                PlannerView(system: system)
                    .modelContainer(container)
                    .preferredColorScheme(appearance.scheme)
                    #if os(macOS)
                    .frame(minWidth: 720, minHeight: 540)
                    #endif
            case .failure(let error):
                ContentUnavailableView("无法打开待办", systemImage: "externaldrive.badge.exclamationmark",
                                       description: Text(error.localizedDescription))
            }
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 900)
        // Always open the planner window on launch, even if it was closed when the app last quit.
        .restorationBehavior(.disabled)
        .commands {
            CommandMenu(String(localized: "待办")) {
                Button("回到今天") { NotificationCenter.default.post(name: .asmoToday, object: nil) }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("逐日") { NotificationCenter.default.post(name: .asmoView, object: 0) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("日历") { NotificationCenter.default.post(name: .asmoView, object: 1) }
                    .keyboardShortcut("2", modifiers: .command)
            }
        }
        #endif
    }
}

extension Notification.Name {
    static let asmoToday = Notification.Name("ASMO.Today")
    static let asmoView = Notification.Name("ASMO.View")
    static let asmoDebugType = Notification.Name("ASMO.DebugType")
    static let asmoDebugNav = Notification.Name("ASMO.DebugNav")
    static let asmoDebugDump = Notification.Name("ASMO.DebugDump")
    static let asmoDebugImage = Notification.Name("ASMO.DebugImage")
    /// An agent is about to change / has changed a day's page (object: the day's key).
    static let asmoPageWillChange = Notification.Name("ASMO.PageWillChange")
    static let asmoPageChanged = Notification.Name("ASMO.PageChanged")
}
