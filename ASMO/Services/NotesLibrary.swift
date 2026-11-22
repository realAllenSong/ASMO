#if os(macOS)
import AppKit
import Combine

/// The notes: a folder of Markdown files (an Obsidian vault works as it is: same files, same links, same picture
/// folder). 逐日 reads and writes the files themselves, so Obsidian on the phone and Git see exactly what was written.
@MainActor
final class NotesLibrary: ObservableObject {
    static let shared = NotesLibrary()

    struct Node: Identifiable, Hashable {
        /// The path inside the folder ("个人/账号.md").
        var id: String
        var name: String
        var url: URL
        var isFolder: Bool
        var children: [Node]?
    }

    /// The notes folder (nil until one is chosen or found).
    @Published private(set) var root: URL?
    @Published private(set) var tree: [Node] = []
    /// Every note, by path inside the folder.
    @Published private(set) var notes: [URL] = []
    /// Bumped when a note's file was written by something else (Git, Obsidian on the phone, an agent).
    @Published private(set) var changed = 0

    static let folderKey = "notesFolder"
    /// Folders that are the tools', not the writer's.
    private static let hidden: Set<String> = [".obsidian", ".git", ".trash", ".github", "node_modules"]

    private var stamps: [URL: Date] = [:]
    private var watch: Timer?

    private init() {
        root = Self.defaultRoot()
        reload()
        DispatchQueue.main.async { NotesGit.shared.start() }
        // Files change underneath (a Git pull, the phone, an agent): looked at every few seconds and when the app
        // comes back to the front.
        watch = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { NotesLibrary.shared.rescan() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NotesLibrary.shared.rescan() }
        }
    }

    /// The folder chosen before; else an Obsidian vault on the Desktop or in Documents; else 逐日笔记 in Documents.
    private static func defaultRoot() -> URL? {
        // Testing (Debug, the test store) never touches the real notes: ASMO_TEST_NOTES names a copy.
        if let test = ProcessInfo.processInfo.environment["ASMO_TEST_NOTES"] { return URL(fileURLWithPath: test, isDirectory: true) }
        if ProcessInfo.processInfo.environment["ASMO_TEST_STORE"] != nil {
            return AppPaths.support.appendingPathComponent("notes-test", isDirectory: true)
        }
        if let path = UserDefaults.standard.string(forKey: folderKey), FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for place in ["Desktop", "Documents"] {
            let base = home.appendingPathComponent(place)
            let children = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            if let vault = children.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent(".obsidian").path) }) {
                return vault
            }
        }
        return home.appendingPathComponent("Documents/逐日笔记", isDirectory: true)
    }

    func choose(_ folder: URL) {
        if ProcessInfo.processInfo.environment["ASMO_TEST_STORE"] == nil { UserDefaults.standard.set(folder.path, forKey: Self.folderKey) }
        root = folder
        reload()
    }

    // MARK: Reading the folder

    func reload() {
        guard let root else { tree = []; notes = []; return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var all: [URL] = []
        let scanned = scan(root, into: &all)
        // Only a real change is published (every look would otherwise redraw everything showing the notes).
        if scanned != tree { tree = scanned }
        if all != notes { notes = all }
        stamps = Dictionary(uniqueKeysWithValues: all.map { ($0, Self.modified($0)) })
    }

    private func scan(_ folder: URL, into all: inout [URL]) -> [Node] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        var folders: [Node] = []
        var files: [Node] = []
        for item in items {
            let name = item.lastPathComponent
            if Self.hidden.contains(name) { continue }
            let isFolder = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isFolder {
                let children = scan(item, into: &all)
                // A folder with no notes in it (pictures only) isn't shown.
                guard !children.isEmpty else { continue }
                folders.append(Node(id: path(of: item), name: name, url: item, isFolder: true, children: children))
            } else if item.pathExtension.lowercased() == "md" {
                all.append(item)
                files.append(Node(id: path(of: item), name: Self.title(of: item), url: item, isFolder: false, children: nil))
            }
        }
        let order: (Node, Node) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return folders.sorted(by: order) + files.sorted(by: order)
    }

    /// A note's name: its file name without ".md" (and without ".excalidraw" for a drawing).
    static func title(of url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if name.hasSuffix(".excalidraw") { name = String(name.dropLast(".excalidraw".count)) }
        return name
    }

    /// The path inside the folder.
    func path(of url: URL) -> String {
        guard let root else { return url.lastPathComponent }
        let base = root.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        return full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) : url.lastPathComponent
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Notes added, removed or changed by something else since the last look.
    private func rescan() {
        guard root != nil else { return }
        let before = stamps
        reload()
        if stamps.keys.count != before.keys.count || stamps.contains(where: { before[$0.key] != $0.value }) {
            changed += 1
        }
    }

    // MARK: Reading and writing notes

    func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// Writes a note (only when its text changed). Its stamp is noted so the write isn't taken for someone else's.
    func write(_ text: String, to url: URL) throws {
        if read(url) == text { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        stamps[url] = Self.modified(url)
        NotesGit.shared.noteWritten()
        if !notes.contains(url) { reload() }
    }

    func modifiedDate(_ url: URL) -> Date { Self.modified(url) }

    // MARK: Making, renaming, moving, removing

    /// A new note in `folder` (the notes folder by default), named "未命名" (then "未命名 2", …).
    func create(in folder: URL? = nil, name: String = String(localized: "未命名"), text: String = "") throws -> URL {
        guard let base = folder ?? root else { throw Failure(message: "No notes folder.") }
        let url = free(base, name: name, ext: "md")
        try write(text, to: url)
        reload()
        return url
    }

    func createFolder(in folder: URL? = nil, name: String = String(localized: "新文件夹")) throws -> URL {
        guard let base = folder ?? root else { throw Failure(message: "No notes folder.") }
        let url = free(base, name: name, ext: nil)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // An empty folder isn't shown until it holds a note: give it one to start with.
        _ = try create(in: url)
        return url
    }

    private func free(_ folder: URL, name: String, ext: String?) -> URL {
        func candidate(_ index: Int) -> URL {
            let stem = index == 1 ? name : "\(name) \(index)"
            let url = folder.appendingPathComponent(stem)
            return ext.map { url.appendingPathExtension($0) } ?? url
        }
        var index = 1
        while FileManager.default.fileExists(atPath: candidate(index).path) { index += 1 }
        return candidate(index)
    }

    /// Renames a note (or folder). Links to a renamed note ("[[Old]]", "[[Old|shown]]", "[[Old#Part]]") follow it,
    /// as Obsidian does.
    @discardableResult
    func rename(_ url: URL, to name: String) throws -> URL {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty else { throw Failure(message: "A name is needed.") }
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        var target = url.deletingLastPathComponent().appendingPathComponent(clean)
        if !isFolder { target.appendPathExtension(url.pathExtension.isEmpty ? "md" : url.pathExtension) }
        guard target.standardizedFileURL != url.standardizedFileURL else { return url }
        guard !FileManager.default.fileExists(atPath: target.path) else { throw Failure(message: "「\(clean)」 already exists.") }
        try FileManager.default.moveItem(at: url, to: target)
        if !isFolder { relink(from: Self.title(of: url), to: Self.title(of: target)) }
        reload()
        NotesGit.shared.noteWritten()
        return target
    }

    func move(_ url: URL, into folder: URL) throws -> URL {
        let target = folder.appendingPathComponent(url.lastPathComponent)
        guard target.standardizedFileURL != url.standardizedFileURL else { return url }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw Failure(message: "「\(url.lastPathComponent)」 is already there.")
        }
        try FileManager.default.moveItem(at: url, to: target)
        reload()
        NotesGit.shared.noteWritten()
        return target
    }

    /// To the Trash (never deleted outright).
    func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        reload()
        NotesGit.shared.noteWritten()
    }

    private func relink(from old: String, to new: String) {
        guard old != new else { return }
        let escaped = NSRegularExpression.escapedPattern(for: old)
        guard let regex = try? NSRegularExpression(pattern: #"(!?\[\[)"# + escaped + #"((?:[#|][^\]]*)?\]\])"#) else { return }
        let replacement = "$1" + NSRegularExpression.escapedTemplate(for: new) + "$2"
        for note in notes {
            guard let text = read(note) else { continue }
            let updated = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                                         withTemplate: replacement)
            if updated != text { try? write(updated, to: note) }
        }
    }

    // MARK: Links and pictures

    /// The note a link names: "Note", "folder/Note", with or without ".md" (the nearest match by name, as Obsidian
    /// does: same folder first).
    func note(named link: String, from: URL? = nil) -> URL? {
        let name = NoteMarkdown.target(link)
        guard !name.isEmpty else { return nil }
        let wanted = name.lowercased().hasSuffix(".md") ? String(name.dropLast(3)) : name
        if wanted.contains("/"), let root {
            let url = root.appendingPathComponent(wanted).appendingPathExtension("md")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let matches = notes.filter { Self.title(of: $0).caseInsensitiveCompare(wanted.components(separatedBy: "/").last ?? wanted) == .orderedSame
            || $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(wanted) == .orderedSame }
        if let from, let near = matches.first(where: { $0.deletingLastPathComponent() == from.deletingLastPathComponent() }) { return near }
        return matches.first
    }

    /// A picture (or drawing) a note shows: by path next to the note or in the folder, else by name anywhere in it.
    func attachment(named name: String, from note: URL?) -> URL? {
        let clean = name.removingPercentEncoding ?? name
        if clean.hasPrefix("/"), FileManager.default.fileExists(atPath: clean) { return URL(fileURLWithPath: clean) }
        var places: [URL] = []
        if let note { places.append(note.deletingLastPathComponent().appendingPathComponent(clean)) }
        if let root {
            places.append(root.appendingPathComponent(clean))
            places.append(attachmentFolder.appendingPathComponent(clean))
        }
        if let found = places.first(where: { FileManager.default.fileExists(atPath: $0.path) }) { return found }
        guard let root else { return nil }
        let file = (clean as NSString).lastPathComponent
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let item = enumerator?.nextObject() as? URL {
            if Self.hidden.contains(item.lastPathComponent) { enumerator?.skipDescendants(); continue }
            if item.lastPathComponent == file { return item }
            // A drawing named without its extension ("![[想法]]" for "想法.excalidraw.md").
            if item.lastPathComponent == file + ".excalidraw.md" || item.lastPathComponent == file + ".md" { return item }
        }
        return nil
    }

    /// Where new pictures go: the vault's own setting (Obsidian's "attachmentFolderPath"), else 附件.
    var attachmentFolder: URL {
        guard let root else { return FileManager.default.temporaryDirectory }
        let settings = root.appendingPathComponent(".obsidian/app.json")
        if let data = try? Data(contentsOf: settings),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let path = object["attachmentFolderPath"] as? String, !path.isEmpty, path != "/", !path.hasPrefix("./") {
            return root.appendingPathComponent(path, isDirectory: true)
        }
        return root.appendingPathComponent("附件", isDirectory: true)
    }

    /// Saves a pasted or dropped picture into the picture folder; returns its file name (for "![[name]]").
    func savePicture(_ data: Data, ext: String) throws -> String {
        let folder = attachmentFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMddHHmmss"
        var name = "Pasted image \(stamp.string(from: .now)).\(ext)"
        var index = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "Pasted image \(stamp.string(from: .now)) \(index).\(ext)"
            index += 1
        }
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
        return name
    }

    // MARK: Searching

    struct Hit: Identifiable {
        var id: String { url.path + "#\(line)" }
        var url: URL
        var title: String
        var line: Int
        var snippet: String
    }

    /// Notes whose name contains every word, best first.
    func named(_ query: String) -> [URL] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return notes.sorted { modifiedDate($0) > modifiedDate($1) } }
        return notes.filter { url in
            let name = path(of: url).lowercased()
            return words.allSatisfy(name.contains)
        }.sorted { a, b in
            let an = Self.title(of: a).lowercased(), bn = Self.title(of: b).lowercased()
            let q = query.lowercased()
            if an.hasPrefix(q) != bn.hasPrefix(q) { return an.hasPrefix(q) }
            return an.count < bn.count
        }
    }

    /// Lines of notes containing the text (up to `limit`).
    func search(_ query: String, limit: Int = 200) -> [Hit] {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return [] }
        var hits: [Hit] = []
        for url in notes {
            guard let text = read(url) else { continue }
            for (index, line) in text.components(separatedBy: .newlines).enumerated()
                where line.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                hits.append(Hit(url: url, title: Self.title(of: url), line: index,
                                snippet: String(line.trimmingCharacters(in: .whitespaces).prefix(160))))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
#endif

#if os(macOS)
/// Keeps a notes folder that is a Git repository in step with its remote, as the Obsidian Git plugin did (the phone
/// reads the notes through it): pulls on launch and every ten minutes, commits and pushes two minutes after 逐日
/// last wrote a note, and on quitting. A pull that conflicts is undone and said, never left half-merged.
@MainActor
final class NotesGit: ObservableObject {
    static let shared = NotesGit()

    enum State: Equatable { case idle, syncing, done(Date), failed(String) }
    @Published private(set) var state: State = .idle

    private var pendingPush: DispatchWorkItem?
    private var timer: Timer?
    private var running = false

    /// Testing uses a copy of the notes whose remote is the real one: no syncing there unless asked for.
    private var allowed: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["ASMO_TEST_STORE"] == nil || environment["ASMO_TEST_GIT"] != nil
    }

    private var root: URL? {
        guard allowed, let root = NotesLibrary.shared.root,
              FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else { return nil }
        return root
    }

    func start() {
        guard timer == nil, root != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.sync() }
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            MainActor.assumeIsolated { NotesGit.shared.sync() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NotesGit.shared.syncNow(timeout: 8) }
        }
    }

    /// A note was written here: pushed once writing has settled.
    func noteWritten() {
        guard root != nil else { return }
        pendingPush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sync() }
        pendingPush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: work)
    }

    func sync() {
        guard let root, !running else { return }
        running = true
        state = .syncing
        DispatchQueue.global(qos: .utility).async {
            let result = Self.run(in: root)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let git = NotesGit.shared
                    git.running = false
                    git.state = result.map { .failed($0) } ?? .done(.now)
                    NotesLibrary.shared.reload()
                }
            }
        }
    }

    /// Quitting: commit and push now, waiting a little for it.
    private func syncNow(timeout: TimeInterval) {
        guard let root, !running else { return }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.run(in: root)
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
    }

    /// Commit what changed, merge the remote's changes, push. Returns what went wrong, if anything.
    nonisolated private static func run(in root: URL) -> String? {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        _ = git(["add", "-A"], in: root)
        let status = git(["status", "--porcelain"], in: root)
        if status.code == 0, !status.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let commit = git(["commit", "-m", "vault backup: \(stamp.string(from: .now))"], in: root)
            if commit.code != 0 { return String(localized: "笔记没能提交：") + commit.output.suffix(200) }
        }
        let hasRemote = !git(["remote"], in: root).output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasRemote else { return nil }
        let pull = git(["pull", "--no-rebase", "--no-edit"], in: root)
        if pull.code != 0 {
            _ = git(["merge", "--abort"], in: root)
            return String(localized: "笔记和远端有冲突，没有合并：") + pull.output.suffix(200)
        }
        let push = git(["push"], in: root)
        if push.code != 0 { return String(localized: "笔记没能推送：") + push.output.suffix(200) }
        return nil
    }

    nonisolated private static func git(_ arguments: [String], in folder: URL) -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
#endif
