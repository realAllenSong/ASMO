import Foundation

/// Where the app keeps its files. On the Mac (not sandboxed): ~/Library/Application Support/ASMO and
/// ~/Library/Caches/com.realallensong.asmo; on iPhone, the app's own folders.
enum AppPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if os(macOS)
        return ensure(base.appendingPathComponent("ASMO", isDirectory: true))
        #else
        return base
        #endif
    }

    static var caches: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #if os(macOS)
        return ensure(base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.realallensong.asmo", isDirectory: true))
        #else
        return base
        #endif
    }

    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    #if os(macOS)
    /// The sandbox container earlier versions kept everything in.
    static var container: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(Bundle.main.bundleIdentifier ?? "com.realallensong.asmo")/Data", isDirectory: true)
    }

    /// Once per store, when it is first opened here: copies it (with its attachments) out of the old sandbox
    /// container. The original stays where it was, as a backup. Nothing is copied over a store that exists here.
    static func moveOutOfSandbox(_ base: String) {
        let files = FileManager.default
        let old = container.appendingPathComponent("Library/Application Support", isDirectory: true)
        let store = base + ".store"
        guard !files.fileExists(atPath: support.appendingPathComponent(store).path),
              files.fileExists(atPath: old.appendingPathComponent(store).path) else { return }
        for name in [store, store + "-shm", store + "-wal", "." + base + "_SUPPORT"]
        where files.fileExists(atPath: old.appendingPathComponent(name).path) {
            try? files.copyItem(at: old.appendingPathComponent(name), to: support.appendingPathComponent(name))
        }
    }

    /// Once: brings the settings over from the old container (language, appearance, calendars shown…).
    /// Returns true when the interface language changed, so the app can reopen in it.
    static func moveSettingsOutOfSandbox(_ defaults: UserDefaults) -> Bool {
        guard !defaults.bool(forKey: "leftSandbox") else { return false }
        defaults.set(true, forKey: "leftSandbox")
        let plist = container.appendingPathComponent("Library/Preferences/\(Bundle.main.bundleIdentifier ?? "").plist")
        guard defaults.object(forKey: "paperLookApplied") == nil,
              let saved = NSDictionary(contentsOf: plist) as? [String: Any] else { return false }
        let before = defaults.array(forKey: "AppleLanguages") as? [String]
        for (key, value) in saved where !key.hasPrefix("NS") && !key.hasPrefix("com.apple") { defaults.set(value, forKey: key) }
        let after = saved["AppleLanguages"] as? [String]
        return after != nil && after != before
    }
    #endif
}
