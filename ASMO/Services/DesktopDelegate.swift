#if os(macOS)
import AppKit

final class DesktopDelegate: NSObject, NSApplicationDelegate {
    private var positioned = Set<ObjectIdentifier>()

    /// Saved window state can say "no window" (closed before quitting); the planner should always open.
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconName = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           let url = Bundle.main.url(forResource: iconName, withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        #if DEBUG
        watchSnapshotRequests()
        #endif
        NotificationCenter.default.addObserver(self, selector: #selector(rememberWindow(_:)),
                                               name: NSWindow.didBecomeMainNotification, object: nil)
        if let window = NSApp.mainWindow {
            rememberWindow(Notification(name: NSWindow.didBecomeMainNotification, object: window))
        }
    }

    @objc private func rememberWindow(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window.title == AppName.window else { return }
        // Not movable by background: that would swallow drags of tasks between days. The top edge still moves it.
        window.isMovableByWindowBackground = false
        guard positioned.insert(ObjectIdentifier(window)).inserted, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.insetBy(dx: 14, dy: 12)
        let frame = window.frame
        // Opens roomy, like a writing app: most of the screen (up to 1600 × 1040), centered, never smaller than it was.
        let roomy = CGSize(width: max(frame.width, min(visible.width * 0.86, 1600)),
                           height: max(frame.height, min(visible.height * 0.9, 1040)))
        if !visible.contains(frame) || frame.width < roomy.width - 1 || frame.height < roomy.height - 1 {
            let size = CGSize(width: min(roomy.width, visible.width), height: min(roomy.height, visible.height))
            let centered = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                                  width: size.width, height: size.height)
            window.setFrame(centered, display: true)
        }
    }

    #if DEBUG
    /// Debug builds only: creating <container>/Library/Caches/asmo-snapshot.request makes the app write its window to
    /// asmo-snapshot.png next to it (see script/snapshot.sh). Used for design review without screen recording.
    private var snapshotTimer: Timer?

    private func watchSnapshotRequests() {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            let voiceTest = folder.appendingPathComponent("asmo-voice-test.aiff")
            if FileManager.default.fileExists(atPath: voiceTest.path) {
                let moved = folder.appendingPathComponent("asmo-voice-running.aiff")
                try? FileManager.default.removeItem(at: moved)
                try? FileManager.default.moveItem(at: voiceTest, to: moved)
                Task { @MainActor in
                    let started = Date.now
                    let result: String
                    do { result = try await VoiceCapture.transcribe(file: moved, locale: Locale(identifier: "zh-Hans-CN")) }
                    catch { result = "ERROR: \(error.localizedDescription)" }
                    let line = String(format: "%.2fs\t", Date.now.timeIntervalSince(started)) + result
                    try? line.write(to: folder.appendingPathComponent("asmo-voice-test.txt"), atomically: true, encoding: .utf8)
                }
            }
            // Background test input: type into the open page / switch days, without touching the real keyboard.
            for (name, notification) in [("asmo-type.txt", Notification.Name.asmoDebugType), ("asmo-nav.txt", .asmoDebugNav)] {
                let file = folder.appendingPathComponent(name)
                if let text = try? String(contentsOf: file, encoding: .utf8) {
                    try? FileManager.default.removeItem(at: file)
                    DispatchQueue.main.async { NotificationCenter.default.post(name: notification, object: text) }
                }
            }
            let image = folder.appendingPathComponent("asmo-image.png")
            if FileManager.default.fileExists(atPath: image.path) {
                let moved = folder.appendingPathComponent("asmo-image-\(UUID()).png")
                try? FileManager.default.moveItem(at: image, to: moved)
                DispatchQueue.main.async { NotificationCenter.default.post(name: .asmoDebugImage, object: moved) }
            }
            let dump = folder.appendingPathComponent("asmo-dump.request")
            if FileManager.default.fileExists(atPath: dump.path) {
                try? FileManager.default.removeItem(at: dump)
                DispatchQueue.main.async { NotificationCenter.default.post(name: .asmoDebugDump, object: folder.appendingPathComponent("asmo-dump.txt")) }
            }
            let request = folder.appendingPathComponent("asmo-snapshot.request")
            guard FileManager.default.fileExists(atPath: request.path) else { return }
            try? FileManager.default.removeItem(at: request)
            DispatchQueue.main.async { Self.writeSnapshot(to: folder.appendingPathComponent("asmo-snapshot.png")) }
        }
    }

    private static func writeSnapshot(to url: URL) {
        let candidates = NSApp.windows.filter { $0.isVisible && $0.frame.width > 400 && !($0 is NSPanel) }
        guard let window = candidates.first(where: { $0.title == AppName.window }) ?? NSApp.mainWindow ?? candidates.first,
              let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    #endif

}
#endif
