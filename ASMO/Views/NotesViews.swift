#if os(macOS)
import AppKit
import SwiftUI

/// The notes in the sidebar: the folder's notes and folders, folders folding open; a click opens a note.
struct NotesSidebar: View {
    @ObservedObject var library: NotesLibrary
    let theme: PlannerTheme
    let current: URL?
    @ObservedObject var outline: NoteOutline
    let open: (URL) -> Void
    let find: () -> Void
    /// The home page (all the notes at a glance) is showing / show it.
    var atHome = false
    var home: () -> Void = {}

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
            ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if library.root == nil || library.tree.isEmpty {
                        Text("还没有笔记").font(.system(size: 12)).foregroundStyle(theme.quiet).padding(.horizontal, 16).padding(.vertical, 6)
                    }
                    homeRow
                    ForEach(rows, id: \.node.id) { row in
                        rowView(row.node, depth: row.depth)
                    }
                }
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
            // The open note's row (and its headings under it) comes into view.
            .onAppear { reveal(reader) }
            .onChange(of: current) { _, _ in reveal(reader) }
            }
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

    private func reveal(_ reader: ScrollViewProxy) {
        guard let current else { return }
        let id = library.path(of: current)
        DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo(id, anchor: UnitPoint(x: 0, y: 0.15)) } }
    }

    private var homeRow: some View {
        Button(action: home) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2").font(.system(size: 11, weight: .medium)).frame(width: 14)
                Text("全部笔记").font(.system(size: 13, weight: atHome ? .semibold : .regular))
                Spacer(minLength: 0)
                Text("\(library.notes.count)").font(.system(size: 11)).foregroundStyle(theme.quiet)
            }
            .foregroundStyle(atHome ? theme.accent : theme.ink.opacity(0.72))
            .padding(.leading, 10).padding(.trailing, 10).frame(height: 28)
            .background(atHome ? theme.accent.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 4).padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("所有笔记一览：最近写的、翻到以前写的、各个分类")
    }

    /// The open note's headings under its name: a click goes there; the one being read is marked.
    @ViewBuilder private func headingRows(depth: Int) -> some View {
        let headings = outline.headings
        if !headings.isEmpty {
            let top = headings.map(\.level).min() ?? 1
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(headings.enumerated()), id: \.offset) { index, heading in
                    let here = outline.current == index
                    Button { outline.go?(heading.range) } label: {
                        Text(heading.title.isEmpty ? " " : heading.title)
                            .font(.system(size: 12, weight: here ? .semibold : (heading.level == top ? .medium : .regular)))
                            .foregroundStyle(here ? theme.accent : (heading.level == top ? theme.ink.opacity(0.62) : theme.quiet))
                            .lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 8 + CGFloat(heading.level - top) * 11)
                            .frame(height: 24)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(here ? theme.accent : theme.line).frame(width: here ? 2 : 1)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(heading.title)
                }
            }
            .padding(.leading, 12 + CGFloat(depth) * 14 + 4).padding(.trailing, 12).padding(.vertical, 3)
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

/// One note on the page: its folder and name above the text (the name is edited in place: renames the file),
/// in one centred column that scrolls together.
struct NoteScreen: View {
    let url: URL
    let theme: PlannerTheme
    @ObservedObject var library: NotesLibrary
    @ObservedObject var outline: NoteOutline
    let controller: PageController
    let open: (URL) -> Void

    var body: some View {
        GeometryReader { geometry in
            // The note's contents sit in the margin left of the text, when the window leaves room for them.
            let column = min(760, geometry.size.width - 96)
            let margin = (geometry.size.width - column) / 2
            NoteEditorView(url: url, theme: theme, library: library, outline: outline, controller: controller, open: open,
                           header: AnyView(NoteTitle(url: url, theme: theme, library: library, open: open)))
                .overlay(alignment: .topLeading) {
                    if margin >= 190, outline.headings.count >= 2 {
                        NoteContents(outline: outline, theme: theme)
                            .frame(width: min(240, margin - 44), alignment: .leading)
                            .padding(.leading, 24).padding(.top, 40)
                            .frame(maxHeight: geometry.size.height - 20, alignment: .top)
                    }
                }
        }
    }
}

/// A note's headings beside its text: the top-level ones, and under the one being read its own subheadings (a long
/// note stays a short list). The heading being read is marked; a click goes there.
struct NoteContents: View {
    @ObservedObject var outline: NoteOutline
    let theme: PlannerTheme

    var body: some View {
        let headings = outline.headings
        // The level the note is divided at: the highest one used more than once (a single "# 标题" above the
        // sections repeats the note's name and is left out).
        let counts = Dictionary(grouping: headings, by: \.level).mapValues(\.count)
        let top = counts.keys.sorted().first { (counts[$0] ?? 0) >= 2 } ?? (headings.map(\.level).min() ?? 1)
        // Each heading's top-level section (the last top-level heading at or before it).
        var sections: [Int] = []
        var section = -1
        for (index, heading) in headings.enumerated() {
            if heading.level <= top { section = index }
            sections.append(section)
        }
        let open = outline.current.map { sections.indices.contains($0) ? sections[$0] : -1 } ?? -1
        return VStack(alignment: .leading, spacing: 0) {
            Text("目录").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.quiet).padding(.bottom, 8)
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(headings.enumerated()), id: \.offset) { index, heading in
                            if heading.level == top || (heading.level > top && sections[index] == open) {
                                row(heading, index: index, top: top)
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
                .onChange(of: outline.current) { _, value in
                    if let value { withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo(value, anchor: .center) } }
                }
            }
        }
    }

    private func row(_ heading: NoteMarkdown.Heading, index: Int, top: Int) -> some View {
        let here = outline.current == index
        let sub = heading.level > top
        return Button { outline.go?(heading.range) } label: {
            Text(heading.title)
                .font(.system(size: sub ? 12 : 12.5, weight: here ? .semibold : (sub ? .regular : .medium)))
                .foregroundStyle(here ? theme.accent : (sub ? theme.quiet : theme.ink.opacity(0.66)))
                .lineLimit(2).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10 + CGFloat(min(heading.level - top, 2)) * 12).padding(.vertical, 4)
                .overlay(alignment: .leading) {
                    Rectangle().fill(here ? theme.accent : theme.line).frame(width: here ? 2 : 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(heading.title)
        .id(index)
    }
}

/// The folder (a path one can click back up) and the note's name.
struct NoteTitle: View {
    let url: URL
    let theme: PlannerTheme
    let library: NotesLibrary
    let open: (URL) -> Void

    @State private var title = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let folder = (library.path(of: url) as NSString).deletingLastPathComponent
            if !folder.isEmpty {
                Text(folder.replacingOccurrences(of: "/", with: "  /  ")).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.quiet)
            }
            TextField(String(localized: "未命名"), text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(theme.ink)
                .lineLimit(1...3)
                .focused($focused)
                .onSubmit { rename() }
                .onChange(of: focused) { _, now in if !now { rename() } }
                // Return ends the name (the field wraps long names, but a name is one line).
                .onChange(of: title) { _, value in
                    if value.contains("\n") { title = value.replacingOccurrences(of: "\n", with: ""); focused = false }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { title = NotesLibrary.title(of: url) }
        .onChange(of: url) { _, value in title = NotesLibrary.title(of: value) }
    }

    private func rename() {
        let name = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != NotesLibrary.title(of: url) else { title = NotesLibrary.title(of: url); return }
        do { open(try library.rename(url, to: name)) } catch { title = NotesLibrary.title(of: url); NSSound.beep() }
    }
}

/// What a search finds, everywhere: notes by name, lines in notes, and to-dos and events on the days.
struct NoteSearch {
    struct DayHit {
        var day: PlanDate
        var title: String
    }

    struct Result: Identifiable {
        enum Target { case note(URL, find: String?), day(PlanDate) }
        var id: String
        var target: Target
        var symbol: String
        var title: String
        var detail: String
    }

    @MainActor static func results(_ query: String, library: NotesLibrary, days: (String) -> [DayHit]) -> [Result] {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        let names = library.named(wanted).prefix(wanted.isEmpty ? 10 : 8).map {
            Result(id: "n" + $0.path, target: .note($0, find: nil), symbol: "doc.text", title: NotesLibrary.title(of: $0),
                   detail: (library.path(of: $0) as NSString).deletingLastPathComponent)
        }
        guard wanted.count >= 2 || (wanted.count == 1 && wanted.unicodeScalars.first.map { $0.value > 0x2E80 } == true) else {
            return Array(names)
        }
        let scheduled = days(wanted).prefix(8).map { hit in
            Result(id: "d" + hit.day.key + hit.title, target: .day(hit.day), symbol: "calendar", title: hit.title,
                   detail: hit.day.label)
        }
        let lines = library.search(wanted, limit: 40).map {
            Result(id: "l" + $0.id, target: .note($0.url, find: wanted), symbol: "text.magnifyingglass", title: $0.title, detail: $0.snippet)
        }
        return Array(names) + scheduled + lines
    }
}

/// ⌘P: find anything, a note by name, a line in any note, or a to-do on a day; ↑↓ to choose, Return to open.
struct NoteFinder: View {
    @ObservedObject var library: NotesLibrary
    let theme: PlannerTheme
    let days: (String) -> [NoteSearch.DayHit]
    let choose: (NoteSearch.Result) -> Void
    let create: (String) -> Void
    let close: () -> Void

    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    var body: some View {
        let list = NoteSearch.results(query, library: library, days: days)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.quiet)
                TextField(String(localized: "搜索笔记和日程"), text: $query)
                    .textFieldStyle(.plain).font(.system(size: 16))
                    .focused($focused)
                    .onSubmit {
                        if list.indices.contains(selected) { choose(list[selected]) }
                        else if !query.trimmingCharacters(in: .whitespaces).isEmpty { create(query.trimmingCharacters(in: .whitespaces)) }
                    }
                    .onKeyPress(.downArrow) { selected = min(selected + 1, max(0, list.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                    .onChange(of: query) { _, _ in selected = 0 }
            }
            .padding(14)
            Rectangle().fill(theme.line).frame(height: 1)
            SearchResultList(results: list, query: query, selected: selected, theme: theme, choose: choose, create: create)
                .frame(maxHeight: 420)
        }
        .frame(width: 600)
        .background(theme.sheet, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.line))
        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        .onAppear { focused = true }
    }
}

/// The found things, one a line: what it is (a note, a line in a note, a day), its name and where it is.
struct SearchResultList: View {
    let results: [NoteSearch.Result]
    let query: String
    var selected: Int?
    let theme: PlannerTheme
    let choose: (NoteSearch.Result) -> Void
    let create: (String) -> Void

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        Button { choose(result) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: result.symbol).font(.system(size: 12)).foregroundStyle(theme.quiet)
                                    .frame(width: 16).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(theme.ink).lineLimit(1)
                                    if !result.detail.isEmpty {
                                        highlighted(result.detail).font(.system(size: 12)).foregroundStyle(theme.quiet).lineLimit(2)
                                    }
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
                    let name = query.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty, !results.contains(where: { $0.title == name }) {
                        Button { create(name) } label: {
                            Label("新建笔记「\(name)」", systemImage: "plus").font(.system(size: 13)).foregroundStyle(theme.accent)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: selected) { _, value in if let value { reader.scrollTo(value) } }
        }
    }

    /// The searched words stand out in a found line.
    private func highlighted(_ line: String) -> Text {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty, let found = line.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive]) else { return Text(line) }
        return Text(line[..<found.lowerBound]) + Text(line[found]).foregroundColor(theme.accent).bold() + Text(line[found.upperBound...])
    }
}

/// All the notes at a glance: the ones to go on with, a few written long ago to read again, and every folder with
/// what's in it. One look says "I wrote about that", one click opens it.
struct NotesHome: View {
    @ObservedObject var library: NotesLibrary
    let theme: PlannerTheme
    let days: (String) -> [NoteSearch.DayHit]
    let choose: (NoteSearch.Result) -> Void
    let create: (String?) -> Void

    @State private var query = ""
    @State private var shuffle = 0
    @FocusState private var searching: Bool
    @AppStorage("notesOpenFolders") private var openFoldersRaw = ""

    private var daySeed: Int { Int(Date.now.timeIntervalSince1970 / 86_400) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                header
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    recentSection
                    rediscoverSection
                    foldersSection
                } else {
                    SearchResultList(results: NoteSearch.results(query, library: library, days: days), query: query, theme: theme,
                                     choose: choose, create: { create($0) })
                        .frame(minHeight: 300, maxHeight: .infinity)
                        .background(theme.sidebar.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 48).padding(.top, 34).padding(.bottom, 60)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("笔记").font(.system(size: 30, weight: .bold)).foregroundStyle(theme.ink)
                Text("\(library.notes.count) 篇 · \(folders.count) 个分类").font(.system(size: 13)).foregroundStyle(theme.quiet)
                Spacer()
                Button { create(nil) } label: {
                    Label("新笔记", systemImage: "square.and.pencil").font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.onAccent).padding(.horizontal, 12).frame(height: 30)
                        .background(theme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain).help("新笔记 ⌘N")
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(theme.quiet)
                TextField(String(localized: "搜索所有笔记和日程…"), text: $query)
                    .textFieldStyle(.plain).font(.system(size: 15)).focused($searching)
                    .onSubmit {
                        if let first = NoteSearch.results(query, library: library, days: days).first { choose(first) }
                    }
                    .onKeyPress(.escape) { query = ""; return .handled }
                Text("⌘P").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.quiet)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.line))
            }
            .padding(.horizontal, 14).frame(height: 44)
            .background(theme.sidebar, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(searching ? theme.accent.opacity(0.5) : theme.line))
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey, detail: LocalizedStringKey? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.ink)
            if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(theme.quiet) }
        }
    }

    private var recentSection: some View {
        let recent = library.recent(4)
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("接着写")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                ForEach(recent, id: \.self) { url in
                    card(url) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(folderName(url)).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.quiet).lineLimit(1)
                            Text(NotesLibrary.title(of: url)).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(theme.ink).lineLimit(2)
                            Text(library.excerpt(url)).font(.system(size: 12.5)).foregroundStyle(theme.ink.opacity(0.6))
                                .lineLimit(3).lineSpacing(2)
                            Spacer(minLength: 0)
                            Text(library.modifiedDate(url).formatted(.relative(presentation: .named)))
                                .font(.system(size: 11)).foregroundStyle(theme.quiet)
                        }
                        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
                    }
                }
            }
        }
    }

    /// A few notes, a line from each: what was written and might be forgotten. New ones every day (or on asking).
    private var rediscoverSection: some View {
        let picks = rediscover(3)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("翻到以前写的", detail: "每天换几篇")
                Spacer()
                Button { shuffle += 1 } label: {
                    Label("换几篇", systemImage: "arrow.triangle.2.circlepath").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.quiet).padding(.horizontal, 8).frame(height: 26).contentShape(Rectangle())
                }
                .buttonStyle(DesktopButtonStyle(theme: theme))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                ForEach(picks, id: \.url) { pick in
                    card(pick.url, find: pick.line) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top, spacing: 8) {
                                Rectangle().fill(theme.accent.opacity(0.55)).frame(width: 3)
                                Text(pick.line).font(.system(size: 13.5)).foregroundStyle(theme.ink.opacity(0.85))
                                    .lineLimit(5).lineSpacing(3)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            HStack(spacing: 5) {
                                Image(systemName: "doc.text").font(.system(size: 10))
                                Text(NotesLibrary.title(of: pick.url)).lineLimit(1)
                                Text("· " + folderName(pick.url)).lineLimit(1)
                            }
                            .font(.system(size: 11.5)).foregroundStyle(theme.quiet)
                        }
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    }
                }
            }
        }
    }

    private var foldersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("分类")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                ForEach(folders) { folder in folderCard(folder) }
                let loose = library.tree.filter { !$0.isFolder }
                if !loose.isEmpty {
                    folderCard(NotesLibrary.Node(id: "", name: String(localized: "不在分类里"), url: library.root ?? URL(fileURLWithPath: "/"),
                                                 isFolder: true, children: loose))
                }
            }
        }
    }

    private func folderCard(_ folder: NotesLibrary.Node) -> some View {
        let all = notes(in: folder)
        let shown = sortedByUse(all).prefix(5)
        let subfolders = (folder.children ?? []).filter(\.isFolder).map(\.name)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(folder.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.ink)
                Spacer()
                Text("\(all.count) 篇").font(.system(size: 11.5)).foregroundStyle(theme.quiet)
            }
            if !subfolders.isEmpty {
                Text(subfolders.joined(separator: " · ")).font(.system(size: 11.5)).foregroundStyle(theme.quiet).lineLimit(1)
                    .padding(.top, 3)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown), id: \.self) { url in
                    Button { choose(.init(id: url.path, target: .note(url, find: nil), symbol: "", title: "", detail: "")) } label: {
                        HStack(spacing: 7) {
                            Circle().fill(theme.quiet.opacity(0.5)).frame(width: 4, height: 4)
                            Text(NotesLibrary.title(of: url)).font(.system(size: 13)).foregroundStyle(theme.ink.opacity(0.78)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(height: 25).contentShape(Rectangle())
                    }
                    .buttonStyle(HoverRowStyle(theme: theme))
                }
            }
            .padding(.top, 10)
            if all.count > shown.count, !folder.id.isEmpty {
                Button { reveal(folder) } label: {
                    Text("还有 \(all.count - shown.count) 篇，在左边展开 →").font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain).padding(.top, 6)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(theme.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.line))
    }

    private func card<Content: View>(_ url: URL, find: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        Button { choose(.init(id: url.path, target: .note(url, find: find), symbol: "", title: "", detail: "")) } label: {
            content()
                .padding(16)
                .background(theme.sidebar, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.line.opacity(0.7)))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(LiftStyle())
    }

    // MARK: Data

    private var folders: [NotesLibrary.Node] { library.tree.filter(\.isFolder) }

    private func notes(in node: NotesLibrary.Node) -> [URL] {
        if !node.isFolder { return [node.url] }
        return (node.children ?? []).flatMap(notes(in:))
    }

    private func sortedByUse(_ urls: [URL]) -> [URL] {
        let order = Dictionary(library.opened.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return urls.sorted { a, b in
            let oa = order[library.path(of: a)] ?? Int.max, ob = order[library.path(of: b)] ?? Int.max
            if oa != ob { return oa < ob }
            return library.modifiedDate(a) > library.modifiedDate(b)
        }
    }

    private func folderName(_ url: URL) -> String {
        let folder = (library.path(of: url) as NSString).deletingLastPathComponent
        return folder.isEmpty ? String(localized: "笔记") : folder.replacingOccurrences(of: "/", with: " / ")
    }

    /// Notes not opened lately, each with a line worth reading; the same ones all day, others on "换几篇".
    private func rediscover(_ count: Int) -> [(url: URL, line: String)] {
        let recent = Set(library.recent(6))
        var pool = library.notes.filter { !recent.contains($0) && !library.path(of: $0).hasPrefix("归档/")
            && !NotesLibrary.title(of: $0).contains("账号") && library.readableLines($0).count >= 3 }
        if pool.count < count { pool = library.notes }
        var generator = SeededGenerator(seed: UInt64(truncatingIfNeeded: daySeed &* 31 &+ shuffle))
        pool.shuffle(using: &generator)
        return pool.prefix(count).compactMap { url in
            library.quote(url, seed: Int(generator.next() % 10_000)).map { (url, $0) }
        }
    }

    /// Opens a folder in the sidebar (all its notes listed there).
    private func reveal(_ folder: NotesLibrary.Node) {
        var set = Set(openFoldersRaw.split(separator: "\n").map(String.init))
        set.insert(folder.id)
        openFoldersRaw = set.sorted().joined(separator: "\n")
    }
}

/// The same pick all day for the same seed (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A card that rises a little under the pointer.
private struct LiftStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LiftBody(configuration: configuration)
    }

    private struct LiftBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .offset(y: hovering ? -1.5 : 0)
                .shadow(color: .black.opacity(hovering ? 0.1 : 0), radius: 10, y: 4)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// A row that shades under the pointer.
private struct HoverRowStyle: ButtonStyle {
    let theme: PlannerTheme
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, theme: theme)
    }

    private struct HoverBody: View {
        let configuration: ButtonStyleConfiguration
        let theme: PlannerTheme
        @State private var hovering = false
        var body: some View {
            configuration.label
                .padding(.horizontal, 6)
                .background(hovering ? theme.accent.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .padding(.horizontal, -6)
                .onHover { hovering = $0 }
        }
    }
}
#endif
