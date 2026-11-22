#if os(macOS)
import AppKit
import SwiftUI

/// The notes in the sidebar: the folder's notes and folders, folders folding open; a click opens a note.
struct NotesSidebar: View {
    @ObservedObject var library: NotesLibrary
    let theme: PlannerTheme
    let current: URL?
    let open: (URL) -> Void
    let find: () -> Void

    @ObservedObject private var git = NotesGit.shared
    @AppStorage("notesOpenFolders") private var openFoldersRaw = ""
    @State private var renaming: URL?
    @State private var newName = ""
    @State private var problem: String?

    private var openFolders: Set<String> {
        get { Set(openFoldersRaw.split(separator: "\n").map(String.init)) }
    }

    private func toggle(_ id: String) {
        var set = openFolders
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        openFoldersRaw = set.sorted().joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("笔记").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.quiet)
                Spacer()
                iconButton("magnifyingglass", help: "找笔记 ⌘P", action: find)
                iconButton("square.and.pencil", help: "新笔记 ⌘N") { make(in: currentFolder) }
            }
            .padding(.leading, 16).padding(.trailing, 10).padding(.top, 10).padding(.bottom, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if library.root == nil || library.tree.isEmpty {
                        Text("还没有笔记").font(.system(size: 12)).foregroundStyle(theme.quiet).padding(.horizontal, 16).padding(.vertical, 6)
                    }
                    ForEach(rows, id: \.node.id) { row in
                        rowView(row.node, depth: row.depth)
                    }
                }
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
            syncLine
        }
        .alert(String(localized: "重命名"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(String(localized: "名称"), text: $newName)
            Button(String(localized: "取消"), role: .cancel) { renaming = nil }
            Button(String(localized: "好")) {
                guard let url = renaming else { return }
                renaming = nil
                do {
                    let moved = try library.rename(url, to: newName)
                    if current == url { open(moved) }
                } catch { problem = error.localizedDescription }
            }
        }
        .alert(problem ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button(String(localized: "好")) { problem = nil }
        }
    }

    /// How the notes stand with GitHub (shown only for a folder that syncs).
    @ViewBuilder private var syncLine: some View {
        switch git.state {
        case .idle:
            EmptyView()
        case .syncing:
            Text("正在同步笔记…").font(.system(size: 11)).foregroundStyle(theme.quiet).padding(.horizontal, 16).padding(.vertical, 6)
        case .done(let date):
            Button { git.sync() } label: {
                Text("已同步 · \(date.formatted(date: .omitted, time: .shortened))").font(.system(size: 11)).foregroundStyle(theme.quiet)
            }
            .buttonStyle(.plain).help("笔记和 GitHub 同步了；点一下现在再同步").padding(.horizontal, 16).padding(.vertical, 6)
        case .failed(let message):
            Button { git.sync() } label: {
                Label("同步出了问题", systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange)
            }
            .buttonStyle(.plain).help(message + "\n" + String(localized: "点一下再试")).padding(.horizontal, 16).padding(.vertical, 6)
        }
    }

    private var currentFolder: URL? {
        current?.deletingLastPathComponent()
    }

    /// The visible rows: the tree flattened, folders open as the reader left them.
    private var rows: [(node: NotesLibrary.Node, depth: Int)] {
        var result: [(NotesLibrary.Node, Int)] = []
        func walk(_ nodes: [NotesLibrary.Node], _ depth: Int) {
            for node in nodes {
                result.append((node, depth))
                if node.isFolder, openFolders.contains(node.id) || (current.map { library.path(of: $0).hasPrefix(node.id + "/") } ?? false) {
                    walk(node.children ?? [], depth + 1)
                }
            }
        }
        walk(library.tree, 0)
        return result
    }

    private func rowView(_ node: NotesLibrary.Node, depth: Int) -> some View {
        let isCurrent = current?.standardizedFileURL == node.url.standardizedFileURL
        let expanded = node.isFolder && (openFolders.contains(node.id) || (current.map { library.path(of: $0).hasPrefix(node.id + "/") } ?? false))
        return Button {
            if node.isFolder { toggle(node.id) } else { open(node.url) }
        } label: {
            HStack(spacing: 6) {
                if node.isFolder {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(theme.quiet.opacity(0.8)).frame(width: 10)
                } else {
                    Color.clear.frame(width: 10)
                }
                Text(node.name)
                    .font(.system(size: 13, weight: node.isFolder || isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? theme.accent : node.isFolder ? theme.ink.opacity(0.78) : theme.ink.opacity(0.68))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, 12 + CGFloat(depth) * 14).padding(.trailing, 10).frame(height: 27)
            .background(isCurrent ? theme.accent.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(String(localized: "新笔记")) { make(in: node.isFolder ? node.url : node.url.deletingLastPathComponent()) }
            Button(String(localized: "新文件夹")) {
                do {
                    let folder = try library.createFolder(in: node.isFolder ? node.url : node.url.deletingLastPathComponent())
                    toggle(library.path(of: folder))
                } catch { problem = error.localizedDescription }
            }
            Divider()
            Button(String(localized: "重命名…")) { newName = node.isFolder ? node.name : NotesLibrary.title(of: node.url); renaming = node.url }
            Button(String(localized: "在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            Divider()
            Button(String(localized: "移到废纸篓"), role: .destructive) {
                do { try library.trash(node.url) } catch { problem = error.localizedDescription }
            }
        }
    }

    private func make(in folder: URL?) {
        do {
            let url = try library.create(in: folder)
            open(url)
        } catch { problem = error.localizedDescription }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.quiet)
                .frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }
}

/// One note on the page: its name (edited in place: renames the file), its headings in the margin, the text.
struct NoteScreen: View {
    let url: URL
    let theme: PlannerTheme
    @ObservedObject var library: NotesLibrary
    @ObservedObject var outline: NoteOutline
    let controller: PageController
    let open: (URL) -> Void

    @State private var title = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // The note's headings, to jump to (only for a note that has some).
            if outline.headings.count > 1 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本文目录").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.quiet)
                            .padding(.bottom, 6)
                        ForEach(Array(outline.headings.enumerated()), id: \.offset) { _, heading in
                            let top = outline.headings.map(\.level).min() ?? 1
                            Button { outline.go?(heading.range) } label: {
                                Text(heading.title)
                                    .font(.system(size: 12.5, weight: heading.level == top ? .medium : .regular))
                                    .foregroundStyle(heading.level == top ? theme.ink.opacity(0.75) : theme.quiet)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, CGFloat(heading.level - top) * 12).padding(.vertical, 4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 30).padding(.bottom, 20)
                }
                .scrollIndicators(.never)
                .frame(width: 210)
            }
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    let folder = (library.path(of: url) as NSString).deletingLastPathComponent
                    if !folder.isEmpty {
                        Text(folder.replacingOccurrences(of: "/", with: " / ")).font(.system(size: 12)).foregroundStyle(theme.quiet)
                    }
                    TextField(String(localized: "未命名"), text: $title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(theme.ink)
                        .focused($titleFocused)
                        .onSubmit { rename() }
                        .onChange(of: titleFocused) { _, focused in if !focused { rename() } }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.top, 26).padding(.horizontal, 40)
                NoteEditorView(url: url, theme: theme, library: library, outline: outline, controller: controller, open: open)
            }
        }
        .onAppear { title = NotesLibrary.title(of: url) }
        .onChange(of: url) { _, value in title = NotesLibrary.title(of: value) }
    }

    private func rename() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != NotesLibrary.title(of: url) else { title = NotesLibrary.title(of: url); return }
        do { open(try library.rename(url, to: name)) } catch { title = NotesLibrary.title(of: url); NSSound.beep() }
    }
}

/// ⌘P: find a note by name, or a line in any note; ↑↓ to choose, Return to open.
struct NoteFinder: View {
    @ObservedObject var library: NotesLibrary
    let theme: PlannerTheme
    let open: (URL) -> Void
    let close: () -> Void

    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private struct Result: Identifiable {
        var id: String
        var url: URL
        var title: String
        var detail: String
    }

    private var results: [Result] {
        let names = library.named(query).prefix(12).map {
            Result(id: "n" + $0.path, url: $0, title: NotesLibrary.title(of: $0), detail: (library.path(of: $0) as NSString).deletingLastPathComponent)
        }
        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else { return Array(names) }
        let lines = library.search(query, limit: 30).map {
            Result(id: "l" + $0.id, url: $0.url, title: $0.title, detail: $0.snippet)
        }
        return Array(names) + lines
    }

    var body: some View {
        let list = results
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.quiet)
                TextField(String(localized: "找笔记：名字或里面的字"), text: $query)
                    .textFieldStyle(.plain).font(.system(size: 16))
                    .focused($focused)
                    .onSubmit { if list.indices.contains(selected) { open(list[selected].url) } else { create() } }
                    .onKeyPress(.downArrow) { selected = min(selected + 1, max(0, list.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                    .onChange(of: query) { _, _ in selected = 0 }
            }
            .padding(14)
            Rectangle().fill(theme.line).frame(height: 1)
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, result in
                            Button { open(result.url) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(theme.ink).lineLimit(1)
                                    if !result.detail.isEmpty {
                                        Text(result.detail).font(.system(size: 11.5)).foregroundStyle(theme.quiet).lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(index == selected ? theme.accent.opacity(0.12) : Color.clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                        if list.isEmpty, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                            Button { create() } label: {
                                Text("新建笔记「\(query.trimmingCharacters(in: .whitespaces))」 ↩︎").font(.system(size: 13)).foregroundStyle(theme.accent)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .onChange(of: selected) { _, value in reader.scrollTo(value) }
            }
            .frame(maxHeight: 380)
        }
        .frame(width: 560)
        .background(theme.sheet, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.line))
        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        .onAppear { focused = true }
    }

    private func create() {
        let name = query.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let url = try? library.create(name: name) else { return }
        open(url)
    }
}
#endif
