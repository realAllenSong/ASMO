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
}

/// What a note page shows besides the text: its headings (the contents in the margin).
@MainActor
final class NoteOutline: ObservableObject {
    @Published var headings: [NoteMarkdown.Heading] = []
    /// Set to a heading's range to go there.
    var go: ((NSRange) -> Void)?
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
        context.coordinator.view = view
        context.coordinator.load()
        controller?.textView = view
        outline.go = { [weak coordinator = context.coordinator] range in coordinator?.go(to: range) }
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let urlChanged = coordinator.parent.url != url
        let darkChanged = coordinator.parent.theme.dark != theme.dark
        coordinator.parent = self
        if let view = coordinator.view {
            controller?.textView = view
            // A column of comfortable width, centred.
            let side = max(40, (scroll.contentView.bounds.width - 760) / 2)
            if abs(view.textContainerInset.width - side) > 0.5 { view.textContainerInset = NSSize(width: side, height: 24) }
            // Pictures leave room for themselves at the column's width: a new width draws them again.
            let column = max(200, min(760, scroll.contentView.bounds.width - 80))
            if scroll.contentView.bounds.width > 0, abs(view.columnWidth - column) > 1 {
                view.columnWidth = column
                if !urlChanged { DispatchQueue.main.async { coordinator.restyle() } }
            }
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

        private func paragraph(before: CGFloat = 0, after: CGFloat = 6, indent: CGFloat = 0) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 5
            style.paragraphSpacing = after
            style.paragraphSpacingBefore = before
            style.headIndent = indent
            style.firstLineHeadIndent = indent
            return style
        }

        private var base: [NSAttributedString.Key: Any] {
            [.font: bodyFont, .foregroundColor: ink, .paragraphStyle: paragraph()]
        }

        /// Draws the whole note again.
        func restyle() {
            guard let storage = view?.textStorage else { return }
            styling = true
            storage.beginEditing()
            let lines = NoteMarkdown.lines(storage.string)
            for line in lines { style(line, in: storage) }
            storage.endEditing()
            styling = false
            view?.typingAttributes = base
            view?.needsDisplay = true
        }

        /// Draws again the lines a range touches (after an edit, or the caret moving on or off them).
        private func restyle(around range: NSRange) {
            guard let storage = view?.textStorage, storage.length >= 0 else { return }
            let string = storage.string as NSString
            let covered = string.paragraphRange(for: NSRange(location: min(range.location, string.length), length: min(range.length, max(0, string.length - range.location))))
            let lines = NoteMarkdown.lines(storage.string)
            styling = true
            storage.beginEditing()
            for line in lines where NSIntersectionRange(NSRange(location: line.range.location, length: max(line.range.length, 1)), covered).length > 0
                || (line.range.location >= covered.location && line.range.location <= NSMaxRange(covered)) {
                style(line, in: storage)
            }
            storage.endEditing()
            styling = false
            view?.needsDisplay = true
        }

        private func style(_ line: NoteMarkdown.Line, in storage: NSTextStorage) {
            let string = storage.string as NSString
            // The line with its break (attributes of the break set the paragraph's spacing).
            var whole = line.range
            if NSMaxRange(whole) < string.length { whole.length += 1 }
            guard NSMaxRange(whole) <= storage.length else { return }
            let showMarks = caretLine.map { NSIntersectionRange($0, whole).length > 0 || $0.location == line.range.location } ?? false
            var attributes = base
            switch line.kind {
            case .heading(let level):
                let sizes: [CGFloat] = [26, 22, 19, 17, 16, 16]
                attributes[.font] = NSFont.systemFont(ofSize: sizes[min(level, 6) - 1], weight: .bold)
                attributes[.paragraphStyle] = paragraph(before: level <= 2 ? 14 : 8, after: 6)
            case .code, .fence:
                attributes[.font] = monoFont
                attributes[.paragraphStyle] = paragraph(after: 0, indent: 12)
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
                attributes[.foregroundColor] = quiet
                attributes[.paragraphStyle] = paragraph(indent: 16)
            case .rule:
                attributes[.foregroundColor] = quiet
            default:
                break
            }
            storage.setAttributes(attributes, range: whole)
            if case .embed(let target) = line.kind {
                embed(target, line: line, showMarks: showMarks, in: storage)
                return
            }
            if let marker = line.marker { decorateMarker(line, marker: marker, showMarks: showMarks, in: storage) }
            switch line.kind {
            case .code, .fence, .frontmatter, .math, .mathFence:
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

        private func hide(_ range: NSRange, in storage: NSTextStorage) {
            guard range.length > 0 else { return }
            storage.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear], range: range)
        }

        private func decorateMarker(_ line: NoteMarkdown.Line, marker: NSRange, showMarks: Bool, in storage: NSTextStorage) {
            let string = storage.string as NSString
            switch line.kind {
            case .heading:
                if showMarks { storage.addAttribute(.foregroundColor, value: quiet, range: marker) } else { hide(marker, in: storage) }
            case .bullet(let depth, let ordered):
                let indent = CGFloat(depth) * 22
                storage.addAttribute(.paragraphStyle, value: hanging(indent: indent, marker: 22), range: string.paragraphRange(for: line.range))
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
                let indent = CGFloat(depth) * 22
                storage.addAttribute(.paragraphStyle, value: hanging(indent: indent, marker: 26), range: string.paragraphRange(for: line.range))
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

        /// Lines of a list wrap under their words, not under the bullet.
        private func hanging(indent: CGFloat, marker: CGFloat) -> NSParagraphStyle {
            let style = paragraph(after: 3)
            style.firstLineHeadIndent = indent
            style.headIndent = indent + marker
            return style
        }

        private func dashRange(in marker: NSRange, string: NSString) -> NSRange {
            let text = string.substring(with: marker)
            let offset = text.prefix { $0 == " " || $0 == "\t" }.utf16.count
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
                storage.addAttributes([.font: monoFont, .foregroundColor: accent], range: content)
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
            guard let file = library.attachment(named: target, from: parent.url), let size = view?.pictureSize(file) else {
                storage.addAttribute(.foregroundColor, value: quiet, range: line.range)
                return
            }
            let style = paragraph(after: size.height + 14)
            storage.addAttributes([.paragraphStyle: style, .noteDraw: "embed:" + file.path], range: paragraphRange)
            if showMarks {
                storage.addAttributes([.foregroundColor: quiet, .font: NSFont.systemFont(ofSize: 13)], range: line.range)
            } else {
                hide(line.range, in: storage)
            }
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
            parent.outline.headings = NoteMarkdown.headings(view.string)
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
    private var pictures: [String: NSImage] = [:]

    /// The width of the column of text (set from the window; pictures are sized to it).
    var columnWidth: CGFloat = 760

    /// The size a picture is shown at: its own, no wider than the column, no taller than 520.
    func pictureSize(_ file: URL) -> NSSize? {
        guard let image = picture(file) else { return nil }
        let width = max(200, columnWidth - 4)
        var size = image.size
        if size.width > width { size = NSSize(width: width, height: size.height * width / size.width) }
        if size.height > 520 { size = NSSize(width: size.width * 520 / size.height, height: 520) }
        return size
    }

    private func picture(_ file: URL) -> NSImage? {
        if let known = pictures[file.path] { return known }
        guard let image = NSImage(contentsOf: file), image.size.width > 0 else { return nil }
        pictures[file.path] = image
        return image
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
                // One block behind the lines (each line's own rect, run together).
                let block = NSRect(x: left - 4, y: line.minY, width: width + 8, height: line.height)
                (kind == "code" ? quiet.withAlphaComponent(0.1) : quiet.withAlphaComponent(0.07)).setFill()
                block.intersection(rect).fill()
            case "quote":
                let lastGlyph = layout.glyphRange(forCharacterRange: NSRange(location: NSMaxRange(range) - 1, length: 1), actualCharacterRange: nil)
                let bottom = layout.lineFragmentUsedRect(forGlyphAt: lastGlyph.location, effectiveRange: nil).maxY + origin.y
                accent.withAlphaComponent(0.45).setFill()
                NSRect(x: left + 2, y: used.minY + 2, width: 3, height: max(10, bottom - used.minY - 4)).fill()
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
                guard let size = pictureSize(file), let image = picture(file) else { return }
                let frame = NSRect(x: left, y: used.maxY + 6, width: size.width, height: size.height)
                guard frame.intersects(rect) else { return }
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).addClip()
                image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
                NSGraphicsContext.restoreGraphicsState()
            default:
                break
            }
        }
    }

    // Clicks: a box checks off; a [[link]] opens (⌘-click too, like Obsidian).
    override func mouseDown(with event: NSEvent) {
        engaged = true
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
