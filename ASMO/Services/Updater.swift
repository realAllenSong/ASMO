#if os(macOS)
import AppKit
import Observation
import SwiftUI

/// Updates from GitHub Releases, like ThunderTalk: a check shortly after launch, a prompt when a newer version is
/// out, and "Update now" downloads the zip, checks it is signed by the same developer, swaps the app in place and
/// reopens it.
@MainActor
@Observable
final class Updater {
    struct Release: Equatable {
        var version: String
        var zip: URL
        var page: URL
        var notes: String
    }

    enum State: Equatable {
        case idle, checking, upToDate, downloading, installing
        case failed(String)
    }

    static let shared = Updater()
    static let releasesAPI = URL(string: "https://api.github.com/repos/realAllenSong/ASMO/releases/latest")!

    var available: Release?
    var state: State = .idle
    /// The prompt for this release was answered "Later" (until the next launch).
    var postponed = false

    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// Shortly after launch, then once a day while the app stays open.
    func checkInBackground() {
        Task {
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                await check()
                // Test runs only (`--args -asmoInstallUpdate YES`): install without the prompt.
                if available != nil, UserDefaults.standard.bool(forKey: "asmoInstallUpdate") { install() }
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    func check() async {
        guard state != .downloading, state != .installing else { return }
        state = .checking
        var request = URLRequest(url: Self.releasesAPI, timeoutInterval: 15)
        request.setValue("ASMO-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = body["tag_name"] as? String,
              let assets = body["assets"] as? [[String: Any]],
              let zip = assets.compactMap({ ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) })
                  .first(where: { $0.lastPathComponent.hasSuffix("-macOS.zip") }),
              let page = (body["html_url"] as? String).flatMap(URL.init(string:)) else {
            state = .failed(String(localized: "暂时连不上 GitHub，稍后再试。"))
            return
        }
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        if Self.isNewer(version, than: Self.currentVersion) {
            available = Release(version: version, zip: zip, page: page, notes: body["body"] as? String ?? "")
            state = .idle
        } else {
            available = nil
            state = .upToDate
        }
    }

    static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = remote.split(separator: ".").map { Int($0) ?? 0 }, b = local.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Downloads, checks and installs the release, then quits so the new version can open.
    func install() {
        guard let release = available else { return }
        // A build from source (no developer signature) can't be swapped safely: show the release instead.
        guard let team = Self.teamIdentifier(of: Bundle.main.bundleURL) else {
            NSWorkspace.shared.open(release.page)
            return
        }
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            NSWorkspace.shared.open(release.page)
            return
        }
        state = .downloading
        Task {
            do {
                let folder = AppPaths.caches.appendingPathComponent("updates/\(release.version)", isDirectory: true)
                try? FileManager.default.removeItem(at: folder)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let (download, _) = try await URLSession.shared.download(from: release.zip)
                let zip = folder.appendingPathComponent("ASMO.zip")
                try FileManager.default.moveItem(at: download, to: zip)
                try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path])
                let fresh = folder.appendingPathComponent("ASMO.app")
                guard FileManager.default.fileExists(atPath: fresh.path) else { throw Failure(String(localized: "下载的文件里没有 逐日。")) }
                try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", fresh.path])
                guard Self.teamIdentifier(of: fresh) == team else { throw Failure(String(localized: "新版本的签名和当前的不一致，已停止更新。")) }
                state = .installing
                try Self.swapAndReopen(target: target, fresh: fresh)
                NSApp.terminate(nil)
            } catch {
                state = .failed((error as? Failure)?.message ?? error.localizedDescription)
            }
        }
    }

    private struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// A small script waits for this app to quit, moves the new one into place (the old one comes back if that
    /// fails), clears the download quarantine and opens it.
    private static func swapAndReopen(target: URL, fresh: URL) throws {
        let quote = { (path: String) in "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let old = target.path + ".old"
        let script = """
        while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf \(quote(old))
        if /bin/mv \(quote(target.path)) \(quote(old)) && /bin/mv \(quote(fresh.path)) \(quote(target.path)); then
            /bin/rm -rf \(quote(old))
        else
            [ -e \(quote(target.path)) ] || /bin/mv \(quote(old)) \(quote(target.path))
        fi
        /usr/bin/xattr -dr com.apple.quarantine \(quote(target.path)) 2>/dev/null
        /bin/rm -rf \(quote(fresh.deletingLastPathComponent().path))
        /usr/bin/open \(quote(target.path))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        try process.run()
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(String(localized: "更新文件没有通过检查。")) }
    }

    /// The developer team that signed an app, or nil for an unsigned / locally signed build.
    static func teamIdentifier(of app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any] else { return nil }
        return values[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// The prompt shown when a newer version is out.
struct UpdatePrompt: ViewModifier {
    @State private var updater = Updater.shared

    func body(content: Content) -> some View {
        content.alert(String(localized: "逐日 \(updater.available?.version ?? "") 已发布"),
                      isPresented: Binding(get: { updater.available != nil && !updater.postponed && updater.state == .idle },
                                           set: { if !$0 { updater.postponed = true } })) {
            Button(String(localized: "立即更新")) { updater.install() }
            Button(String(localized: "稍后"), role: .cancel) { updater.postponed = true }
        } message: {
            Text(String(localized: "更新会下载新版本、替换当前的 逐日 并重新打开。你的数据不受影响。"))
        }
    }
}
#endif
