#if os(macOS)
import AppKit
import SwiftUI

/// The days and the notes, joined up:
/// - "#" in a line of the days opens a short menu by the cursor: make the line repeat (每天, 工作日, 每周…,
///   每月…), keep it every year (a birthday or an anniversary on that date), or join it to a note (one that
///   exists, or a new one named after the line). Typing after "#" narrows the menu; ↑↓ and Return choose.
/// - "[[note]]" in a line is a link: a click opens the note in a small window by the line, to read and write in,
///   with a button to open it full size among the notes.

extension NSTextView {
    /// The area the selection's highlight covers now (nil when nothing is selected), with a margin: drawn again
    /// when the selection changes, so no edge of the old highlight stays on screen.
    func selectionArea() -> NSRect? {
        guard let layout = layoutManager, let container = textContainer else { return nil }
        var area: NSRect?
        for value in selectedRanges {
            let range = value.rangeValue
            guard range.length > 0 else { continue }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y).insetBy(dx: -6, dy: -6)
            area = area.map { $0.union(rect) } ?? rect
        }
        // Whole lines, edge to edge (a highlight can run to the end of the line).
        return area.map { NSRect(x: bounds.minX, y: $0.minY, width: bounds.width, height: $0.height) }
    }
}

/// One choice in the "#" menu.
struct HashChoice: Identifiable {
    enum Action {
        case repeating(String)
        case yearly(ImportantDateKind)
        case note(URL)
        case newNote(String)
    }
    let id: String
    let symbol: String
    let title: String
    let detail: String
    let action: Action
}

@MainActor
final class HashMenuModel: ObservableObject {
    @Published var items: [HashChoice] = []
    @Published var selected = 0
}

struct HashMenuList: View {
    @ObservedObject var model: HashMenuModel
    let theme: PlannerTheme
    let pick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                Button { pick(index) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.symbol).font(.system(size: 12)).foregroundStyle(theme.accent).frame(width: 16)
                        Text(item.title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(theme.ink).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(item.detail).font(.system(size: 11.5)).foregroundStyle(theme.quiet).lineLimit(1)
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(index == model.selected ? theme.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(theme.sheet, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line))
    }
}

extension DocTextView {
    /// "#…" just before the cursor on a line of a day (not a heading): where it starts, and what's typed after it.
    var hashBeingWritten: (range: NSRange, query: String)? {
        guard selectedRange().length == 0, !hasMarkedText() || hashPanel != nil, let storage = textStorage else { return nil }
        let text = storage.string as NSString
        let at = selectedRange().location
        guard at > 0, at <= text.length else { return nil }
        let lineStart = text.paragraphRange(for: NSRange(location: at - 1, length: 0)).location
        let before = text.substring(with: NSRange(location: lineStart, length: at - lineStart))
        guard let match = before.range(of: #"[#＃][^\s#＃]{0,12}$"#, options: .regularExpression) else { return nil }
        // A "#" right after a letter is part of a word (C#), not the menu.
        if match.lowerBound > before.startIndex {
            let previous = before[before.index(before: match.lowerBound)]
            if previous.isLetter || previous.isNumber { return nil }
        }
        // Not on a day's heading, and not inside a tag already drawn.
        if storage.attribute(.asmoDay, at: lineStart, effectiveRange: nil) != nil { return nil }
        let start = lineStart + before.utf16.distance(from: before.utf16.startIndex, to: match.lowerBound.samePosition(in: before.utf16)!)
        if storage.attribute(.asmoTag, at: start, effectiveRange: nil) != nil { return nil }
        let query = String(before[match].dropFirst())
        return (NSRange(location: start, length: at - start), query)
    }

    /// The words of the line the cursor is on, without its bullet, time drawn in front, "#…" or links.
    private var lineWords: String {
        guard let storage = textStorage else { return "" }
        let text = storage.string as NSString
        var line = text.paragraphRange(for: NSRange(location: min(selectedRange().location, max(0, text.length - 1)), length: 0))
        // Only what comes before the "#" being typed.
        if let typed = hashBeingWritten, typed.range.location >= line.location {
            line.length = typed.range.location - line.location
        }
        var words = ""
        storage.enumerateAttributes(in: line) { attributes, range, _ in
            if attributes[.asmoTime] != nil || attributes[.asmoTag] != nil || attributes[.asmoCheck] != nil { return }
            words += text.substring(with: range)
        }
        return words
            .replacingOccurrences(of: #"^[\s•◦▪‣☐☑✦*-]*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[\[|\]\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{200B}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Shows, narrows or hides the "#" menu (after every change and cursor move).
    func updateHashMenu() {
        guard let typed = hashBeingWritten, window != nil, let coordinator else { hideHashMenu(); return }
        let query = typed.query.lowercased()
        var items: [HashChoice] = []
        for choice in coordinator.repeatChoices() ?? [] {
            items.append(HashChoice(id: "r" + choice.tag, symbol: "repeat", title: choice.label, detail: String(localized: "重复"),
                                    action: .repeating(choice.tag)))
        }
        let at = selectedRange().location
        if let day = coordinator.day(at: max(0, at - 1)), let dayNumber = day.day {
            let date = String(localized: "每年 \(day.month)月\(dayNumber)日")
            items.append(HashChoice(id: "y-birthday", symbol: "gift", title: String(localized: "生日"), detail: date, action: .yearly(.birthday)))
            items.append(HashChoice(id: "y-anniversary", symbol: "heart", title: String(localized: "纪念日"), detail: date, action: .yearly(.anniversary)))
        }
        let library = NotesLibrary.shared
        let words = lineWords
        if !words.isEmpty {
            items.append(HashChoice(id: "n-new", symbol: "square.and.pencil", title: String(localized: "新笔记「\(words)」"),
                                    detail: String(localized: "笔记"), action: .newNote(words)))
        }
        let notes = (query.isEmpty ? library.recent(4) : Array(library.named(query).prefix(6)))
        for url in notes {
            items.append(HashChoice(id: "n" + url.path, symbol: "doc.text", title: NotesLibrary.title(of: url),
                                    detail: (library.path(of: url) as NSString).deletingLastPathComponent, action: .note(url)))
        }
        if !query.isEmpty {
            items = items.filter { item in
                if case .note = item.action { return true }
                if case .newNote = item.action { return "笔记note".contains(query) || "新".contains(query) }
                return item.title.lowercased().contains(query) || item.detail.lowercased().contains(query)
                    || (query == "生" && item.id == "y-birthday")
            }
        }
        guard !items.isEmpty else { hideHashMenu(); return }
        hashModel.items = items
        hashModel.selected = min(hashModel.selected, items.count - 1)
        let panel = hashPanel ?? makeHashPanel()
        var caret = firstRect(forCharacterRange: NSRange(location: at, length: 0), actualRange: nil)
        if caret == .zero { caret = window?.convertToScreen(convert(bounds, to: nil)) ?? .zero }
        let height = CGFloat(items.count) * 30 + 12
        panel.setFrame(NSRect(x: caret.minX - 10, y: caret.minY - height - 6, width: 320, height: height), display: true)
        if panel.parent == nil { window?.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    private func makeHashPanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120), styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        panel.contentView = NSHostingView(rootView: HashMenuList(model: hashModel, theme: PlannerTheme(dark: dark)) { [weak self] index in
            self?.hashModel.selected = index
            self?.acceptHashChoice()
        })
        hashPanel = panel
        return panel
    }

    func hideHashMenu() {
        guard let panel = hashPanel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        hashPanel = nil
        hashModel.selected = 0
    }

    /// The menu's keys while it shows: ↑↓ to move, Return or Tab to choose, Esc to close. True when handled.
    func hashMenuCommand(_ selector: Selector) -> Bool {
        guard hashPanel != nil else { return false }
        switch selector {
        case #selector(moveDown(_:)): hashModel.selected = min(hashModel.selected + 1, max(0, hashModel.items.count - 1)); return true
        case #selector(moveUp(_:)): hashModel.selected = max(hashModel.selected - 1, 0); return true
        case #selector(insertNewline(_:)), #selector(insertTab(_:)): acceptHashChoice(); return true
        case #selector(cancelOperation(_:)): hideHashMenu(); return true
        default: return false
        }
    }

    private func acceptHashChoice() {
        guard let typed = hashBeingWritten, hashModel.items.indices.contains(hashModel.selected), let coordinator else { hideHashMenu(); return }
        let choice = hashModel.items[hashModel.selected]
        hideHashMenu()
        let words = lineWords
        // The "#…" typed goes; what was chosen takes its place.
        func replaceTyped(with text: String) {
            guard shouldChangeText(in: typed.range, replacementString: text) else { return }
            textStorage?.replaceCharacters(in: typed.range, with: NSAttributedString(string: text, attributes: typingAttributes))
            didChangeText()
            setSelectedRange(NSRange(location: typed.range.location + (text as NSString).length, length: 0))
        }
        switch choice.action {
        case .repeating(let tag):
            replaceTyped(with: "")
            coordinator.applyRepeat(tag)
        case .yearly(let kind):
            replaceTyped(with: "")
            guard !words.isEmpty, let day = coordinator.day(at: max(0, typed.range.location - 1)) else { NSSound.beep(); return }
            // The line becomes a date that comes back every year (shown with ✦ on its day from now on).
            removeCurrentLine()
            coordinator.parent.actions.yearly(words, day, kind)
        case .note(let url):
            replaceTyped(with: "[[\(NotesLibrary.title(of: url))]]")
            coordinator.linkNotes()
        case .newNote(let name):
            replaceTyped(with: "")
            guard let url = (try? NotesLibrary.shared.create(name: name)) ?? NotesLibrary.shared.note(named: name) else { NSSound.beep(); return }
            let title = NotesLibrary.title(of: url)
            let at = selectedRange().location
            let text = string as NSString
            let lead = at > 0 && text.character(at: at - 1) == 32 ? "" : " "
            insertText(lead + "[[\(title)]]", replacementRange: NSRange(location: at, length: 0))
            coordinator.linkNotes()
            // Opened by the line to be written in right away.
            peekNote(url, near: NSRange(location: at + (lead as NSString).length + 2, length: (title as NSString).length))
        }
    }

    private func removeCurrentLine() {
        guard let storage = textStorage else { return }
        let text = storage.string as NSString
        let line = text.paragraphRange(for: NSRange(location: min(selectedRange().location, max(0, text.length - 1)), length: 0))
        guard shouldChangeText(in: line, replacementString: "") else { return }
        storage.replaceCharacters(in: line, with: "")
        didChangeText()
    }

    // MARK: The note window

    /// The note in a small window by the link: written in there; "全屏" opens it among the notes.
    func peekNote(_ url: URL, near range: NSRange) {
        notePeek?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let theme = PlannerTheme(dark: dark)
        popover.contentViewController = NSHostingController(rootView: NotePeekView(
            url: url, theme: theme,
            full: { [weak self, weak popover] shown in
                popover?.close()
                self?.coordinator?.parent.actions.openNote(shown)
            }
        ))
        popover.contentSize = NSSize(width: 580, height: 500)
        var rect = firstRect(forCharacterRange: range, actualRange: nil)
        rect = window?.convertFromScreen(rect) ?? rect
        rect = convert(rect, from: nil)
        if rect.width < 1 { rect.size.width = 1 }
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
        notePeek = popover
    }
}

extension DocCoordinator {
    /// "[[note]]" in the lines of the days becomes a link to the note (the brackets quiet); a click opens it by the
    /// line. Runs over the lines given, or the whole page.
    func linkNotes(in range: NSRange? = nil) {
        guard let view, let storage = view.textStorage, storage.length > 0 else { return }
        let text = storage.string as NSString
        let covered = range ?? NSRange(location: 0, length: text.length)
        guard let regex = try? NSRegularExpression(pattern: #"\[\[([^\[\]\n]+)\]\]"#) else { return }
        let quiet = NSColor(parent.theme.quiet)
        for match in regex.matches(in: storage.string, range: covered) {
            let inner = match.range(at: 1)
            let name = NoteMarkdown.target(text.substring(with: inner))
            guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "asmo-note:" + encoded) else { continue }
            if (storage.attribute(.link, at: inner.location, effectiveRange: nil) as? URL) == url { continue }
            storage.addAttribute(.link, value: url, range: inner)
            storage.addAttribute(.foregroundColor, value: quiet.withAlphaComponent(0.7), range: NSRange(location: match.range.location, length: 2))
            storage.addAttribute(.foregroundColor, value: quiet.withAlphaComponent(0.7), range: NSRange(location: NSMaxRange(match.range) - 2, length: 2))
        }
    }

    /// A click on a [[note]] link in the days: the note by the line (made first, as in Obsidian, when there's none).
    func openNoteLink(_ url: URL, at index: Int) -> Bool {
        guard url.scheme == "asmo-note", let view = view as? DocTextView else { return false }
        let name = url.absoluteString.dropFirst("asmo-note:".count).removingPercentEncoding ?? ""
        return MainActor.assumeIsolated {
            let library = NotesLibrary.shared
            guard let note = library.note(named: name) ?? (try? library.create(name: name)) else { NSSound.beep(); return true }
            var range = NSRange(location: index, length: 1)
            _ = view.textStorage?.attribute(.link, at: index, effectiveRange: &range)
            view.peekNote(note, near: range)
            return true
        }
    }
}

/// A note in a small window: its name, a button to open it full size, and the note itself to write in.
struct NotePeekView: View {
    let url: URL
    let theme: PlannerTheme
    let full: (URL) -> Void

    @State private var shown: URL?
    @StateObject private var outline = NoteOutline()

    var body: some View {
        let current = shown ?? url
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").font(.system(size: 12)).foregroundStyle(theme.quiet)
                Text(NotesLibrary.title(of: current)).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.ink).lineLimit(1)
                Text((NotesLibrary.shared.path(of: current) as NSString).deletingLastPathComponent)
                    .font(.system(size: 11.5)).foregroundStyle(theme.quiet).lineLimit(1)
                Spacer()
                Button { full(current) } label: {
                    Label("全屏打开", systemImage: "arrow.up.left.and.arrow.down.right").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.accent).padding(.horizontal, 8).frame(height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("在笔记里打开这篇")
            }
            .padding(.horizontal, 14).frame(height: 42)
            Rectangle().fill(theme.line).frame(height: 1)
            NoteEditorView(url: current, theme: theme, library: NotesLibrary.shared, outline: outline, controller: nil,
                           open: { shown = $0 })
        }
        .background(theme.sheet)
    }
}
#endif
