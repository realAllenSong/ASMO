#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension NSAttributedString.Key {
    /// Drawn by NoteTextView instead of the characters: "bullet:DEPTH", "box:open", "box:done", "quote", "code",
    /// "front", "embed:PATH".
    static let noteDraw = NSAttributedString.Key("asmo.note.draw")
    /// The note a [[link]] opens.
    static let noteLink = NSAttributedString.Key("asmo.note.link")
    /// A picture drawn for the source it hides (a formula, a diagram, a drawing, a note inside the note).
    static let noteImage = NSAttributedString.Key("asmo.note.image")
}

/// A picture standing for source text: under its line (a block), or in the room its hidden source leaves (inline).
final class NoteImage: NSObject {
    let image: NSImage
    let size: NSSize
    let inline: Bool
    var centered = false
    /// On a white card (diagrams are drawn for white).
    var panel = false
    /// The note a click opens.
    var link: String?
    /// Where a click puts the caret to write the source (a table).
    var editAt: Int?
    /// How far in from the column's edge it's drawn (a table inside a callout).
    var indent: CGFloat = 0
    /// What it is ("math", "mermaid", "table", "note", "drawing") and the source it stands for (for the menu).
    var kind = ""
    var source: NSRange?

    init(image: NSImage, size: NSSize, inline: Bool, centered: Bool = false, panel: Bool = false, link: String? = nil,
         editAt: Int? = nil, indent: CGFloat = 0, kind: String = "", source: NSRange? = nil) {
        self.kind = kind
        self.source = source
        self.image = image
        self.size = size
        self.inline = inline
        self.centered = centered
        self.panel = panel
        self.link = link
        self.editAt = editAt
        self.indent = indent
    }
}

/// What a note page shows besides the text: its headings (the contents in the margin).
@MainActor
final class NoteOutline: ObservableObject {
    @Published var headings: [NoteMarkdown.Heading] = []
    /// The heading the reader is under (highlighted in the sidebar).
    @Published var current: Int?
    /// Set to a heading's range to go there.
    var go: ((NSRange) -> Void)?
    /// Words to show once the next note opens (a search result).
    var pendingFind: String?
    /// Shows words in the note open now.
    var find: ((String) -> Void)?
}

/// A note, edited as the Markdown it is. The text in the editor is the file (nothing is converted, so Obsidian and
/// Git see exactly what was written); it's drawn like a document: headings large, emphasis as emphasis, bullets and
/// checkboxes drawn, pictures shown under their line, [[links]] clickable. The marks (**, ##, [[ ]]) show on the line
/// being written and hide on the others.
struct NoteEditorView: NSViewRepresentable {
    let url: URL
    let theme: PlannerTheme
    @ObservedObject var library: NotesLibrary
    let outline: NoteOutline
    var controller: PageController?
    let open: (URL) -> Void
    /// Shown above the text, scrolling with it (the note's name).
    var header: AnyView?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        let view = NoteTextView(frame: .zero)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 0
        view.textContainerInset = NSSize(width: 48, height: 24)
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.smartInsertDeleteEnabled = false
        view.layoutManager?.allowsNonContiguousLayout = true
        view.linkTextAttributes = [.foregroundColor: NSColor(theme.accent), .underlineStyle: NSUnderlineStyle.single.rawValue,
                                   .underlineColor: NSColor(theme.accent).withAlphaComponent(0.35), .cursor: NSCursor.pointingHand]
        view.delegate = context.coordinator
        view.textStorage?.delegate = context.coordinator
        view.coordinator = context.coordinator
        scroll.documentView = view
        if let header {
            let hosting = NSHostingView(rootView: header)
            view.addSubview(hosting)
            view.header = hosting
        }
        context.coordinator.view = view
        context.coordinator.load()
        controller?.textView = view
        outline.go = { [weak coordinator = context.coordinator] range in coordinator?.go(to: range) }
        outline.find = { [weak coordinator = context.coordinator] words in coordinator?.show(words) }
        // The heading being read is followed in the sidebar.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) {
            [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated { coordinator?.scrolled() }
        }
        // A formula, diagram or drawing finished: drawn in place of its source.
        NotificationCenter.default.addObserver(forName: NoteRenders.ready, object: nil, queue: .main) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated { coordinator?.restyle() }
        }
        DispatchQueue.main.async { view.window?.makeFirstResponder(view); view.layoutColumn() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let urlChanged = coordinator.parent.url != url
        let darkChanged = coordinator.parent.theme.dark != theme.dark
        coordinator.parent = self
        if let view = coordinator.view {
            controller?.textView = view
            if let header { view.header?.rootView = header }
            view.layoutColumn()
        }
        if urlChanged {
            coordinator.save()
            coordinator.load()
        } else if darkChanged {
            coordinator.restyle()
        } else if library.changed != coordinator.seenChange {
            coordinator.seenChange = library.changed
            coordinator.reloadIfChangedOnDisk()
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.save()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: NoteEditorView
        weak var view: NoteTextView?
        var seenChange = 0
        /// The text as last read from or written to the file.
        private var saved = ""
        private var savedStamp = Date.distantPast
        private var pendingSave: DispatchWorkItem?
        private var pendingOutline: DispatchWorkItem?
        private var styling = false
        /// The line the caret was on (its marks are shown).
        private var caretLine: NSRange?
        /// Line breaks of the file ("\r\n" files are edited with "\n" and written back with "\r\n").
        private var crlf = false

        init(_ parent: NoteEditorView) { self.parent = parent }

        var library: NotesLibrary { parent.library }
        private var theme: PlannerTheme { parent.theme }
        var ink: NSColor { NSColor(theme.ink) }
        var quiet: NSColor { NSColor(theme.quiet) }
        var accent: NSColor { NSColor(theme.accent) }

        // MARK: File

        func load() {
            guard let view else { return }
            var text = library.read(parent.url) ?? ""
            crlf = text.contains("\r\n")
            if crlf { text = text.replacingOccurrences(of: "\r\n", with: "\n") }
            saved = text
            savedStamp = library.modifiedDate(parent.url)
            styling = true
            view.string = text
            styling = false
            caretLine = nil
            view.engaged = false
            view.setSelectedRange(NSRange(location: 0, length: 0))
            restyle()
            view.undoManager?.removeAllActions()
            view.scroll(.zero)
            outlineNow()
            library.noteOpened(parent.url)
            if let words = parent.outline.pendingFind {
                parent.outline.pendingFind = nil
                DispatchQueue.main.async { [weak self] in self?.show(words) }
            }
        }

        /// Selects the first place the words are written and brings it into view (opened from a search).
        func show(_ words: String) {
            guard let view else { return }
            let found = (view.string as NSString).range(of: words, options: [.caseInsensitive, .diacriticInsensitive])
            guard found.location != NSNotFound else { return }
            go(to: found)
            view.setSelectedRange(found)
            view.showFindIndicator(for: found)
        }

        private var trackingScroll = false

        /// Notes which heading the top of the window is under (a few times a second at most).
        func scrolled() {
            guard !trackingScroll else { return }
            trackingScroll = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.trackingScroll = false
                self?.trackHeading()
            }
        }

        private func trackHeading() {
            guard let view, let layout = view.layoutManager, let clip = view.enclosingScrollView?.contentView else { return }
            let headings = parent.outline.headings
            let top = clip.bounds.minY - view.textContainerOrigin.y + 90
            var index: Int?
            let length = view.string.utf16.count
            for (i, heading) in headings.enumerated() where heading.range.location < length {
                let glyph = layout.glyphIndexForCharacter(at: heading.range.location)
                if layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY <= top { index = i } else { break }
            }
            if parent.outline.current != index { parent.outline.current = index }
        }

        /// The paragraph style the caret's line has, for the toolbar (0 text, 1–6 a heading).
        private func publishStyle() {
            guard let view, let controller = parent.controller else { return }
            let string = view.string as NSString
            let line = string.paragraphRange(for: NSRange(location: min(view.selectedRange().location, string.length), length: 0))
            let text = string.substring(with: line)
            var level = 0
            if let match = text.range(of: #"^#{1,6}(?=\s)"#, options: .regularExpression) { level = text.distance(from: match.lowerBound, to: match.upperBound) }
            if controller.noteStyle != level { controller.noteStyle = level }
        }

        /// Writes the note if it changed (soon after typing stops, and when leaving it).
        func save() {
            pendingSave?.cancel()
            pendingSave = nil
            guard let view else { return }
            let text = view.string
            guard text != saved else { return }
            let output = crlf ? text.replacingOccurrences(of: "\n", with: "\r\n") : text
            do {
                try library.write(output, to: parent.url)
                saved = text
                savedStamp = library.modifiedDate(parent.url)
            } catch {
                NSSound.beep()
            }
        }

        private func scheduleSave() {
            pendingSave?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.save() }
            pendingSave = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }

        /// The file was written by something else (Git, the phone, an agent): read again, unless there's writing
        /// here that isn't saved yet (that wins, and is saved over it).
        func reloadIfChangedOnDisk() {
            guard let view else { return }
            let stamp = library.modifiedDate(parent.url)
            guard stamp > savedStamp.addingTimeInterval(0.5) else { return }
            if view.string != saved { save(); return }
            let selection = view.selectedRange()
            let origin = (view.enclosingScrollView?.contentView.bounds.origin) ?? .zero
            load()
            view.setSelectedRange(NSRange(location: min(selection.location, view.string.utf16.count), length: 0))
            view.scroll(origin)
        }

        // MARK: Drawing the Markdown

        private var bodyFont: NSFont { .systemFont(ofSize: 16) }
        private var monoFont: NSFont { .monospacedSystemFont(ofSize: 13.5, weight: .regular) }
        private let hiddenFont = NSFont.systemFont(ofSize: 0.1)
        private var tableFont: NSFont { .systemFont(ofSize: 14.5) }

        private func paragraph(before: CGFloat = 0, after: CGFloat = 6, indent: CGFloat = 0) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 5
            style.paragraphSpacing = after
            style.paragraphSpacingBefore = before
            style.headIndent = indent
            style.firstLineHeadIndent = indent
            return style
        }

        /// A line that takes (almost) no room: the hidden lines of a block shown as a picture or a table's
        /// "|---|" line.
        private var flat: NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.maximumLineHeight = 0.5
            style.lineSpacing = 0
            return style
        }

        private var base: [NSAttributedString.Key: Any] {
            [.font: bodyFont, .foregroundColor: ink, .paragraphStyle: paragraph()]
        }

        /// What a line is part of beyond itself.
        enum Block {
            case code(language: String)
            case callout(type: String, first: Bool)
            /// Lines shown as one picture: "math" between $$, "mermaid" in a ```mermaid fence.
            case rendered(kind: String, source: String, first: Bool)
            /// A table (inside a callout of that kind, or not), drawn as a picture with its cells wrapped.
            case table(callout: String?, first: Bool)
        }

        /// The blocks of the note: each line's block (by the line's start) with the whole block's range.
        private func blocks(_ lines: [NoteMarkdown.Line], _ string: NSString) -> [Int: (block: Block, whole: NSRange)] {
            var result: [Int: (Block, NSRange)] = [:]
            func whole(_ from: Int, _ to: Int) -> NSRange {
                NSRange(location: lines[from].range.location, length: NSMaxRange(lines[to].range) - lines[from].range.location)
            }
            var index = 0
            while index < lines.count {
                let line = lines[index]
                let text = string.substring(with: line.range)
                switch line.kind {
                case .fence:
                    var end = index + 1
                    while end < lines.count, lines[end].kind != .fence { end += 1 }
                    let last = min(end, lines.count - 1)
                    let language = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "`~"))
                        .trimmingCharacters(in: .whitespaces).lowercased()
                    let range = whole(index, last)
                    if language == "mermaid", end < lines.count {
                        let source = lines[(index + 1)..<end].map { string.substring(with: $0.range) }.joined(separator: "\n")
                        for i in index...last { result[lines[i].range.location] = (.rendered(kind: "mermaid", source: source, first: i == index), range) }
                    } else {
                        for i in index...last { result[lines[i].range.location] = (.code(language: language), range) }
                    }
                    index = last + 1
                case .mathFence:
                    var end = index + 1
                    while end < lines.count, lines[end].kind != .mathFence { end += 1 }
                    let last = min(end, lines.count - 1)
                    let source = lines[(index + 1)..<max(index + 1, end)].map { string.substring(with: $0.range) }.joined(separator: "\n")
                    if end < lines.count, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let range = whole(index, last)
                        for i in index...last { result[lines[i].range.location] = (.rendered(kind: "math", source: source, first: i == index), range) }
                    }
                    index = last + 1
                case .math:
                    // "$$x$$" on a line of its own.
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count > 4 {
                        let source = String(trimmed.dropFirst(2).dropLast(2))
                        result[line.range.location] = (.rendered(kind: "math", source: source, first: true), line.range)
                    }
                    index += 1
                case .table:
                    var end = index
                    while end + 1 < lines.count, lines[end + 1].kind == .table { end += 1 }
                    // A table has its "|---|" line second.
                    if end > index, NoteMarkdown.isTableSeparator(string.substring(with: lines[index + 1].range)) {
                        let range = whole(index, end)
                        for i in index...end { result[lines[i].range.location] = (.table(callout: nil, first: i == index), range) }
                    }
                    index = end + 1
                case .quote:
                    if let callout = NoteMarkdown.callout(text) {
                        var end = index
                        while end + 1 < lines.count, lines[end + 1].kind == .quote { end += 1 }
                        let range = whole(index, end)
                        for i in index...end { result[lines[i].range.location] = (.callout(type: callout.type, first: i == index), range) }
                        // A table inside the callout ("> | a | b |"): its rows are one table, drawn on the callout.
                        var row = index + 1
                        while row <= end {
                            var last = row
                            func isRow(_ i: Int) -> Bool {
                                NoteMarkdown.unquoted(string.substring(with: lines[i].range)).text.trimmingCharacters(in: .whitespaces).hasPrefix("|")
                            }
                            guard isRow(row) else { row += 1; continue }
                            while last + 1 <= end, isRow(last + 1) { last += 1 }
                            if last > row, NoteMarkdown.isTableSeparator(NoteMarkdown.unquoted(string.substring(with: lines[row + 1].range)).text) {
                                let rows = whole(row, last)
                                for i in row...last { result[lines[i].range.location] = (.table(callout: callout.type, first: i == row), rows) }
                            }
                            row = last + 1
                        }
                        index = end + 1
                    } else {
                        index += 1
                    }
                default:
                    index += 1
                }
            }
            return result
        }

        /// The caret is in this block (its source shows, to be written).
        private func editing(_ range: NSRange) -> Bool {
            guard let caretLine else { return false }
            return NSIntersectionRange(caretLine, NSRange(location: range.location, length: max(range.length, 1))).length > 0
                || (caretLine.location >= range.location && caretLine.location <= NSMaxRange(range))
        }

        /// Draws the whole note again.
        func restyle() {
            guard let storage = view?.textStorage else { return }
            view?.linkedPictures = [:]
            view?.editablePictures = [:]
            view?.drawn = [:]
            styling = true
            storage.beginEditing()
            let lines = NoteMarkdown.lines(storage.string)
            let found = blocks(lines, storage.string as NSString)
            for line in lines { style(line, block: found[line.range.location], in: storage) }
            storage.endEditing()
            styling = false
            view?.typingAttributes = base
            view?.needsDisplay = true
        }

        /// Draws again the lines a range touches (after an edit, or the caret moving on or off them), and the whole
        /// of any block (table, formula, callout…) they are in.
        private func restyle(around range: NSRange) {
            guard let storage = view?.textStorage, storage.length >= 0 else { return }
            let string = storage.string as NSString
            var covered = string.paragraphRange(for: NSRange(location: min(range.location, string.length), length: min(range.length, max(0, string.length - range.location))))
            let lines = NoteMarkdown.lines(storage.string)
            let found = blocks(lines, string)
            for line in lines where touches(line, covered) {
                if let whole = found[line.range.location]?.whole { covered = NSUnionRange(covered, whole) }
            }
            styling = true
            storage.beginEditing()
            for line in lines where touches(line, covered) {
                style(line, block: found[line.range.location], in: storage)
            }
            storage.endEditing()
            styling = false
            view?.needsDisplay = true
        }

        private func touches(_ line: NoteMarkdown.Line, _ covered: NSRange) -> Bool {
            NSIntersectionRange(NSRange(location: line.range.location, length: max(line.range.length, 1)), covered).length > 0
                || (line.range.location >= covered.location && line.range.location <= NSMaxRange(covered))
        }

        private func style(_ line: NoteMarkdown.Line, block: (block: Block, whole: NSRange)?, in storage: NSTextStorage) {
            let string = storage.string as NSString
            // The line with its break (attributes of the break set the paragraph's spacing).
            var whole = line.range
            if NSMaxRange(whole) < string.length { whole.length += 1 }
            guard NSMaxRange(whole) <= storage.length else { return }
            let showMarks = caretLine.map { NSIntersectionRange($0, whole).length > 0 || $0.location == line.range.location } ?? false
            // A formula or diagram, not being written: its picture instead of its lines.
            if case .rendered(let kind, let source, let first)? = block?.block, let range = block?.whole, !editing(range),
               let image = kind == "math" ? NoteRenders.shared.math(source, display: true, color: ink) : NoteRenders.shared.mermaid(source) {
                storage.setAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear, .paragraphStyle: flat], range: whole)
                if first {
                    let size = fitted(image.size, maxHeight: kind == "math" ? 400 : 640)
                    let style = paragraph(before: 4, after: size.height + 12)
                    style.lineSpacing = 0
                    storage.addAttributes([.paragraphStyle: style,
                                           .noteImage: NoteImage(image: image, size: size, inline: false, centered: kind == "math", panel: kind == "mermaid",
                                                                 kind: kind, source: range)],
                                          range: whole)
                }
                return
            }
            // A table, not being written: drawn as a table (cells wrap to fit the column); its lines step aside.
            if case .table(let callout, let first)? = block?.block, let range = block?.whole, !editing(range) {
                storage.setAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear, .paragraphStyle: flat], range: whole)
                if let callout { storage.addAttribute(.noteDraw, value: "callout:" + callout, range: whole) }
                if first {
                    let indent: CGFloat = callout == nil ? 0 : 16
                    let source = string.substring(with: range)
                    let image = tableImage(source, width: max(200, (view?.columnWidth ?? 760) - 4 - indent * 1.75))
                    let style = paragraph(before: 4, after: image.size.height + 12)
                    style.lineSpacing = 0
                    storage.addAttributes([.paragraphStyle: style,
                                           .noteImage: NoteImage(image: image, size: image.size, inline: false, editAt: range.location, indent: indent,
                                                                 kind: "table", source: range)],
                                          range: whole)
                }
                return
            }
            var attributes = base
            switch line.kind {
            case .heading(let level):
                let sizes: [CGFloat] = [26, 22, 19, 17, 16, 16]
                attributes[.font] = NSFont.systemFont(ofSize: sizes[min(level, 6) - 1], weight: .bold)
                attributes[.paragraphStyle] = paragraph(before: level <= 2 ? 14 : 8, after: 6)
            case .code, .fence:
                attributes[.font] = monoFont
                attributes[.paragraphStyle] = paragraph(after: 0, indent: 14)
                attributes[.noteDraw] = "code"
                if case .fence = line.kind { attributes[.foregroundColor] = quiet }
            case .frontmatter:
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
                attributes[.foregroundColor] = quiet
                attributes[.paragraphStyle] = paragraph(after: 0, indent: 12)
                attributes[.noteDraw] = "front"
            case .math, .mathFence:
                attributes[.font] = monoFont
                attributes[.foregroundColor] = accent
                attributes[.paragraphStyle] = paragraph(after: 2, indent: 12)
            case .table:
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
                attributes[.paragraphStyle] = paragraph(after: 0)
            case .quote:
                if case .table(let type?, _)? = block?.block {
                    // A table in a callout, being written: its source, on the callout.
                    attributes[.font] = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
                    let style = paragraph(after: 0, indent: 16)
                    style.tailIndent = -12
                    attributes[.paragraphStyle] = style
                    attributes[.noteDraw] = "callout:" + type
                } else if case .callout(let type, let first)? = block?.block {
                    let style = paragraph(before: first ? 4 : 0, after: 0, indent: 16)
                    style.tailIndent = -12
                    attributes[.paragraphStyle] = style
                    attributes[.noteDraw] = "callout:" + type
                } else {
                    attributes[.foregroundColor] = quiet
                    attributes[.paragraphStyle] = paragraph(indent: 16)
                }
            case .rule:
                attributes[.foregroundColor] = quiet
                attributes[.paragraphStyle] = paragraph(before: 6, after: 10)
                if !showMarks { attributes[.font] = NSFont.systemFont(ofSize: 8); attributes[.foregroundColor] = NSColor.clear }
                attributes[.noteDraw] = "rule"
            default:
                break
            }
            storage.setAttributes(attributes, range: whole)
            if case .embed(let target) = line.kind {
                embed(target, line: line, showMarks: showMarks, in: storage)
                return
            }
            if case .callout(_, let first)? = block?.block {
                decorateCallout(line, first: first, showMarks: showMarks, in: storage)
                if !first { decorateQuoted(line, showMarks: showMarks, in: storage) }
            } else if let marker = line.marker {
                decorateMarker(line, marker: marker, showMarks: showMarks, in: storage)
                if case .quote = line.kind { decorateQuoted(line, showMarks: showMarks, in: storage) }
            }
            switch line.kind {
            case .code:
                if case .code(let language)? = block?.block { colourCode(line, language: language, in: storage) }
                return
            case .fence, .frontmatter, .math, .mathFence, .rule:
                return
            case .task(_, let done) where done:
                let words = NSRange(location: NSMaxRange(line.marker ?? line.range), length: NSMaxRange(line.range) - NSMaxRange(line.marker ?? line.range))
                if words.length > 0 {
                    storage.addAttributes([.foregroundColor: quiet, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: words)
                }
            default:
                break
            }
            for span in NoteMarkdown.spans(in: string, line: line.range) { decorate(span, showMarks: showMarks, in: storage) }
        }

        /// A picture's size on the page: no wider than the column, no taller than `maxHeight`.
        private func fitted(_ size: NSSize, maxHeight: CGFloat) -> NSSize {
            let width = max(200, (view?.columnWidth ?? 760) - 4)
            var result = size
            if result.width > width { result = NSSize(width: width, height: result.height * width / result.width) }
            if result.height > maxHeight { result = NSSize(width: result.width * maxHeight / result.height, height: maxHeight) }
            return result
        }

        private func hide(_ range: NSRange, in storage: NSTextStorage) {
            guard range.length > 0 else { return }
            storage.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: range)
        }

        /// "> [!tip] Title": the marks go, the title (or the kind, when there's none) shows bold in the callout's
        /// colour; the other lines lose their "> ".
        private func decorateCallout(_ line: NoteMarkdown.Line, first: Bool, showMarks: Bool, in storage: NSTextStorage) {
            let string = storage.string as NSString
            let text = string.substring(with: line.range)
            if first, let callout = NoteMarkdown.callout(text) {
                let colour = NoteTextView.calloutColour(callout.type)
                let marker = NSRange(location: line.range.location + callout.marker.location, length: callout.marker.length)
                let title = NSRange(location: line.range.location + callout.title.location, length: callout.title.length)
                let bold = NSFont.systemFont(ofSize: 15.5, weight: .semibold)
                if showMarks {
                    storage.addAttribute(.foregroundColor, value: quiet, range: marker)
                    storage.addAttributes([.font: bold, .foregroundColor: colour], range: title)
                } else if title.length > 0 {
                    hide(NSRange(location: marker.location, length: title.location - marker.location), in: storage)
                    storage.addAttributes([.font: bold, .foregroundColor: colour], range: title)
                } else {
                    // No title: the kind's name shows ("tip"), the brackets don't.
                    let kind = (text as NSString).range(of: callout.type, options: .caseInsensitive, range: callout.marker)
                    let shown = NSRange(location: line.range.location + kind.location, length: kind.length)
                    hide(NSRange(location: marker.location, length: shown.location - marker.location), in: storage)
                    hide(NSRange(location: NSMaxRange(shown), length: NSMaxRange(marker) - NSMaxRange(shown)), in: storage)
                    storage.addAttributes([.font: bold, .foregroundColor: colour], range: shown)
                }
                return
            }
            guard let marker = line.marker else { return }
            if showMarks { storage.addAttribute(.foregroundColor, value: quiet, range: marker) } else { hide(marker, in: storage) }
        }

        /// Keywords, strings, comments and numbers in their colours.
        private func colourCode(_ line: NoteMarkdown.Line, language: String, in storage: NSTextStorage) {
            let hash: Set<String> = ["python", "py", "sh", "bash", "zsh", "shell", "console", "yaml", "yml", "ruby", "rb", "r", "toml",
                                     "perl", "dockerfile", "makefile", "make", "conf", "nginx", "powershell", "ps1", "julia", "elixir"]
            let text = (storage.string as NSString).substring(with: line.range)
            let dark = theme.dark
            for token in NoteMarkdown.codeTokens(text, hashComments: hash.contains(language)) {
                let colour: NSColor
                switch token.kind {
                case .keyword: colour = dark ? NSColor(red: 0.98, green: 0.47, blue: 0.67, alpha: 1) : NSColor(red: 0.68, green: 0.1, blue: 0.45, alpha: 1)
                case .string: colour = dark ? NSColor(red: 0.6, green: 0.84, blue: 0.5, alpha: 1) : NSColor(red: 0.13, green: 0.5, blue: 0.13, alpha: 1)
                case .comment: colour = quiet
                case .number: colour = dark ? NSColor(red: 0.98, green: 0.72, blue: 0.42, alpha: 1) : NSColor(red: 0.7, green: 0.38, blue: 0.0, alpha: 1)
                }
                storage.addAttribute(.foregroundColor, value: colour, range: NSRange(location: line.range.location + token.range.location, length: token.range.length))
            }
        }

        private func decorateMarker(_ line: NoteMarkdown.Line, marker: NSRange, showMarks: Bool, in storage: NSTextStorage,
                                    base: CGFloat = 0) {
            let string = storage.string as NSString
            switch line.kind {
            case .heading:
                if showMarks { storage.addAttribute(.foregroundColor, value: quiet, range: marker) } else { hide(marker, in: storage) }
            case .bullet(let depth, let ordered):
                let indent = base + CGFloat(depth) * 22
                storage.addAttribute(.paragraphStyle, value: hanging(indent: indent, marker: 22, inBox: base > 0), range: string.paragraphRange(for: line.range))
                if ordered {
                    storage.addAttribute(.foregroundColor, value: quiet, range: marker)
                } else if !showMarks {
                    // The "-" is drawn as a dot.
                    let dash = dashRange(in: marker, string: string)
                    // Room after the dot, as in any list.
                    storage.addAttributes([.foregroundColor: NSColor.clear, .noteDraw: "bullet:\(depth)", .kern: 7], range: dash)
                } else {
                    storage.addAttribute(.foregroundColor, value: quiet, range: marker)
                }
            case .task(let depth, let done):
                let indent = base + CGFloat(depth) * 22
                storage.addAttribute(.paragraphStyle, value: hanging(indent: indent, marker: 26, inBox: base > 0), range: string.paragraphRange(for: line.range))
                if showMarks {
                    storage.addAttribute(.foregroundColor, value: quiet, range: marker)
                } else {
                    // "- " goes; "[ ]" is drawn as a box.
                    let box = line.box ?? marker
                    hide(NSRange(location: marker.location, length: box.location - marker.location), in: storage)
                    storage.addAttributes([.foregroundColor: NSColor.clear, .noteDraw: done ? "box:done" : "box:open"], range: box)
                    // The box is a little wider than "[ ]": room after it.
                    storage.addAttribute(.kern, value: 8, range: NSRange(location: NSMaxRange(box) - 1, length: 1))
                }
            case .quote:
                storage.addAttribute(.noteDraw, value: "quote", range: string.paragraphRange(for: line.range))
                if showMarks { storage.addAttribute(.foregroundColor, value: quiet, range: marker) } else { hide(marker, in: storage) }
            default:
                break
            }
        }

        /// What a quote's line holds after its "> ": a list item, a checkbox or a heading, drawn as such inside the
        /// quote or callout.
        private func decorateQuoted(_ line: NoteMarkdown.Line, showMarks: Bool, in storage: NSTextStorage) {
            let string = storage.string as NSString
            let (prefix, inner) = NoteMarkdown.unquoted(string.substring(with: line.range))
            guard prefix > 0, !inner.isEmpty, var item = NoteMarkdown.lines(inner).first else { return }
            let shift = line.range.location + prefix
            func moved(_ range: NSRange?) -> NSRange? { range.map { NSRange(location: $0.location + shift, length: $0.length) } }
            item.range = NSRange(location: item.range.location + shift, length: item.range.length)
            item.marker = moved(item.marker)
            item.box = moved(item.box)
            switch item.kind {
            case .bullet, .task:
                if let marker = item.marker { decorateMarker(item, marker: marker, showMarks: showMarks, in: storage, base: 16) }
                if case .task(_, true) = item.kind, let marker = item.marker {
                    let words = NSRange(location: NSMaxRange(marker), length: NSMaxRange(item.range) - NSMaxRange(marker))
                    if words.length > 0 { storage.addAttributes([.foregroundColor: quiet, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: words) }
                }
            case .heading(let level):
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: level <= 2 ? 17 : 16, weight: .bold), range: item.range)
                if let marker = item.marker {
                    if showMarks { storage.addAttribute(.foregroundColor, value: quiet, range: marker) } else { hide(marker, in: storage) }
                }
            default:
                break
            }
        }

        private var tablePictures: [String: NSImage] = [:]

        /// A table as a picture: columns sized to their words and shared out when the column is too narrow for all
        /// of them (the words then wrap inside their cells), the header shaded, a hairline grid.
        private func tableImage(_ source: String, width available: CGFloat) -> NSImage {
            let key = "\(theme.dark)|\(Int(available))|" + source
            if let known = tablePictures[key] { return known }
            let lines = source.components(separatedBy: "\n")
            var rows: [[String]] = []
            var alignments: [NSTextAlignment] = []
            for (index, line) in lines.enumerated() {
                let inner = NoteMarkdown.unquoted(line).text
                if index == 1, NoteMarkdown.isTableSeparator(inner) {
                    alignments = NoteMarkdown.tableRow(inner).map { cell in
                        let c = cell.trimmingCharacters(in: .whitespaces)
                        return c.hasPrefix(":") && c.hasSuffix(":") ? .center : c.hasSuffix(":") ? .right : .left
                    }
                    continue
                }
                if !inner.trimmingCharacters(in: .whitespaces).isEmpty { rows.append(NoteMarkdown.tableRow(inner)) }
            }
            let columns = max(1, rows.map(\.count).max() ?? 1)
            let pad: CGFloat = 10, vpad: CGFloat = 7
            let cells: [[NSAttributedString]] = rows.enumerated().map { r, row in
                (0..<columns).map { c in
                    cellText(c < row.count ? row[c] : "", header: r == 0, alignment: c < alignments.count ? alignments[c] : .left)
                }
            }
            // Each column's natural width (its longest cell on one line), then shared out if they don't all fit.
            var natural = (0..<columns).map { c in
                cells.map { ceil($0[c].size().width) }.max() ?? 0
            }.map { max(36, $0 + pad * 2) }
            if natural.reduce(0, +) > available {
                var widths = Array(repeating: CGFloat(0), count: columns)
                var open = Set(0..<columns)
                var left = available
                var settled = true
                while settled, !open.isEmpty {
                    settled = false
                    let share = left / CGFloat(open.count)
                    for c in open where natural[c] <= share {
                        widths[c] = natural[c]; left -= natural[c]; open.remove(c); settled = true
                    }
                }
                let share = left / CGFloat(max(1, open.count))
                for c in open { widths[c] = max(56, share) }
                natural = widths
            }
            let widths = natural
            let heights = cells.map { row in
                row.enumerated().map { c, text in
                    ceil(text.boundingRect(with: NSSize(width: widths[c] - pad * 2, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
                }.max() ?? 18
            }.map { $0 + vpad * 2 }
            let size = NSSize(width: ceil(widths.reduce(0, +)) + 1, height: ceil(heights.reduce(0, +)) + 1)
            let header = quiet.withAlphaComponent(0.12)
            let grid = quiet.withAlphaComponent(0.32)
            let image = NSImage(size: size, flipped: true) { _ in
                header.setFill()
                NSRect(x: 0, y: 0, width: size.width, height: heights.first ?? 0).fill()
                var y: CGFloat = 0
                for (r, row) in cells.enumerated() {
                    var x: CGFloat = 0
                    for (c, text) in row.enumerated() {
                        text.draw(with: NSRect(x: x + pad, y: y + vpad, width: widths[c] - pad * 2, height: heights[r] - vpad * 2),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading])
                        x += widths[c]
                    }
                    y += heights[r]
                }
                grid.setStroke()
                let path = NSBezierPath()
                path.lineWidth = 1
                y = 0.5
                for height in [0] + heights {
                    y += height
                    path.move(to: NSPoint(x: 0, y: (y - (height == 0 ? 0 : 0)).rounded(.down) + 0.5))
                    path.line(to: NSPoint(x: size.width, y: y.rounded(.down) + 0.5))
                }
                var x: CGFloat = 0
                for width in [0] + widths {
                    x += width
                    path.move(to: NSPoint(x: x.rounded(.down) + 0.5, y: 0))
                    path.line(to: NSPoint(x: x.rounded(.down) + 0.5, y: size.height))
                }
                path.stroke()
                return true
            }
            tablePictures[key] = image
            return image
        }

        /// A cell's Markdown as styled text: **bold**, *italic*, `code`, ~~strike~~, ==highlight==, links and
        /// [[links]] as their words, <br> as a new line.
        private func cellText(_ raw: String, header: Bool, alignment: NSTextAlignment) -> NSAttributedString {
            let font = NSFont.systemFont(ofSize: 14, weight: header ? .semibold : .regular)
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3
            style.alignment = alignment
            var text = raw.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression, range: nil)
            text = text.replacingOccurrences(of: #"\[\[([^\]|]*)\|([^\]]*)\]\]"#, with: "$2", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\[\[([^\]]*)\]\]"#, with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            let result = NSMutableAttributedString(string: "", attributes: [.font: font, .foregroundColor: ink, .paragraphStyle: style])
            // One pass over the marks: each kind restyles its words and drops its marks.
            let pattern = #"\*\*(.+?)\*\*|`([^`]+)`|~~(.+?)~~|==(.+?)==|(?<![*\w])\*([^*\s][^*]*?)\*(?!\*)|\$([^$]+)\$"#
            let regex = try? NSRegularExpression(pattern: pattern)
            let ns = text as NSString
            var at = 0
            let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .paragraphStyle: style]
            for match in regex?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [] {
                if match.range.location > at {
                    result.append(NSAttributedString(string: ns.substring(with: NSRange(location: at, length: match.range.location - at)), attributes: base))
                }
                var attributes = base
                var group = 1
                while group <= 6, match.range(at: group).location == NSNotFound { group += 1 }
                let words = group <= 6 ? ns.substring(with: match.range(at: group)) : ns.substring(with: match.range)
                switch group {
                case 1: attributes[.font] = NSFont.systemFont(ofSize: 14, weight: .semibold)
                case 2: attributes[.font] = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
                        attributes[.backgroundColor] = quiet.withAlphaComponent(0.14)
                case 3: attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue; attributes[.foregroundColor] = quiet
                case 4: attributes[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(theme.dark ? 0.35 : 0.4)
                case 5: attributes[.obliqueness] = 0.16
                default: attributes[.font] = NSFont(name: "Times New Roman Italic", size: 15) ?? font; attributes[.foregroundColor] = accent
                }
                result.append(NSAttributedString(string: words, attributes: attributes))
                at = NSMaxRange(match.range)
            }
            if at < ns.length { result.append(NSAttributedString(string: ns.substring(from: at), attributes: base)) }
            return result
        }

        /// Lines of a list wrap under their words, not under the bullet.
        private func hanging(indent: CGFloat, marker: CGFloat, inBox: Bool = false) -> NSParagraphStyle {
            let style = paragraph(after: inBox ? 0 : 3)
            if inBox { style.tailIndent = -12 }
            style.firstLineHeadIndent = indent
            style.headIndent = indent + marker
            return style
        }

        private func dashRange(in marker: NSRange, string: NSString) -> NSRange {
            let text = string.substring(with: marker)
            // Any kind of space before the dash (a no-break space pasted in counts too).
            let offset = text.prefix { $0.isWhitespace }.utf16.count
            return NSRange(location: marker.location + offset, length: 1)
        }

        private func decorate(_ span: NoteMarkdown.Span, showMarks: Bool, in storage: NSTextStorage) {
            let marks = [NSRange(location: span.range.location, length: span.content.location - span.range.location),
                         NSRange(location: NSMaxRange(span.content), length: NSMaxRange(span.range) - NSMaxRange(span.content))]
            func hideMarks() {
                for mark in marks where mark.length > 0 {
                    if showMarks { storage.addAttribute(.foregroundColor, value: quiet.withAlphaComponent(0.6), range: mark) }
                    else { hide(mark, in: storage) }
                }
            }
            let content = span.content
            switch span.kind {
            case .bold:
                storage.enumerateAttribute(.font, in: content) { value, range, _ in
                    let font = (value as? NSFont) ?? bodyFont
                    storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: range)
                }
                hideMarks()
            case .italic:
                storage.addAttribute(.obliqueness, value: 0.16, range: content)
                hideMarks()
            case .strike:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: content)
                hideMarks()
            case .highlight:
                storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(theme.dark ? 0.35 : 0.4), range: content)
                hideMarks()
            case .code:
                storage.addAttributes([.font: monoFont, .backgroundColor: quiet.withAlphaComponent(0.14)], range: content)
                hideMarks()
            case .math:
                // A formula among words: its picture, in the room of its hidden source, once it's made.
                let source = (storage.string as NSString).substring(with: content)
                if !showMarks, let image = NoteRenders.shared.math(source, display: false, color: ink) {
                    let size = fitted(image.size, maxHeight: 60)
                    hide(span.range, in: storage)
                    storage.addAttribute(.kern, value: size.width + 2, range: NSRange(location: NSMaxRange(span.range) - 1, length: 1))
                    storage.addAttribute(.noteImage, value: NoteImage(image: image, size: size, inline: true, kind: "math", source: span.range), range: span.range)
                    if size.height > 20, let current = storage.attribute(.paragraphStyle, at: span.range.location, effectiveRange: nil) as? NSParagraphStyle {
                        let style = current.mutableCopy() as! NSMutableParagraphStyle
                        style.minimumLineHeight = max(style.minimumLineHeight, size.height + 2)
                        let paragraph = (storage.string as NSString).paragraphRange(for: span.range)
                        storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
                    }
                } else {
                    storage.addAttributes([.font: monoFont, .foregroundColor: accent], range: content)
                    hideMarks()
                }
            case .footnote:
                storage.addAttributes([.font: NSFont.systemFont(ofSize: 11, weight: .medium), .baselineOffset: 6, .foregroundColor: accent], range: content)
                hideMarks()
            case .comment:
                storage.addAttributes([.foregroundColor: quiet.withAlphaComponent(0.65), .obliqueness: 0.12], range: span.range)
                hideMarks()
            case .tag:
                storage.addAttributes([.foregroundColor: accent, .backgroundColor: accent.withAlphaComponent(0.1)], range: span.range)
            case .url:
                if let url = URL(string: (storage.string as NSString).substring(with: span.range)) {
                    storage.addAttribute(.link, value: url, range: span.range)
                }
            case .link(let address):
                if let url = URL(string: address) ?? URL(string: address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") {
                    storage.addAttribute(.link, value: url, range: content)
                }
                hideMarks()
            case .wikilink(let target):
                let exists = library.note(named: target, from: parent.url) != nil
                storage.addAttributes([.foregroundColor: exists ? accent : quiet, .noteLink: target,
                                       .underlineStyle: NSUnderlineStyle.single.rawValue,
                                       .underlineColor: (exists ? accent : quiet).withAlphaComponent(0.35),
                                       .cursor: NSCursor.pointingHand], range: content)
                hideMarks()
            case .embed:
                // A picture inside a line of words: shown as its name (pictures on their own line are drawn).
                storage.addAttribute(.foregroundColor, value: quiet, range: span.range)
            }
        }

        /// A picture or drawing on its own line: drawn below the line, which leaves room for it; the line's text
        /// shows only while the caret is on it.
        private func embed(_ target: String, line: NoteMarkdown.Line, showMarks: Bool, in storage: NSTextStorage) {
            let string = storage.string as NSString
            let paragraphRange = string.paragraphRange(for: line.range)
            guard let file = library.attachment(named: target, from: parent.url) else {
                storage.addAttribute(.foregroundColor, value: quiet, range: line.range)
                return
            }
            func shown(_ image: NSImage, size: NSSize, link: String?, kind: String) {
                let style = paragraph(after: size.height + 14)
                storage.addAttributes([.paragraphStyle: style,
                                       .noteImage: NoteImage(image: image, size: size, inline: false, link: link, kind: kind, source: line.range)],
                                      range: paragraphRange)
                if showMarks { storage.addAttributes([.foregroundColor: quiet, .font: NSFont.systemFont(ofSize: 13)], range: line.range) }
                else { hide(line.range, in: storage) }
            }
            if file.pathExtension.lowercased() == "md" {
                let raw = string.substring(with: line.range)
                if file.lastPathComponent.lowercased().hasSuffix(".excalidraw.md") {
                    // A drawing: its picture, once made (a click opens it to draw).
                    if let image = DrawingPreviews.preview(file) {
                        shown(image, size: fitted(image.size, maxHeight: 560), link: NotesLibrary.title(of: file), kind: "drawing")
                    } else {
                        storage.addAttribute(.foregroundColor, value: quiet, range: line.range)
                    }
                    return
                }
                // Another note (or a part of it, "![[note#heading]]"): its words in a card; a click opens it.
                var section: String?
                if let hash = raw.range(of: #"#([^\]|]+)"#, options: .regularExpression) {
                    section = String(raw[hash].dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                let card = noteCard(file, section: section)
                shown(card, size: card.size, link: NotesLibrary.title(of: file), kind: "note")
                return
            }
            // "![[a.png|300]]" (or "![alt|300](a.png)"): shown 300 points wide, as Obsidian does.
            let raw = string.substring(with: line.range)
            let wanted = raw.range(of: #"\|\s*(\d{2,4})(?:x\d+)?\s*(?=\]\]|\])"#, options: .regularExpression)
                .flatMap { Double(raw[$0].filter(\.isNumber).prefix(4)) }.map { CGFloat($0) }
            guard let size = view?.pictureSize(file, width: wanted) else {
                storage.addAttribute(.foregroundColor, value: quiet, range: line.range)
                return
            }
            let style = paragraph(after: size.height + 14)
            storage.addAttributes([.paragraphStyle: style, .noteDraw: "embed:" + file.path,
                                   .noteImage: NoteImage(image: NSImage(), size: size, inline: false, kind: "picture", source: line.range)],
                                  range: paragraphRange)
            if showMarks {
                storage.addAttributes([.foregroundColor: quiet, .font: NSFont.systemFont(ofSize: 13)], range: line.range)
            } else {
                hide(line.range, in: storage)
            }
        }

        private var cards: [String: NSImage] = [:]

        /// A note shown inside another: its name and first lines (or one heading's part) on a card.
        private func noteCard(_ url: URL, section: String?) -> NSImage {
            let width = max(240, (view?.columnWidth ?? 760) - 4)
            let key = "\(url.path)#\(section ?? "")|\(library.modifiedDate(url).timeIntervalSince1970)|\(Int(width))|\(theme.dark)"
            if let known = cards[key] { return known }
            var lines = library.readableLines(url)
            if let section, let text = library.read(url) {
                let headings = NoteMarkdown.headings(text)
                if let index = headings.firstIndex(where: { $0.title.caseInsensitiveCompare(section) == .orderedSame }) {
                    let start = NSMaxRange(headings[index].range)
                    let end = headings[(index + 1)...].first { $0.level <= headings[index].level }?.range.location ?? (text as NSString).length
                    let part = (text as NSString).substring(with: NSRange(location: start, length: max(0, end - start)))
                    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("asmo-section-\(abs(key.hashValue)).md")
                    if (try? part.write(to: scratch, atomically: true, encoding: .utf8)) != nil {
                        lines = library.readableLines(scratch)
                        try? FileManager.default.removeItem(at: scratch)
                    }
                }
            }
            var body = lines.prefix(10).joined(separator: "\n")
            if body.count > 700 { body = String(body.prefix(700)) + "…" } else if lines.count > 10 { body += "\n…" }
            let text = NSMutableAttributedString()
            let titleStyle = NSMutableParagraphStyle()
            titleStyle.paragraphSpacing = 8
            text.append(NSAttributedString(string: NotesLibrary.title(of: url) + (section.map { " › " + $0 } ?? "") + "\n",
                                           attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: ink,
                                                        .paragraphStyle: titleStyle]))
            let bodyStyle = NSMutableParagraphStyle()
            bodyStyle.lineSpacing = 4
            text.append(NSAttributedString(string: body.isEmpty ? String(localized: "（空笔记）") : body,
                                           attributes: [.font: NSFont.systemFont(ofSize: 13.5), .foregroundColor: ink.withAlphaComponent(0.72),
                                                        .paragraphStyle: bodyStyle]))
            let inner = width - 40
            let height = ceil(text.boundingRect(with: NSSize(width: inner, height: 2000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 32
            let fill = NSColor(theme.sidebar)
            let line = NSColor(theme.line)
            let bar = accent
            let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
                let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
                fill.setFill(); shape.fill()
                line.setStroke(); shape.lineWidth = 1; shape.stroke()
                bar.withAlphaComponent(0.6).setFill()
                NSRect(x: 0, y: 8, width: 3, height: rect.height - 16).fill()
                text.draw(with: NSRect(x: 22, y: 16, width: inner, height: rect.height - 28), options: [.usesLineFragmentOrigin, .usesFontLeading])
                return true
            }
            cards[key] = image
            return image
        }

        // MARK: Editing

        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard !styling, editedMask.contains(.editedCharacters) else { return }
            let edited = editedRange
            // Fences, $$ and the properties block change how every line after them reads: draw all again.
            let string = textStorage.string as NSString
            let paragraph = string.paragraphRange(for: NSRange(location: min(edited.location, string.length), length: 0))
            let text = string.substring(with: paragraph)
            let structural = text.contains("```") || text.contains("~~~") || text.contains("$$") || text.hasPrefix("---") || delta < -1
            // The line the marks were showing on (if it's another one, they hide there again).
            let previous = caretLine
            caretLine = paragraph
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if structural { self.restyle(); return }
                self.restyle(around: NSRange(location: edited.location, length: max(edited.length, 0)))
                if let previous, previous.location != paragraph.location,
                   NSMaxRange(previous) <= (self.view?.string as NSString?)?.length ?? 0 {
                    self.restyle(around: NSRange(location: previous.location, length: 0))
                }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !styling else { return }
            view?.updateSuggestions()
            scheduleSave()
            pendingOutline?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.outlineNow() }
            pendingOutline = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !styling, let view, let storage = view.textStorage else { return }
            view.updateSuggestions()
            publishStyle()
            guard view.engaged else { return }
            let string = storage.string as NSString
            let at = min(view.selectedRange().location, string.length)
            let line = string.paragraphRange(for: NSRange(location: at, length: 0))
            guard line != caretLine else { return }
            let old = caretLine
            caretLine = line
            if let old, NSMaxRange(old) <= string.length { restyle(around: old) }
            restyle(around: line)
        }

        private func outlineNow() {
            guard let view else { return }
            let headings = NoteMarkdown.headings(view.string)
            if parent.outline.headings != headings { parent.outline.headings = headings }
            trackHeading()
        }

        func go(to range: NSRange) {
            guard let view, NSMaxRange(range) <= view.string.utf16.count else { return }
            view.window?.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: range.location, length: 0))
            if let layout = view.layoutManager, let container = view.textContainer {
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                layout.ensureLayout(forGlyphRange: glyphs)
                let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                let y = max(0, rect.minY + view.textContainerOrigin.y - 20)
                view.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: y))
                view.enclosingScrollView?.reflectScrolledClipView(view.enclosingScrollView!.contentView)
            }
        }

        // Links: [[note]] opens the note (a missing one is made, as in Obsidian); addresses open in the browser.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL { NSWorkspace.shared.open(url); return true }
            return false
        }

        func openLink(_ target: String) {
            save()
            if let note = library.note(named: target, from: parent.url) { parent.open(note); return }
            let folder = parent.url.deletingLastPathComponent()
            if let made = try? library.create(in: folder, name: target) { parent.open(made) }
        }

    }
}

/// What the [[link]] suggestions show.
@MainActor
final class LinkSuggestions: ObservableObject {
    @Published var items: [(title: String, folder: String)] = []
    @Published var selected = 0
    /// Nothing matches: Return makes a link to a note of this name (made when the link is first clicked).
    @Published var creating: String?
}

struct LinkSuggestionList: View {
    @ObservedObject var model: LinkSuggestions
    let theme: PlannerTheme
    let pick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.items.isEmpty, let name = model.creating {
                Text("新笔记「\(name)」 ↩︎").font(.system(size: 13)).foregroundStyle(theme.quiet)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).padding(.horizontal, 12)
            }
            ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                Button { pick(index) } label: {
                    HStack(spacing: 8) {
                        Text(item.title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(theme.ink).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(item.folder).font(.system(size: 11)).foregroundStyle(theme.quiet).lineLimit(1)
                    }
                    .padding(.horizontal, 12).frame(height: 32)
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

/// The note's text view: draws bullets, boxes, quotes, code blocks and pictures; checks boxes off on a click; opens
/// [[links]]; turns pasted or dropped pictures into files in the picture folder.
final class NoteTextView: NSTextView {
    weak var coordinator: NoteEditorView.Coordinator?
    /// The writer has clicked or typed in this note (until then no line shows its marks: a note opens as a page).
    var engaged = false

    override func keyDown(with event: NSEvent) {
        engaged = true
        super.keyDown(with: event)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let old = selectionArea()
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if let old { setNeedsDisplay(old) }
    }
    private var pictures: [String: NSImage] = [:]

    /// The width of the column of text (set from the window; pictures are sized to it).
    var columnWidth: CGFloat = 760
    /// The note's name above the text (scrolls with it).
    var header: NSHostingView<AnyView>?
    private var pendingRestyle: DispatchWorkItem?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutColumn()
    }

    /// A column of comfortable width, centred in the window, with the name above it; pictures are sized to the
    /// column, so a new width draws them again.
    func layoutColumn() {
        let width = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        guard width > 100 else { return }
        let column = max(200, min(760, width - 96))
        let side = max(48, (width - column) / 2)
        var top: CGFloat = 28
        if let header {
            let height = max(44, header.fittingSize.height)
            let frame = NSRect(x: side, y: 34, width: column, height: height)
            if header.frame != frame { header.frame = frame }
            top = 34 + height + 22
        }
        if abs(textContainerInset.width - side) > 0.5 || abs(textContainerInset.height - top) > 0.5 {
            textContainerInset = NSSize(width: side, height: top)
        }
        if abs(columnWidth - column) > 1 {
            columnWidth = column
            pendingRestyle?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.coordinator?.restyle() }
            pendingRestyle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }

    /// Makes the selected lines a heading of `level` (0: plain text again), as the style menu does.
    func setHeading(_ level: Int) {
        let text = string as NSString
        let selection = selectedRange()
        let covered = text.paragraphRange(for: selection)
        let block = text.substring(with: covered)
        var lines = block.components(separatedBy: "\n")
        let trailing = block.hasSuffix("\n")
        if trailing { lines.removeLast() }
        let prefix = level > 0 ? String(repeating: "#", count: level) + " " : ""
        var firstDelta = 0
        let changed = lines.enumerated().map { index, line -> String in
            guard lines.count == 1 || !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            let rest = line.replacingOccurrences(of: #"^\s*(#{1,6}\s+|[-*+]\s+(\[[ xX]\]\s+)?|\d{1,3}[.)]\s+|>\s?)"#, with: "",
                                                 options: .regularExpression)
            let result = prefix + rest
            if index == 0 { firstDelta = (result as NSString).length - (line as NSString).length }
            return result
        }
        let replacement = changed.joined(separator: "\n") + (trailing ? "\n" : "")
        guard replacement != block, shouldChangeText(in: covered, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: covered, with: replacement)
        didChangeText()
        if lines.count == 1 {
            setSelectedRange(NSRange(location: max(covered.location, selection.location + firstDelta), length: selection.length))
        } else {
            setSelectedRange(NSRange(location: covered.location, length: (replacement as NSString).length - (trailing ? 1 : 0)))
        }
    }

    /// Puts text where the caret is, on lines of its own (a table, a formula block), and the caret at `caret`
    /// characters into it.
    func insertBlock(_ block: String, caret: Int) {
        let text = string as NSString
        let at = selectedRange().location
        let startsLine = at == 0 || text.character(at: at - 1) == 10
        let lead = startsLine ? "" : "\n"
        let endsLine = at >= text.length || text.character(at: at) == 10
        let insertion = lead + block + (endsLine ? "" : "\n")
        insertText(insertion, replacementRange: selectedRange())
        setSelectedRange(NSRange(location: at + (lead as NSString).length + caret, length: 0))
    }

    /// The size a picture is shown at: its own, no wider than the column, no taller than 520.
    func pictureSize(_ file: URL, width wanted: CGFloat? = nil) -> NSSize? {
        guard let image = picture(file) else { return nil }
        let width = min(wanted ?? .greatestFiniteMagnitude, max(200, columnWidth - 4))
        var size = image.size
        if size.width > width { size = NSSize(width: width, height: size.height * width / size.width) }
        if wanted == nil, size.height > 520 { size = NSSize(width: size.width * 520 / size.height, height: 520) }
        return size
    }

    func picture(_ file: URL) -> NSImage? {
        if let known = pictures[file.path] { return known }
        guard let image = NSImage(contentsOf: file), image.size.width > 0 else { return nil }
        pictures[file.path] = image
        return image
    }

    /// Where pictures that open a note were drawn (a click there opens it).
    var linkedPictures: [String: NSRect] = [:]
    /// Where pictures that stand for source (tables) were drawn, by where their source starts (a click writes it).
    var editablePictures: [Int: NSRect] = [:]
    /// Every picture drawn (pictures, diagrams, formulas, tables, drawings), by where its text starts: what a
    /// double-click opens and the menu acts on.
    var drawn: [Int: DrawnPicture] = [:]

    struct DrawnPicture {
        var rect: NSRect
        var image: NSImage
        var file: URL?
        var kind: String
        var source: NSRange?
    }

    func picture(at point: NSPoint) -> (key: Int, picture: DrawnPicture)? {
        drawn.first { $0.value.rect.contains(point) }.map { ($0.key, $0.value) }
    }

    /// A callout's colour, by its kind (as Obsidian colours them).
    static func calloutColour(_ type: String) -> NSColor {
        switch type {
        case "tip", "hint", "important", "success", "check", "done": return .systemGreen
        case "question", "help", "faq", "warning", "caution", "attention": return .systemOrange
        case "failure", "fail", "missing", "danger", "error", "bug": return .systemRed
        case "example": return .systemPurple
        case "quote", "cite": return .systemGray
        case "abstract", "summary", "tldr": return .systemTeal
        default: return .systemBlue
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return }
        let origin = textContainerOrigin
        let visible = rect.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: 0, dy: -600)
        let glyphs = layout.glyphRange(forBoundingRectWithoutAdditionalLayout: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let quiet = coordinator?.quiet ?? .secondaryLabelColor
        let accent = coordinator?.accent ?? .controlAccentColor
        let left = origin.x, width = container.size.width
        /// Each line of a run, in view coordinates.
        func fragments(_ glyphRange: NSRange, _ body: @escaping (NSRect, NSRect) -> Void) {
            layout.enumerateLineFragments(forGlyphRange: glyphRange) { line, used, _, _, _ in
                body(line.offsetBy(dx: origin.x, dy: origin.y), used.offsetBy(dx: origin.x, dy: origin.y))
            }
        }
        // A line is shaded once, however many runs of text it holds (a callout's line with a bullet in it).
        var shaded = Set<CGFloat>()
        storage.enumerateAttribute(.noteDraw, in: characters) { value, range, _ in
            guard let kind = value as? String else { return }
            let glyphRange = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return }
            let line = layout.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
            let used = layout.lineFragmentUsedRect(forGlyphAt: glyphRange.location, effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
            let glyph = layout.boundingRect(forGlyphRange: NSRange(location: glyphRange.location, length: 1), in: container)
                .offsetBy(dx: origin.x, dy: origin.y)
            switch kind {
            case "code", "front":
                // One block behind the lines.
                (kind == "code" ? quiet.withAlphaComponent(0.1) : quiet.withAlphaComponent(0.07)).setFill()
                fragments(glyphRange) { line, _ in
                    guard shaded.insert(line.minY).inserted else { return }
                    NSRect(x: left - 4, y: line.minY, width: width + 8, height: line.height).intersection(rect).fill()
                }
            case let value where value.hasPrefix("callout:"):
                let colour = Self.calloutColour(String(value.dropFirst(8)))
                fragments(glyphRange) { line, _ in
                    guard shaded.insert(line.minY).inserted else { return }
                    colour.withAlphaComponent(0.1).setFill()
                    NSRect(x: left, y: line.minY, width: width, height: line.height).intersection(rect).fill()
                    colour.withAlphaComponent(0.75).setFill()
                    NSRect(x: left, y: line.minY, width: 3, height: line.height).intersection(rect).fill()
                }
            case "quote":
                let lastGlyph = layout.glyphRange(forCharacterRange: NSRange(location: NSMaxRange(range) - 1, length: 1), actualCharacterRange: nil)
                let bottom = layout.lineFragmentUsedRect(forGlyphAt: lastGlyph.location, effectiveRange: nil).maxY + origin.y
                accent.withAlphaComponent(0.45).setFill()
                NSRect(x: left + 2, y: used.minY + 2, width: 3, height: max(10, bottom - used.minY - 4)).fill()
            case "rule":
                quiet.withAlphaComponent(0.35).setFill()
                NSRect(x: left, y: used.midY.rounded(), width: width, height: 1).fill()
            case let value where value.hasPrefix("trow:"):
                // A table row: its cells' lines, the header shaded.
                let parts = value.split(separator: ":")
                guard parts.count == 3 else { return }
                let edges = parts[2].split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) }
                let total = edges.reduce(0, +)
                let row = NSRect(x: left, y: line.minY, width: total, height: line.height)
                if parts[1] == "h" { quiet.withAlphaComponent(0.1).setFill(); row.fill() }
                quiet.withAlphaComponent(0.3).setStroke()
                let path = NSBezierPath(rect: row.insetBy(dx: 0.5, dy: 0.5))
                var x = left
                for edge in edges.dropLast() {
                    x += edge
                    path.move(to: NSPoint(x: x.rounded() + 0.5, y: row.minY))
                    path.line(to: NSPoint(x: x.rounded() + 0.5, y: row.maxY))
                }
                path.lineWidth = 1
                path.stroke()
            case let value where value.hasPrefix("bullet:"):
                let depth = Int(value.dropFirst(7)) ?? 0
                let size: CGFloat = depth == 0 ? 6 : 5
                let dot = NSRect(x: glyph.midX - size / 2, y: used.midY - size / 2 + 1, width: size, height: size)
                accent.withAlphaComponent(0.85).set()
                let path = depth % 2 == 1 ? NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5)) : NSBezierPath(ovalIn: dot)
                if depth % 2 == 1 { path.lineWidth = 1.2; path.stroke() } else { path.fill() }
            case let value where value.hasPrefix("box:"):
                let done = value == "box:done"
                let box = NSRect(x: glyph.minX + 1, y: used.midY - 7.5, width: 15, height: 15)
                let path = NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5)
                if done {
                    accent.setFill(); path.fill()
                    let tick = NSBezierPath()
                    tick.move(to: NSPoint(x: box.minX + 3.5, y: box.midY))
                    tick.line(to: NSPoint(x: box.minX + 6.5, y: box.maxY - 4))
                    tick.line(to: NSPoint(x: box.maxX - 3.5, y: box.minY + 4))
                    tick.lineWidth = 1.8
                    NSColor.white.setStroke(); tick.stroke()
                } else {
                    quiet.setStroke(); path.lineWidth = 1.3; path.stroke()
                }
            case let value where value.hasPrefix("embed:"):
                let file = URL(fileURLWithPath: String(value.dropFirst(6)))
                guard let image = picture(file) else { return }
                let size = (storage.attribute(.noteImage, at: range.location, effectiveRange: nil) as? NoteImage)?.size ?? pictureSize(file) ?? image.size
                let frame = NSRect(x: left, y: used.maxY + 6, width: size.width, height: size.height)
                drawn[range.location] = DrawnPicture(rect: frame, image: image, file: file, kind: "picture",
                                                     source: (storage.attribute(.noteImage, at: range.location, effectiveRange: nil) as? NoteImage)?.source)
                guard frame.intersects(rect) else { return }
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).addClip()
                image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
                NSGraphicsContext.restoreGraphicsState()
            default:
                break
            }
        }
        // Formulas, diagrams, drawings and notes shown in the note.
        storage.enumerateAttribute(.noteImage, in: characters) { value, range, _ in
            guard let picture = value as? NoteImage, picture.kind != "picture" else { return }
            let glyphRange = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return }
            let used = layout.lineFragmentUsedRect(forGlyphAt: glyphRange.location, effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
            var frame: NSRect
            if picture.inline {
                let glyph = layout.boundingRect(forGlyphRange: NSRange(location: glyphRange.location, length: 1), in: container)
                    .offsetBy(dx: origin.x, dy: origin.y)
                let baseline = layout.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil).minY + origin.y
                    + layout.location(forGlyphAt: glyphRange.location).y
                frame = NSRect(x: glyph.minX + 1, y: baseline - 5.5 - picture.size.height / 2, width: picture.size.width, height: picture.size.height)
            } else {
                let x = picture.centered ? left + (width - picture.size.width) / 2 : left + picture.indent
                frame = NSRect(x: x, y: used.maxY + 6, width: picture.size.width, height: picture.size.height)
            }
            if let link = picture.link { linkedPictures[link] = frame }
            if let at = picture.editAt { editablePictures[at] = frame }
            drawn[range.location] = DrawnPicture(rect: frame, image: picture.image,
                                                 file: picture.link.flatMap { coordinator?.library.note(named: $0) },
                                                 kind: picture.kind, source: picture.source)
            guard frame.intersects(rect) else { return }
            NSGraphicsContext.saveGraphicsState()
            if picture.panel {
                let card = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
                NSColor.white.setFill(); card.fill()
                card.addClip()
            }
            picture.image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                               hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // Clicks: a box checks off; a [[link]] opens (⌘-click too, like Obsidian).
    override func mouseDown(with event: NSEvent) {
        engaged = true
        let clicked = convert(event.locationInWindow, from: nil)
        // A double-click on a picture, diagram, formula or table: shown large, to zoom and copy.
        if event.clickCount == 2, let hit = picture(at: clicked), hit.picture.kind != "note" {
            PictureViewer.show(hit.picture.image, title: viewerTitle(hit.picture), file: hit.picture.kind == "picture" ? hit.picture.file : nil, over: window)
            return
        }
        if let link = linkedPictures.first(where: { $0.value.contains(clicked) })?.key {
            coordinator?.openLink(link)
            return
        }
        // A click on a table: its source, to write in (drawn again as a table once the caret leaves it).
        if let at = editablePictures.first(where: { $0.value.contains(clicked) })?.key, at <= string.utf16.count {
            window?.makeFirstResponder(self)
            setSelectedRange(NSRange(location: at, length: 0))
            return
        }
        guard let storage = textStorage, storage.length > 0, let layout = layoutManager, let container = textContainer else {
            super.mouseDown(with: event); return
        }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y
        let glyph = layout.glyphIndex(for: point, in: container)
        let index = layout.characterIndexForGlyph(at: glyph)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        if index < storage.length, rect.insetBy(dx: -4, dy: -4).contains(point) {
            if let kind = storage.attribute(.noteDraw, at: index, effectiveRange: nil) as? String, kind.hasPrefix("box:") {
                toggleBox(at: index)
                return
            }
            if let target = storage.attribute(.noteLink, at: index, effectiveRange: nil) as? String {
                coordinator?.openLink(target)
                return
            }
        }
        super.mouseDown(with: event)
    }

    private func toggleBox(at index: Int) {
        guard let storage = textStorage else { return }
        let string = storage.string as NSString
        var range = NSRange()
        _ = storage.attribute(.noteDraw, at: index, longestEffectiveRange: &range, in: string.paragraphRange(for: NSRange(location: index, length: 0)))
        // The "[ ]" / "[x]": the middle character changes.
        let mark = NSRange(location: range.location + 1, length: 1)
        guard NSMaxRange(mark) <= string.length else { return }
        let next = string.substring(with: mark) == " " ? "x" : " "
        if shouldChangeText(in: mark, replacementString: next) {
            storage.replaceCharacters(in: mark, with: next)
            didChangeText()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
    }

    // MARK: [[ link suggestions

    /// The list of notes under the caret while a [[link]] is being written (nil: not showing).
    private var suggestions: NSPanel?
    private var suggestionModel = LinkSuggestions()

    /// "[[" also writes "]]" after the caret, and the suggestions open.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        guard let typed = string as? String, typed == "[" else { return }
        let at = selectedRange().location
        let text = self.string as NSString
        if at >= 2, text.substring(with: NSRange(location: at - 2, length: 2)) == "[[",
           at >= text.length || text.substring(with: NSRange(location: at, length: 1)) != "]" {
            super.insertText("]]", replacementRange: NSRange(location: at, length: 0))
            setSelectedRange(NSRange(location: at, length: 0))
        }
    }

    /// Where the link being written starts (after "[["), when the caret is inside one on this line.
    private var linkBeingWritten: NSRange? {
        let text = string as NSString
        let at = selectedRange().location
        guard selectedRange().length == 0, at <= text.length else { return nil }
        let lineStart = text.paragraphRange(for: NSRange(location: min(at, text.length), length: 0)).location
        let before = text.substring(with: NSRange(location: lineStart, length: at - lineStart))
        guard let open = before.range(of: "[[", options: .backwards) else { return nil }
        let start = lineStart + before.utf16.distance(from: before.utf16.startIndex, to: open.upperBound.samePosition(in: before.utf16)!)
        let typed = text.substring(with: NSRange(location: start, length: at - start))
        guard !typed.contains("]"), !typed.contains("|"), !typed.contains("#") else { return nil }
        return NSRange(location: start, length: at - start)
    }

    /// Shows, updates or hides the suggestions (after every change and caret move).
    func updateSuggestions() {
        guard hasMarkedText() == false || suggestions != nil else { return }
        guard let range = linkBeingWritten, let library = coordinator?.library, window != nil else { hideSuggestions(); return }
        let typed = (string as NSString).substring(with: range)
        let found = library.named(typed).prefix(8).map { (title: NotesLibrary.title(of: $0), folder: (library.path(of: $0) as NSString).deletingLastPathComponent) }
        suggestionModel.items = Array(found)
        suggestionModel.selected = min(suggestionModel.selected, max(0, found.count - 1))
        suggestionModel.creating = found.isEmpty ? typed : nil
        guard !found.isEmpty || !typed.isEmpty else { hideSuggestions(); return }
        let panel = suggestions ?? makeSuggestions()
        var caret = firstRect(forCharacterRange: NSRange(location: selectedRange().location, length: 0), actualRange: nil)
        if caret == .zero { caret = window?.convertToScreen(convert(bounds, to: nil)) ?? .zero }
        let height = CGFloat(max(1, found.count)) * 32 + 12
        panel.setFrame(NSRect(x: caret.minX - 8, y: caret.minY - height - 6, width: 300, height: height), display: true)
        if panel.parent == nil { window?.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    private func makeSuggestions() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        panel.contentView = NSHostingView(rootView: LinkSuggestionList(model: suggestionModel, theme: PlannerTheme(dark: dark)) { [weak self] index in
            self?.suggestionModel.selected = index
            self?.acceptSuggestion()
        })
        suggestions = panel
        return panel
    }

    func hideSuggestions() {
        guard let panel = suggestions else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        suggestions = nil
        suggestionModel.selected = 0
    }

    private func acceptSuggestion() {
        guard let range = linkBeingWritten else { hideSuggestions(); return }
        let title = suggestionModel.items.indices.contains(suggestionModel.selected)
            ? suggestionModel.items[suggestionModel.selected].title : (string as NSString).substring(with: range)
        hideSuggestions()
        insertText(title, replacementRange: range)
        // Past the closing brackets.
        let at = selectedRange().location
        let text = string as NSString
        if at + 2 <= text.length, text.substring(with: NSRange(location: at, length: 2)) == "]]" {
            setSelectedRange(NSRange(location: at + 2, length: 0))
        }
    }

    override func doCommand(by selector: Selector) {
        if suggestions != nil {
            switch selector {
            case #selector(moveDown(_:)):
                suggestionModel.selected = min(suggestionModel.selected + 1, max(0, suggestionModel.items.count - 1)); return
            case #selector(moveUp(_:)):
                suggestionModel.selected = max(suggestionModel.selected - 1, 0); return
            case #selector(insertNewline(_:)), #selector(insertTab(_:)):
                acceptSuggestion(); return
            case #selector(cancelOperation(_:)):
                hideSuggestions(); return
            default: break
            }
        }
        super.doCommand(by: selector)
    }

    override func resignFirstResponder() -> Bool {
        hideSuggestions()
        return super.resignFirstResponder()
    }

    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let at = selectedRange().location
        let line = text.paragraphRange(for: NSRange(location: min(at, text.length), length: 0))
        let content = text.substring(with: line).trimmingCharacters(in: .newlines)
        if let match = content.range(of: #"^(\s*)([-*+]|\d{1,3}[.)])(\s+)(\[[ xX]\]\s+)?"#, options: .regularExpression) {
            let marker = String(content[match])
            if content.count == marker.count {
                // An empty item: the list ends here.
                if shouldChangeText(in: NSRange(location: line.location, length: (content as NSString).length), replacementString: "") {
                    textStorage?.replaceCharacters(in: NSRange(location: line.location, length: (content as NSString).length), with: "")
                    didChangeText()
                }
                return
            }
            var next = marker.replacingOccurrences(of: #"\[[xX]\]"#, with: "[ ]", options: .regularExpression)
            if let number = marker.range(of: #"\d{1,3}"#, options: .regularExpression), let value = Int(marker[number]) {
                next = marker.replacingCharacters(in: number, with: String(value + 1))
            }
            super.insertText("\n" + next, replacementRange: selectedRange())
            return
        }
        super.insertNewline(sender)
    }

    // Pictures pasted or dropped become files in the picture folder, linked as ![[name]] on their own line.
    override func paste(_ sender: Any?) {
        if insertPictures(from: .general) { return }
        pasteAsPlainText(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if (sender.draggingSource as? NSTextView) !== self {
            let point = convert(sender.draggingLocation, from: nil)
            setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
            if insertPictures(from: sender.draggingPasteboard) { return true }
        }
        return super.performDragOperation(sender)
    }

    private func insertPictures(from board: NSPasteboard) -> Bool {
        guard let library = coordinator?.library else { return false }
        var names: [String] = []
        if let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            for file in files where UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true {
                if let data = try? Data(contentsOf: file), let name = try? library.savePicture(data, ext: file.pathExtension.lowercased()) {
                    names.append(name)
                }
            }
        } else if let data = board.data(forType: .png) {
            if let name = try? library.savePicture(data, ext: "png") { names.append(name) }
        } else if let tiff = board.data(forType: .tiff), let image = NSBitmapImageRep(data: tiff),
                  let png = image.representation(using: .png, properties: [:]) {
            if let name = try? library.savePicture(png, ext: "png") { names.append(name) }
        }
        guard !names.isEmpty else { return false }
        let text = string as NSString
        let at = selectedRange().location
        let startsLine = at == 0 || text.character(at: at - 1) == 10
        let insertion = (startsLine ? "" : "\n") + names.map { "![[\($0)]]" }.joined(separator: "\n") + "\n"
        insertText(insertion, replacementRange: selectedRange())
        return true
    }

    // MARK: Formatting (the toolbar): Markdown marks around the selection, or at the start of the lines.

    func wrap(_ mark: String) {
        let range = selectedRange()
        let text = string as NSString
        let selected = text.substring(with: range)
        let length = (mark as NSString).length
        // Already wrapped: unwrap.
        if range.location >= length, NSMaxRange(range) + length <= text.length,
           text.substring(with: NSRange(location: range.location - length, length: length)) == mark,
           text.substring(with: NSRange(location: NSMaxRange(range), length: length)) == mark {
            let outer = NSRange(location: range.location - length, length: range.length + length * 2)
            if shouldChangeText(in: outer, replacementString: selected) {
                textStorage?.replaceCharacters(in: outer, with: selected)
                didChangeText()
                setSelectedRange(NSRange(location: outer.location, length: range.length))
            }
            return
        }
        let replacement = mark + selected + mark
        if shouldChangeText(in: range, replacementString: replacement) {
            textStorage?.replaceCharacters(in: range, with: replacement)
            didChangeText()
            setSelectedRange(NSRange(location: range.location + length, length: range.length))
        }
    }

    /// Puts `prefix` ("# ", "- ", "- [ ] ") at the start of each selected line, or takes it off.
    func linePrefix(_ prefix: String) {
        let text = string as NSString
        let covered = text.paragraphRange(for: selectedRange())
        let block = text.substring(with: covered)
        var lines = block.components(separatedBy: "\n")
        let trailing = block.hasSuffix("\n")
        if trailing { lines.removeLast() }
        let pattern = #"^(\s*)(#{1,6} |- \[[ xX]\] |[-*+] |\d{1,3}[.)] )?"#
        let allHave = lines.allSatisfy { $0.range(of: "^\\s*" + NSRegularExpression.escapedPattern(for: prefix), options: .regularExpression) != nil }
        let changed = lines.map { line -> String in
            guard let match = line.range(of: pattern, options: .regularExpression) else { return line }
            let indent = String(line[match].prefix { $0 == " " || $0 == "\t" })
            let rest = String(line[match.upperBound...])
            return allHave ? indent + rest : indent + prefix + rest
        }
        let replacement = changed.joined(separator: "\n") + (trailing ? "\n" : "")
        if shouldChangeText(in: covered, replacementString: replacement) {
            textStorage?.replaceCharacters(in: covered, with: replacement)
            didChangeText()
            setSelectedRange(NSRange(location: covered.location + (replacement as NSString).length - (trailing ? 1 : 0), length: 0))
        }
    }

    func insertLink() {
        let range = selectedRange()
        let selected = (string as NSString).substring(with: range)
        let copied = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let address = copied.hasPrefix("http") ? copied : "https://"
        let replacement = "[\(selected.isEmpty ? String(localized: "链接") : selected)](\(address))"
        if shouldChangeText(in: range, replacementString: replacement) {
            textStorage?.replaceCharacters(in: range, with: replacement)
            didChangeText()
        }
    }

    func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let board = NSPasteboard(name: NSPasteboard.Name("asmo-note-pictures"))
        board.clearContents()
        board.writeObjects(panel.urls as [NSURL])
        _ = insertPictures(from: board)
    }
}
#endif
