#if os(macOS)
import AppKit
#endif
import SwiftUI

// MARK: Data handed to the document

/// One line that stands for a stored item.
struct DocLine: Equatable {
    enum Kind: String {
        case task, routine, event
        /// A birthday, anniversary or holiday (every year).
        case occasion
        /// A line of the imported history (石墨), as it was written that day.
        case archive
        /// Shown for what it is, never written from the page: calendar events, important dates, the history.
        var readOnly: Bool { self == .event || self == .occasion || self == .archive }
    }
    var kind: Kind
    /// Task UUID, "routineUUID|dayKey", event id, "occasion-…" or "archive-…".
    var id: String
    var depth = 0
    var time: String?
    var title: String
    var done = false
    var style: String?
    /// Small grey label after the title ("每天").
    var tag: String?

    /// What the line should show; when stored data changes elsewhere the line is redrawn.
    var signature: String { "\(depth)|\(time ?? "")|\(title)|\(done)|\(style ?? "")|\(tag ?? "")" }
}

struct DocDay: Equatable {
    var day: PlanDate
    var heading: String
    var isToday: Bool
    var lines: [DocLine]
    /// Free paragraphs (notes) written in this day, kept as rich text.
    var notes: Data?
    var showsHeading = true
}

/// What the document asks the app to do. All writes go through here so the store stays the single truth.
struct DocActions {
    /// A finished line of writing. Returns the lines to show in its place (for this day); items that landed on
    /// other days are reported through `movedElsewhere`. Nil means "keep it as a note".
    /// `page` is the day the line was written under: "明天" counts from it, even when the line goes to another day.
    var commit: (_ text: String, _ day: PlanDate, _ page: PlanDate, _ parent: UUID?, _ done: Bool) -> [DocLine]?
    var update: (_ line: DocLine, _ text: String, _ day: PlanDate, _ parent: UUID?) -> Void
    var toggle: (_ line: DocLine, _ day: PlanDate) -> Void
    /// An item deleted from the page came back (⌘Z): put it back in the store. False if it can't be.
    var restore: (_ id: String) -> Bool = { _ in false }
    /// An item's title formatting changed on the page ("b i u s #rrggbb", nil for plain).
    var restyle: (_ id: String, _ style: String?) -> Void = { _, _ in }
    /// An item's line was struck through (done) or un-struck (not done) on the page.
    var strike: (_ line: DocLine, _ day: PlanDate, _ struck: Bool) -> Void = { _, _, _ in }
    /// The repeat tag ("# 每天") on a routine's line was clicked: change how it repeats.
    var editTag: (_ id: String) -> Void = { _ in }
    var delete: (_ line: DocLine, _ day: PlanDate) -> Void
    var saveNotes: (_ day: PlanDate, _ data: Data?, _ pending: [String]) -> Void
    /// The day a line of writing talks about ("明天交材料" → tomorrow), by the date rules; the page's day otherwise.
    /// `page`: the page's day (what 明天 is relative to); `fallback`: the day when the text names none.
    var dayOf: (_ text: String, _ page: PlanDate, _ fallback: PlanDate) -> PlanDate = { $2 }
    /// Items from this page landed on another day.
    var moved: (_ count: Int, _ day: PlanDate) -> Void = { _, _ in }
    /// Judges finished lines of the page of `day` (the on-device model, or rules when it isn't ready).
    var classify: (_ lines: [String], _ day: PlanDate) async -> [LineJudgement]
    /// An existing item the writing talks about again ("头发也剪了", "会改到四点"): `ref` from the organize context.
    /// Returns false when the match was too weak to change that item: the piece is then filed as a new item.
    var revise: (_ ref: String, _ piece: String, _ done: Bool, _ page: PlanDate) -> Bool = { _, _, _, _ in false }
    /// One organize pass starts (true) / ends (false) on the page of `day`; everything between is undone together.
    var batch: (_ day: PlanDate, _ begin: Bool) -> Void = { _, _ in }
    /// Undoes the last organize pass (⌘Z on the page right after organizing).
    var undoOrganize: () -> Void = {}
    /// Organizing started/finished (for the toolbar spinner).
    var organizing: (Bool) -> Void = { _ in }
    /// Results that came back after the page closed: file them without the page.
    var fileLater: (_ lines: [String], _ judgements: [LineJudgement], _ day: PlanDate) -> Void = { _, _, _ in }
    /// ⌘[ / ⌘] from inside the page: previous / next day.
    var navigate: (Int) -> Void = { _ in }
    /// The cursor went into this day's page (the toolbar and the microphone follow it).
    var focused: (PlanDate) -> Void = { _ in }
}

/// What a finished line of free writing is.
struct LineJudgement {
    var isNote: Bool
    /// The things to do in it (usually one), each keeping its own date/time words.
    var pieces: [String]
    /// Belongs under the line above.
    var sub: Bool
    /// For each piece: already done.
    var done: [Bool] = []
    /// For each piece: belongs under the item before it (a step, a condition, "记得…").
    var pieceSub: [Bool] = []
    /// For each piece: the clause it came from (its date words still there when the model dropped them).
    var sources: [String] = []
    /// Parts of a long line that were thoughts, kept as a note after its items.
    var noteText: String? = nil
    /// For each piece: the existing item it is (a context ref like "task:UUID"), nil for a new item.
    var targets: [String?] = []
    /// The line was read together with the lines before it and is fully taken care of: remove it.
    var drop = false
}

/// An item's title with its formatting, piece by piece: "b i u s #RRGGBB hl code" and a link per piece.
/// A title in one style and no link is stored the old way ("b i"); anything richer as "runs:" + base64 JSON,
/// a single token that older readers of the style skip.
struct TitleRun: Codable, Equatable {
    var t: String
    var s = ""
    var l: String?
}

enum RichTitle {
    static let prefix = "runs:"

    static func encode(_ runs: [TitleRun]) -> String? {
        guard let first = runs.first else { return nil }
        let simple = runs.allSatisfy { $0.s == first.s && $0.l == nil }
            && !first.s.split(separator: " ").contains(where: { $0 == "hl" || $0 == "code" })
        if simple { return first.s.isEmpty ? nil : first.s }
        guard let data = try? JSONEncoder().encode(runs) else { return nil }
        return prefix + data.base64EncodedString()
    }

    static func decode(_ style: String?) -> [TitleRun]? {
        guard let style, style.hasPrefix(prefix), let data = Data(base64Encoded: String(style.dropFirst(prefix.count))) else { return nil }
        return try? JSONDecoder().decode([TitleRun].self, from: data)
    }

    /// The pieces that make up `title` inside the line they were read from (the line may also hold a bullet or a
    /// time that isn't part of the title). Nil when the title isn't there as written.
    static func slice(_ runs: [TitleRun], to title: String) -> [TitleRun]? {
        let whole = runs.map(\.t).joined() as NSString
        let found = whole.range(of: title)
        guard found.location != NSNotFound, found.length > 0 else { return nil }
        var result: [TitleRun] = []
        var offset = 0
        for run in runs {
            let length = (run.t as NSString).length
            let overlap = NSIntersectionRange(NSRange(location: offset, length: length), found)
            if overlap.length > 0 {
                var piece = run
                piece.t = (run.t as NSString).substring(with: NSRange(location: overlap.location - offset, length: overlap.length))
                result.append(piece)
            }
            offset += length
        }
        return result
    }
}

// MARK: Attributes

extension NSAttributedString.Key {
    static let asmoDay = NSAttributedString.Key("asmo.day")
    static let asmoLine = NSAttributedString.Key("asmo.line")
    static let asmoKind = NSAttributedString.Key("asmo.kind")
    static let asmoCheck = NSAttributedString.Key("asmo.check")
    static let asmoTag = NSAttributedString.Key("asmo.tag")
    static let asmoNote = NSAttributedString.Key("asmo.note")
    /// The time drawn before an item's title (it belongs to the item, not to the title's formatting).
    static let asmoTime = NSAttributedString.Key("asmo.time")
}

// MARK: View

/// The whole planner as one document: each day a heading, items as checklist lines, notes as text.
/// Writing is plain typing; finished lines become items without asking.
enum NoteRule {
    static func stripMarker(_ text: String) -> String {
        for marker in ["• ", "◦ ", "▪ ", "‣ ", "☐ ", "☑ ", "- ", "* "] where text.hasPrefix(marker) {
            return String(text.dropFirst(marker.count).drop { $0 == " " })
        }
        // A numbered list ("1.", "2)", "i.", "iv.", "a)"): the number is the list's, not the item's.
        if let range = text.range(of: #"^(?:\d{1,2}|[ivx]{1,4}|[a-h])[.)、]\s+"#, options: [.regularExpression, .caseInsensitive]) {
            return String(text[range.upperBound...])
        }
        return text
    }

    /// Notes stay text: headings, "> " quotes, labels ending in a colon, a bare link. (Long passages are split
    /// and judged clause by clause, not set aside.)
    static func looksLikeNote(_ text: String, heading: Bool) -> Bool {
        if heading { return true }
        let value = text.trimmed
        if value.hasPrefix(">") || value.hasPrefix("//") || value.hasPrefix("#") || value.hasPrefix("「") { return true }
        if value.hasSuffix(":") || value.hasSuffix("：") { return true }
        if value.hasPrefix("http"), !value.contains(" ") { return true }
        return false
    }
}

#if os(macOS)
struct DayDocumentView: NSViewRepresentable {
    let days: [DocDay]
    let anchor: PlanDate
    let theme: PlannerTheme
    let actions: DocActions
    /// Formatting toolbar hookup.
    var controller: PageController?
    /// Organizes everything now (⌘↵, the toolbar button, leaving the page); calls back when done.
    var organizeRequest: Int = 0
    /// Bumped when stored data was put back wholesale (undoing an organize pass): the page is drawn again.
    var rebuildRequest: Int = 0
    /// Takes the cursor when it first appears (one page of the writing view, not all of them).
    var autofocus = true
    /// The page's least height (an empty day in the writing view is just a line).
    var minHeight: CGFloat = 80
    /// Organize finished lines after a pause in typing. Off: only when the cursor leaves the day, the page loses
    /// focus or ⌘↵ (nothing changes under the writer while they are still thinking).
    var organizeWhenIdle = true
    /// Typed lines become items word for word (no model, no rewording).
    var verbatim = true

    func makeCoordinator() -> DocCoordinator { DocCoordinator(self) }

    /// Leaving the page by any route (another view, ⌘1/⌘2, closing): what was written is organized, the same as
    /// when it loses the cursor. Results land in their days even though the page is gone.
    static func dismantleNSView(_ view: DocTextView, coordinator: DocCoordinator) {
        coordinator.organize(includingCurrent: true)
    }

    /// The page lives inside the 逐日 card: no scroll view of its own, it grows with what's written.
    func makeNSView(context: Context) -> DocTextView {
        let view = DocTextView(frame: .zero)
        // Every change to the text (typing, drawing, organizing) counts, so a measured height is never stale.
        let coordinator = context.coordinator
        NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: view.textStorage,
                                               queue: nil) { [weak coordinator] _ in coordinator?.edits &+= 1 }
        view.isRichText = true
        view.importsGraphics = true
        view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticLinkDetectionEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 0
        view.textContainerInset = NSSize(width: 4, height: 6)
        view.insertionPointColor = NSColor(theme.accent)
        view.linkTextAttributes = [.foregroundColor: NSColor(theme.accent), .underlineStyle: NSUnderlineStyle.single.rawValue,
                                   .cursor: NSCursor.pointingHand]
        view.delegate = context.coordinator
        view.textStorage?.delegate = context.coordinator
        view.coordinator = context.coordinator
        context.coordinator.view = view
        context.coordinator.rebuildRequest = rebuildRequest
        context.coordinator.builtDark = theme.dark
        context.coordinator.autofocused = autofocus
        if autofocus || controller?.textView == nil { controller?.textView = view }
        context.coordinator.build(days, anchor: anchor)
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: DocTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 600
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        // Measuring lays out the whole page (years of history): only again when the text or the width changed.
        let coordinator = context.coordinator
        if let last = coordinator.measured, last.width == width, last.edits == coordinator.edits, last.min == minHeight {
            return CGSize(width: width, height: last.height)
        }
        container.containerSize = NSSize(width: max(60, width - view.textContainerInset.width * 2), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        let height = max(minHeight, ceil(used + view.textContainerInset.height * 2 + 8))
        coordinator.measured = (width, coordinator.edits, minHeight, height)
        return CGSize(width: width, height: height)
    }

    func updateNSView(_ view: DocTextView, context: Context) {
        context.coordinator.parent = self
        // Asked to take the cursor while already on screen (a day chosen in the rail or the calendar).
        if autofocus && !context.coordinator.autofocused {
            controller?.textView = view
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
                context.coordinator.scroll(to: anchor)
            }
        }
        context.coordinator.autofocused = autofocus
        if context.coordinator.organizeRequest != organizeRequest {
            context.coordinator.organizeRequest = organizeRequest
            DispatchQueue.main.async { context.coordinator.organize(includingCurrent: true) }
        }
        // The look changed (light ↔ dark): the text was drawn in the old ink, so draw it again.
        if context.coordinator.builtDark != theme.dark {
            context.coordinator.builtDark = theme.dark
            context.coordinator.syncEdits()
            context.coordinator.build(days, anchor: context.coordinator.anchor ?? anchor)
            return
        }
        if context.coordinator.rebuildRequest != rebuildRequest {
            context.coordinator.rebuildRequest = rebuildRequest
            context.coordinator.build(days, anchor: anchor)
            return
        }
        // Midnight passed: 今天 / 明天 move on, and the writer stays where they are.
        if let today = days.first(where: \.isToday)?.day, let built = context.coordinator.builtToday, built != today {
            context.coordinator.rebuildInPlace(days)
            return
        }
        // Days came or went (the history finished loading, an item landed on a day not on the paper yet):
        // draw again, keeping the reader's place.
        if days.map(\.day) != context.coordinator.builtDays {
            context.coordinator.rebuildInPlace(days)
            return
        }
        context.coordinator.reconcile(days)
    }
}

final class DocTextView: NSTextView {
    weak var coordinator: DocCoordinator?
    /// The page's own undo history (the window's shared one outlived the page and crashed on ⌘Z).
    private let pageUndo = UndoManager()
    override var undoManager: UndoManager? { pageUndo }

    // ⌘Z / ⇧⌘Z reach this view before the window (whose own history this page doesn't use).
    @objc func undo(_ sender: Any?) {
        if pageUndo.canUndo { pageUndo.undo() } else { NSSound.beep() }
    }

    @objc func redo(_ sender: Any?) {
        if pageUndo.canRedo { pageUndo.redo() } else { NSSound.beep() }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return pageUndo.canUndo }
        if item.action == #selector(redo(_:)) { return pageUndo.canRedo }
        return super.validateUserInterfaceItem(item)
    }

    override var intrinsicContentSize: NSSize {
        guard let container = textContainer, let layout = layoutManager else { return super.intrinsicContentSize }
        layout.ensureLayout(for: container)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(layout.usedRect(for: container).height + textContainerInset.height * 2 + 8))
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            // Physical [ and ] keys (33, 30), so it works with a Chinese input method too (where "[" types "【").
            if event.keyCode == 33 { coordinator?.parent.actions.navigate(-1); return true }
            if event.keyCode == 30 { coordinator?.parent.actions.navigate(1); return true }
            // ⌘K: link the selection (the physical K key, whatever the input method).
            if event.keyCode == 40 { coordinator?.parent.controller?.link(); return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    // Pasting and dropping: links become cards, pictures and videos are shown, Markdown is drawn (DocPaste).
    override func paste(_ sender: Any?) {
        if let body = coordinator?.writingAttributes, DocPaste.insert(from: .general, into: self, body: body) { return }
        super.paste(sender)
    }

    /// ⌥⇧⌘V: the words alone, in the page's style.
    override func pasteAsPlainText(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), let body = coordinator?.writingAttributes else {
            super.pasteAsPlainText(sender); return
        }
        insertText(NSAttributedString(string: text, attributes: body), replacementRange: selectedRange())
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        // Text dragged within the page moves as usual; things from elsewhere land where they're dropped.
        if (sender.draggingSource as? NSTextView) !== self, let body = coordinator?.writingAttributes {
            let point = convert(sender.draggingLocation, from: nil)
            let index = characterIndexForInsertion(at: point)
            let saved = selectedRange()
            setSelectedRange(NSRange(location: index, length: 0))
            if DocPaste.insert(from: sender.draggingPasteboard, into: self, body: body) {
                window?.makeFirstResponder(self)
                return true
            }
            setSelectedRange(saved)
        }
        return super.performDragOperation(sender)
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { coordinator?.organize(includingCurrent: true) }
        return ok
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let coordinator {
            coordinator.parent.controller?.textView = self
            coordinator.parent.actions.focused(coordinator.parent.anchor)
        }
        return ok
    }

    // MARK: The bar next to a selection

    private var selectionBar: NSHostingView<SelectionBar>?
    private var selectionBarWork: DispatchWorkItem?

    /// Shows the format bar by the selected words (once the mouse is up and the selection has settled), or hides it.
    func refreshSelectionBar(after delay: TimeInterval = 0.12) {
        selectionBarWork?.cancel()
        guard selectedRange().length > 0 else { hideSelectionBar(); return }
        let work = DispatchWorkItem { [weak self] in self?.placeSelectionBar() }
        selectionBarWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func hideSelectionBar() {
        selectionBarWork?.cancel()
        guard let bar = selectionBar, !bar.isHidden else { return }
        bar.isHidden = true
    }

    private func placeSelectionBar() {
        let selection = selectedRange()
        guard selection.length > 0, NSEvent.pressedMouseButtons & 1 == 0, window?.firstResponder === self,
              let coordinator, let controller = coordinator.parent.controller,
              let layout = layoutManager, let container = textContainer, let storage = textStorage else { hideSelectionBar(); return }
        // Only words: a selection of nothing but line breaks or pictures has nothing to format.
        let text = (storage.string as NSString).substring(with: selection)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { hideSelectionBar(); return }
        let bar: NSHostingView<SelectionBar>
        if let existing = selectionBar {
            bar = existing
            bar.rootView = SelectionBar(controller: controller, theme: coordinator.parent.theme)
        } else {
            bar = NSHostingView(rootView: SelectionBar(controller: controller, theme: coordinator.parent.theme))
            addSubview(bar)
            selectionBar = bar
        }
        let size = bar.fittingSize
        let glyphs = layout.glyphRange(forCharacterRange: selection, actualCharacterRange: nil)
        let origin = textContainerOrigin
        // The first and last lines of the selection.
        let first = layout.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let last = layout.lineFragmentUsedRect(forGlyphAt: max(glyphs.location, NSMaxRange(glyphs) - 1), effectiveRange: nil)
        let startX = layout.boundingRect(forGlyphRange: NSRange(location: glyphs.location, length: 1), in: container).minX
        let whole = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let middle = first.minY == last.minY ? whole.midX : (startX + first.maxX) / 2
        var x = origin.x + middle - size.width / 2
        x = max(0, min(x, bounds.width - size.width))
        // Above the selection; below it when the top of the window is in the way.
        var y = origin.y + first.minY - size.height + 6
        if y < visibleRect.minY { y = origin.y + last.maxY - 6 }
        bar.frame = NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
        if bar.isHidden || bar.alphaValue < 1 {
            bar.isHidden = false
            bar.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                bar.animator().alphaValue = 1
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        hideSelectionBar()
        defer { refreshSelectionBar(after: 0.05) }
        // Clicking a checkbox toggles the item instead of placing the cursor.
        let point = convert(event.locationInWindow, from: nil)
        if let index = characterIndex(at: point), let storage = textStorage, index < storage.length,
           storage.attribute(.asmoTag, at: index, effectiveRange: nil) != nil,
           let id = storage.attribute(.asmoLine, at: max(0, (storage.string as NSString).paragraphRange(for: NSRange(location: index, length: 0)).location), effectiveRange: nil) as? String
            ?? storage.attribute(.asmoLine, at: max(0, index - 1), effectiveRange: nil) as? String {
            coordinator?.parent.actions.editTag(id)
            return
        }
        // A link card or video poster: a single click opens it (a double click still selects it).
        if event.clickCount == 1, let index = characterIndex(at: point), let storage = textStorage, index < storage.length,
           storage.attribute(.attachment, at: index, effectiveRange: nil) != nil,
           let link = storage.attribute(.link, at: index, effectiveRange: nil) {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            if let url { NSWorkspace.shared.open(url); return }
        }
        if let index = characterIndex(at: point), let storage = textStorage, index < storage.length,
           storage.attribute(.asmoCheck, at: index, effectiveRange: nil) != nil,
           storage.attribute(.attachment, at: index, effectiveRange: nil) != nil {
            coordinator?.toggleCheck(at: index)
            return
        }
        super.mouseDown(with: event)
    }

    private func characterIndex(at point: NSPoint) -> Int? {
        guard let layout = layoutManager, let container = textContainer else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.insetBy(dx: -3, dy: -3).contains(local) else { return nil }
        return layout.characterIndexForGlyph(at: glyph)
    }
}

// MARK: Coordinator

/// One font object per face and size for the characters the page's font can't draw (Chinese, symbols).
/// Left to itself the text system makes a new substitute font for every such run of text, each with its own
/// 350 KB width table: a page of Chinese then holds hundreds of copies of the same font (100+ MB).
enum SharedFonts {
    nonisolated(unsafe) private static var known: [String: NSFont] = [:]
    nonisolated(unsafe) private static var shared = Set<ObjectIdentifier>()

    private static func unique(_ font: NSFont) -> NSFont {
        let key = font.fontName + "|" + String(Double(font.pointSize))
        if let existing = known[key] { return existing }
        known[key] = font
        shared.insert(ObjectIdentifier(font))
        return font
    }

    /// Gives every run of characters its font from the shared set, so the text system has nothing to substitute.
    static func apply(to text: NSMutableAttributedString, in range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= text.length else { return }
        let string = text.string as NSString
        var changes: [(NSRange, NSFont)] = []
        text.enumerateAttribute(.font, in: range) { value, run, _ in
            guard let font = value as? NSFont else { return }
            if shared.contains(ObjectIdentifier(font)) { return }
            var characters = [unichar](repeating: 0, count: run.length)
            string.getCharacters(&characters, range: run)
            var glyphs = [CGGlyph](repeating: 0, count: run.length)
            if CTFontGetGlyphsForCharacters(font, characters, &glyphs, run.length) { return }
            // Runs of characters this font has no glyph for (line breaks and tabs draw nothing: skipped).
            var start: Int?
            func close(_ end: Int) {
                guard let from = start else { return }
                start = nil
                let piece = NSRange(location: run.location + from, length: end - from)
                let substitute = CTFontCreateForString(font, string.substring(with: piece) as CFString, CFRange(location: 0, length: piece.length)) as NSFont
                changes.append((piece, unique(substitute)))
            }
            for index in 0..<run.length {
                let missing = glyphs[index] == 0 && characters[index] > 32 && characters[index] != 0x200B && characters[index] != 0xFFFC
                if missing { if start == nil { start = index } } else { close(index) }
            }
            close(run.length)
        }
        for (piece, font) in changes { text.addAttribute(.font, value: font, range: piece) }
    }
}

final class DocCoordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    /// Typed and pasted text gets the shared fonts before the text system substitutes its own.
    func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        SharedFonts.apply(to: textStorage, in: editedRange)
    }

    var parent: DayDocumentView
    weak var view: DocTextView?
    var anchor: PlanDate?
    /// The page was last told to take the cursor (so it takes it once per request).
    var autofocused = false
    /// Last drawn signature for each line id, to notice changes made elsewhere.
    private var drawn: [String: String] = [:]
    private var kinds: [String: DocLine.Kind] = [:]
    private var lineDays: [String: PlanDate] = [:]
    private var applying = false
    /// An edit moved off a heading or read-only line is being made: let it through.
    private var redirecting = false
    /// Text typed on a heading, waiting to be put on the day's line.
    private var redirectBuffer: String?
    /// The page is being saved to the store.
    private var syncing = false
    /// The days drawn, in order: when the list changes the page is drawn again.
    var builtDays: [PlanDate] = []
    /// Changes to the text so far, and the height last measured for it.
    var edits = 0
    var measured: (width: CGFloat, edits: Int, min: CGFloat, height: CGFloat)?
    /// What the page was last brought up to date with.
    private var reconciled: [DocDay] = []
    /// Days that had a saved page when drawn (emptying one must still be saved).
    private var daysWithNotes = Set<PlanDate>()
    /// Heading keys already read back into days.
    private var dayKeys: [String: PlanDate?] = [:]
    /// Item ids the stored data has shown at least once. A line is only removed for a missing item when the
    /// item was confirmed before — a line just written may be ahead of the data refresh.
    private var confirmed = Set<String>()
    var organizeRequest = 0
    var rebuildRequest = 0
    /// The look the text was last drawn for.
    var builtDark: Bool?
    /// The day drawn as 今天 (midnight passing redraws the labels).
    var builtToday: PlanDate?
    /// The day the cursor is in (to notice it leaving one).
    private var cursorDay: PlanDate?
    var keyMonitor: Any?
    private var idleOrganize: DispatchWorkItem?
    private var organizingNow = false
    private var pendingSync: DispatchWorkItem?
    /// Items whose lines were deleted on this page (kept out of redraws until the store drops them).
    private var removedHere: [String: Date] = [:]
    /// What each item line last pushed to the store (unchanged lines are skipped).
    private var synced: [String: String] = [:]
    /// The page's free writing as last saved, per day (unchanged writing isn't re-encoded on every pause).
    private var savedNotes: [PlanDate: (text: NSAttributedString?, pending: [String])] = [:]

    private var agentWrites: NSObjectProtocol?

    init(_ parent: DayDocumentView) {
        self.parent = parent
        super.init()
        // An agent is about to write on a page shown here: save what is being typed first, so its change lands on
        // top of the latest text (the app then redraws the page).
        agentWrites = NotificationCenter.default.addObserver(forName: .asmoPageWillChange, object: nil, queue: nil) { [weak self] note in
            guard let self, let key = note.object as? String, self.parent.days.contains(where: { $0.day.key == key }) else { return }
            self.pendingSync?.cancel()
            self.syncEdits()
        }
        for name in [NSApplication.willResignActiveNotification, NSApplication.willTerminateNotification] {
            leaving.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.saveNow()
            })
        }
    }

    private var leaving: [NSObjectProtocol] = []

    deinit {
        if let agentWrites { NotificationCenter.default.removeObserver(agentWrites) }
        for observer in leaving { NotificationCenter.default.removeObserver(observer) }
    }

    /// True right after an organize pass: ⌘Z on the page undoes it (until the page is rebuilt).
    var organizeUndoArmed = false

    /// The app changed the text (organizing, redrawing items): the typed history no longer matches the text, so
    /// it is dropped; the last organize pass stays undoable as one step.
    func resetUndo() {
        guard let undo = view?.undoManager else { return }
        undo.removeAllActions()
        guard organizeUndoArmed else { return }
        undo.registerUndo(withTarget: self) { coordinator in
            coordinator.organizeUndoArmed = false
            coordinator.parent.actions.undoOrganize()
        }
        undo.setActionName(String(localized: "整理"))
    }

    private var theme: PlannerTheme { parent.theme }
    private var bodyFont: NSFont { .systemFont(ofSize: 15) }
    private var ink: NSColor { NSColor(theme.ink) }
    private var quiet: NSColor { NSColor(theme.quiet) }
    private var accent: NSColor { NSColor(theme.accent) }

    /// What plain writing looks like (for pasting).
    var writingAttributes: [NSAttributedString.Key: Any] { bodyAttributes }

    private var bodyAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 4
        paragraph.defaultTabInterval = 26
        paragraph.tabStops = []
        return [.font: bodyFont, .foregroundColor: ink, .paragraphStyle: paragraph]
    }

    // MARK: Building

    /// Draws the days again without moving the reader: the cursor keeps its distance from the end (what changes,
    /// like the "今天" label at midnight, is above it) and the scroll position stays.
    func rebuildInPlace(_ days: [DocDay]) {
        guard let view, let storage = view.textStorage else { return }
        // Asked while the page is being saved (the store answered right away): draw once the save is done.
        if syncing {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let latest = self.parent.days
                if latest.map(\.day) != self.builtDays { self.rebuildInPlace(latest) }
            }
            return
        }
        syncEdits()
        let cursor = view.selectedRange().location
        let fromEnd = storage.length - cursor
        // The line the cursor is in (its text and day) and how far into it: found again after drawing.
        let before = paragraphs()
        let here = before.first { $0.range.location <= cursor && cursor <= $0.range.location + ($0.text as NSString).length }
        // What's at the top of the window, and how far below the top: found again after drawing, so days added
        // above (the history) don't move what the reader is looking at.
        let clip = view.enclosingScrollView?.contentView
        var topLine: (paragraph: Paragraph, offset: CGFloat)?
        if let clip, let layout = view.layoutManager, let container = view.textContainer {
            let point = NSPoint(x: 1, y: clip.bounds.minY - view.textContainerInset.height + 1)
            let index = layout.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
            if let found = before.last(where: { $0.range.location <= index }) {
                let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: found.range.location, length: 0), actualCharacterRange: nil)
                let y = layout.lineFragmentRect(forGlyphAt: min(glyphs.location, max(0, layout.numberOfGlyphs - 1)), effectiveRange: nil).minY
                topLine = (found, clip.bounds.minY - (y + view.textContainerInset.height))
            }
        }
        let hadFocus = view.window?.firstResponder === view
        build(days, anchor: anchor ?? days.first?.day ?? PlanDate.from(.now, calendar: .current), scrolls: false)
        let after = paragraphs()
        var location = max(0, min(storage.length, storage.length - fromEnd))
        if let here, let again = after.first(where: { $0.text == here.text && $0.day == here.day && $0.isHeading == here.isHeading }) {
            location = min(storage.length, again.range.location + cursor - here.range.location)
        }
        applying = true
        view.setSelectedRange(NSRange(location: location, length: 0))
        applying = false
        if let clip, let topLine, let layout = view.layoutManager, let container = view.textContainer,
           let again = after.first(where: { $0.text == topLine.paragraph.text && $0.day == topLine.paragraph.day && $0.isHeading == topLine.paragraph.isHeading }) {
            layout.ensureLayout(for: container)
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: again.range.location, length: 0), actualCharacterRange: nil)
            let y = layout.lineFragmentRect(forGlyphAt: min(glyphs.location, max(0, layout.numberOfGlyphs - 1)), effectiveRange: nil).minY
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, y + view.textContainerInset.height + topLine.offset)))
            view.enclosingScrollView?.reflectScrolledClipView(clip)
        }
        if hadFocus { view.window?.makeFirstResponder(view) }
    }

    func build(_ days: [DocDay], anchor: PlanDate, scrolls: Bool = true) {
        #if DEBUG
        let started = Date.now
        defer { PerfLog.note("editorBuild", since: started) }
        #endif
        guard let view, let storage = view.textStorage else { return }
        applying = true
        defer { applying = false }
        let text = NSMutableAttributedString()
        drawn = [:]
        builtDays = days.map(\.day)
        daysWithNotes = Set(days.filter { $0.notes != nil }.map(\.day))
        reconciled = days
        for day in days {
            confirmed.formUnion(day.lines.map(\.id))
            text.append(heading(day))
            for line in day.lines { text.append(render(line, day: day.day)) }
            if let notes = day.notes, let saved = try? NSAttributedString(
                data: notes, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil) {
                let note = NSMutableAttributedString(attributedString: saved)
                Self.neutralizeInk(note, ink: ink, quiet: quiet)
                let dark = theme.dark
                MainActor.assumeIsolated { DocPaste.redrawCards(in: note, dark: dark) }
                note.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: note.length)) { value, range, _ in
                    if value == nil { note.addAttribute(.foregroundColor, value: ink, range: range) }
                }
                if !note.string.hasSuffix("\n") { note.append(NSAttributedString(string: "\n", attributes: bodyAttributes)) }
                note.addAttribute(.asmoNote, value: true, range: NSRange(location: 0, length: note.length))
                text.append(note)
            }
            // One empty line under each day to start writing.
            text.append(NSAttributedString(string: "\n", attributes: bodyAttributes))
        }
        storage.setAttributedString(text)
        view.typingAttributes = bodyAttributes
        organizeUndoArmed = false
        resetUndo()
        markSynced()
        let focus = parent.autofocus
        #if DEBUG
        if let opened = PerfLog.opened {
            PerfLog.opened = nil
            DispatchQueue.main.async { PerfLog.note("open→drawn", since: opened) }
        }
        #endif
        builtToday = days.first(where: \.isToday)?.day
        guard scrolls else { view.invalidateIntrinsicContentSize(); return }
        // Once more when the window has laid the document out (the first try can come before it has its size).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.scroll(to: anchor) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.scroll(to: anchor)
            // Opening the card means starting to write: the cursor is ready on the empty line.
            if focus { view.window?.makeFirstResponder(view) }
            view.invalidateIntrinsicContentSize()
        }
    }

    private func heading(_ day: DocDay) -> NSAttributedString {
        if !day.showsHeading {
            // The 逐日 card already shows the date: keep the day marker as an invisible, near-zero-height line.
            let paragraph = NSMutableParagraphStyle()
            paragraph.maximumLineHeight = 1
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 1), .foregroundColor: NSColor.clear,
                                                             .paragraphStyle: paragraph]
            let text = NSMutableAttributedString(string: "\u{200B}", attributes: attributes.merging([.asmoDay: day.day.key]) { $1 })
            text.append(NSAttributedString(string: "\n", attributes: attributes))
            return text
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = 22
        paragraph.paragraphSpacing = 6
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: day.isToday ? 22 : 16, weight: .semibold),
            .foregroundColor: day.isToday ? accent : ink,
            .paragraphStyle: paragraph,
        ]
        let text = NSMutableAttributedString(string: day.heading, attributes: attributes.merging([.asmoDay: day.day.key]) { $1 })
        // The line break carries no markers, so text typed on the next line never inherits them.
        text.append(NSAttributedString(string: "\n", attributes: attributes))
        return text
    }

    private func checkbox(done: Bool, id: String) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let symbol = NSImage(systemSymbolName: done ? "checkmark.square.fill" : "square", accessibilityDescription: done ? String(localized: "已完成") : String(localized: "未完成"))
        let colors: [NSColor] = done ? [.white, accent] : [quiet]
        let configured = symbol?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular)
            .applying(.init(paletteColors: colors)))
        attachment.image = configured
        attachment.bounds = CGRect(x: 0, y: -3, width: 17, height: 17)
        let text = NSMutableAttributedString(attachment: attachment)
        text.addAttribute(.asmoCheck, value: id, range: NSRange(location: 0, length: text.length))
        text.addAttribute(.cursor, value: NSCursor.pointingHand, range: NSRange(location: 0, length: text.length))
        return text
    }

    func render(_ line: DocLine, day: PlanDate) -> NSAttributedString {
        var base = bodyAttributes
        let result = NSMutableAttributedString(string: String(repeating: "\t", count: line.depth), attributes: base)
        switch line.kind {
        case .event:
            result.append(NSAttributedString(string: "◆ ", attributes: base.merging([.foregroundColor: accent]) { $1 }))
            base[.foregroundColor] = quiet
        case .occasion:
            result.append(NSAttributedString(string: "✦ ", attributes: base.merging([.foregroundColor: accent]) { $1 }))
            base[.foregroundColor] = accent
        case .archive:
            // The history reads like what was written that day: plain text, a little quieter than today's.
            base[.foregroundColor] = quiet
        case .task, .routine:
            // While writing, items are plain bullets (sub-bullets by depth), like any list in a doc; they become
            // checkboxes once the day is frozen. The bullet is marked so it's never read as part of the title.
            let glyph = ["•", "◦", "▪", "‣"][min(line.depth, 3)]
            result.append(NSAttributedString(string: glyph, attributes: base.merging([
                .foregroundColor: line.done ? quiet : accent.withAlphaComponent(0.85), .asmoCheck: line.id,
            ]) { $1 }))
            result.append(NSAttributedString(string: "  ", attributes: base))
        }
        if line.done {
            base[.foregroundColor] = quiet
            base[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let time = line.time {
            result.append(NSAttributedString(string: time + " ", attributes: base.merging([
                .foregroundColor: line.done ? quiet : accent,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold), .asmoTime: true,
            ]) { $1 }))
        }
        if let runs = RichTitle.decode(line.style), let pieces = RichTitle.slice(runs, to: line.title),
           pieces.map(\.t).joined() == line.title {
            // A title with formatting inside it: each piece in its own style, links included.
            for piece in pieces {
                var attributes = base
                apply(piece.s, to: &attributes)
                if line.done {
                    attributes[.foregroundColor] = quiet
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                if let link = piece.l, let url = URL(string: link) { attributes[.link] = url }
                result.append(NSAttributedString(string: piece.t, attributes: attributes))
            }
        } else {
            var titleAttributes = base
            if !line.done, let style = line.style, !style.hasPrefix(RichTitle.prefix) { apply(style, to: &titleAttributes) }
            result.append(NSAttributedString(string: line.title, attributes: titleAttributes))
        }
        if let tag = line.tag {
            result.append(NSAttributedString(string: "  # " + tag, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: accent.withAlphaComponent(0.85), .asmoTag: true,
            ]))
        }
        let content = NSRange(location: 0, length: result.length)
        result.addAttribute(.asmoLine, value: line.id, range: content)
        result.addAttribute(.asmoKind, value: line.kind.rawValue, range: content)
        result.append(NSAttributedString(string: "\n", attributes: bodyAttributes))
        // One paragraph style for the whole line: a line starting with the checkbox image would otherwise get none,
        // and indented lines (starting with a tab) would be spaced differently.
        result.addAttribute(.paragraphStyle, value: bodyAttributes[.paragraphStyle] as Any,
                            range: NSRange(location: 0, length: result.length))
        drawn[line.id] = line.signature
        kinds[line.id] = line.kind
        lineDays[line.id] = day
        return result
    }

    private func apply(_ style: String, to attributes: inout [NSAttributedString.Key: Any]) {
        for part in style.split(separator: " ") {
            switch part {
            case "b": attributes[.font] = NSFont.systemFont(ofSize: 15, weight: .semibold)
            case "i":
                attributes[.font] = NSFontManager.shared.convert((attributes[.font] as? NSFont) ?? bodyFont, toHaveTrait: .italicFontMask)
                attributes[.obliqueness] = 0.18   // Chinese fonts have no italic face: slant them
            case "u": attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            case "s": attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case "hl": attributes[.backgroundColor] = PageMarkdown.highlightBackground
            case "code":
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
                attributes[.backgroundColor] = PageMarkdown.codeBackground
            default:
                if part.hasPrefix("#"), part.count == 7, let value = Int(part.dropFirst(), radix: 16) {
                    attributes[.foregroundColor] = NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                                                           green: CGFloat((value >> 8) & 0xFF) / 255,
                                                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
                }
            }
        }
    }

    // MARK: Reading the document

    struct Paragraph {
        var range: NSRange
        var day: PlanDate?
        var isHeading: Bool
        var id: String?
        var kind: DocLine.Kind?
        var depth: Int
        var text: String
        var isNote: Bool
    }

    /// The page read back line by line. Reading the whole page costs real time and happens on every pause and
    /// cursor move, so the result is kept until the text changes.
    private var paragraphCache: (edits: Int, list: [Paragraph])?

    func paragraphs() -> [Paragraph] {
        if let cached = paragraphCache, cached.edits == edits { return cached.list }
        let list = readParagraphs()
        paragraphCache = (edits, list)
        return list
    }

    private func readParagraphs() -> [Paragraph] {
        guard let storage = view?.textStorage else { return [] }
        let string = storage.string as NSString
        var result: [Paragraph] = []
        var location = 0
        var currentDay: PlanDate?
        var seen = Set<String>()
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            let start = range.location
            if let key = storage.attribute(.asmoDay, at: start, effectiveRange: nil) as? String {
                if let known = dayKeys[key] { currentDay = known } else {
                    currentDay = JournalDays.date(forKey: key)
                    dayKeys[key] = currentDay
                }
                result.append(Paragraph(range: range, day: currentDay, isHeading: true, id: nil, kind: nil, depth: 0,
                                        text: "", isNote: false))
                continue
            }
            // The line's identity is any item marker inside it (not the line break); a second line claiming the
            // same item is just text.
            var id: String?
            var kind: DocLine.Kind?
            let content = NSRange(location: range.location, length: max(0, range.length - (string.substring(with: range).hasSuffix("\n") ? 1 : 0)))
            storage.enumerateAttribute(.asmoLine, in: content) { value, sub, stop in
                if let value = value as? String {
                    id = value
                    kind = (storage.attribute(.asmoKind, at: sub.location, effectiveRange: nil) as? String).flatMap(DocLine.Kind.init)
                    stop.pointee = true
                }
            }
            if let found = id, !seen.insert(found).inserted { id = nil; kind = nil }
            let raw = string.substring(with: range)
            let depth = raw.prefix { $0 == "\t" }.count
            // Text without tabs, checkbox, tag and trailing newline.
            var visible = ""
            storage.enumerateAttributes(in: range) { attributes, sub, _ in
                if attributes[.asmoTag] != nil || attributes[.asmoCheck] != nil || attributes[.attachment] != nil { return }
                visible += string.substring(with: sub)
            }
            visible = visible.trimmingCharacters(in: .whitespacesAndNewlines)
            if kind == .event, visible.hasPrefix("◆") { visible = String(visible.dropFirst()).trimmed }
            if kind == .occasion, visible.hasPrefix("✦") { visible = String(visible.dropFirst()).trimmed }
            let note = storage.attribute(.asmoNote, at: start, effectiveRange: nil) != nil
            result.append(Paragraph(range: range, day: currentDay, isHeading: false, id: id, kind: kind, depth: depth,
                                    text: visible, isNote: note))
        }
        return result
    }

    private func parentID(for index: Int, in list: [Paragraph]) -> UUID? {
        let depth = list[index].depth
        guard depth > 0 else { return nil }
        var cursor = index - 1
        while cursor >= 0, !list[cursor].isHeading {
            let candidate = list[cursor]
            if candidate.kind == .task, candidate.depth < depth, let id = candidate.id { return UUID(uuidString: id) }
            cursor -= 1
        }
        return nil
    }

    // MARK: Editing → store

    func textDidChange(_ notification: Notification) {
        guard !applying else { return }
        if view?.selectedRange().length == 0 { view?.hideSelectionBar() }
        // (Markdown as you type is handled before the change, in markdownShortcut, so it can be undone.)
        // Struck words go quiet right away, however they were struck (toolbar, ⌘ key, ~~ ~~).
        if let view, let storage = view.textStorage, storage.length > 0 {
            let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: min(view.selectedRange().location, storage.length - 1), length: 0))
            Self.strikeQuietly(storage, in: paragraph, quiet: quiet, ink: ink)
        }
        scheduleSync()
        // A pause in writing is when the finished lines get organized (never the line being written).
        idleOrganize?.cancel()
        guard parent.organizeWhenIdle else { return }
        let idle = DispatchWorkItem { [weak self] in self?.organize(includingCurrent: false) }
        idleOrganize = idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: idle)
    }

    /// Nothing is saved or organized while the writer is writing: the page is saved once the keys have been
    /// quiet for a while (and never in the middle of an input-method composition). Leaving the day, the page or
    /// the app saves at once.
    private func scheduleSync() {
        pendingSync?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.view?.hasMarkedText() == true { self.scheduleSync(); return }
            self.syncEdits()
        }
        pendingSync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    /// Saves now if something is waiting (the app is going to the background or quitting).
    func saveNow() {
        guard let pending = pendingSync, !pending.isCancelled else { return }
        pending.cancel()
        syncEdits()
    }

    /// Pushes edited item lines to the store, deletes items whose lines are gone, and saves notes.
    func syncEdits() {
        guard let view, !applying else { return }
        // This save is running: it is no longer pending (a redraw it causes must not wait on it).
        pendingSync = nil
        #if DEBUG
        let started = Date.now
        defer { PerfLog.note("syncEdits", since: started) }
        #endif
        let list = paragraphs()
        let version = edits
        syncing = true
        defer { syncing = false }
        var present = Set<String>()
        let cursor = view.selectedRange().location
        for (index, paragraph) in list.enumerated() where !paragraph.isHeading {
            guard let id = paragraph.id, let kind = paragraph.kind, let day = paragraph.day else { continue }
            present.insert(id)
            // A line deleted here is back (undo): its item comes back with it.
            if removedHere[id] != nil {
                removedHere[id] = nil
                if parent.actions.restore(id) { kinds[id] = kind; lineDays[id] = day }
            }
            guard !kind.readOnly else { continue }
            if paragraph.text.isEmpty {
                // An emptied item line that the cursor has left: the item is gone.
                if !NSLocationInRange(cursor, paragraph.range) || cursor == NSMaxRange(paragraph.range) {
                    continue
                }
                continue
            }
            // Only lines that changed since the last save are pushed (re-reading every line on each pause was slow).
            let format = titleFormat(in: paragraph.range)
            let parentLine = parentID(for: index, in: list)
            let signature = "\(paragraph.text)|\(paragraph.depth)|\(parentLine?.uuidString ?? "")|\(format.style ?? "")|\(format.struck)|\(day.key)"
            if synced[id] == signature { continue }
            synced[id] = signature
            let line = DocLine(kind: kind, id: id, depth: paragraph.depth, title: paragraph.text)
            parent.actions.update(line, paragraph.text, day, parentLine)
            if kind == .task { parent.actions.restyle(id, format.style) }
            // Striking the whole of an item through is how a doc says "done" (there are no checkboxes while writing).
            parent.actions.strike(line, day, format.struck)
        }
        // The store's answers above can redraw the page (an item just made appears on its day): what counts as
        // "its line is gone" is the page as it is now, never the list read before. (Reading the old list here
        // once deleted an item the moment it was drawn.)
        if edits != version { present = Set(paragraphs().compactMap(\.id)) }
        for (id, kind) in kinds where !present.contains(id) && !kind.readOnly && confirmed.contains(id) {
            if let day = lineDays[id] {
                parent.actions.delete(DocLine(kind: kind, id: id, title: ""), day)
                removedHere[id] = .now
            }
            kinds[id] = nil
            drawn[id] = nil
            lineDays[id] = nil
        }
        // The store's answers can redraw the page meanwhile: then read it again.
        saveNotes(edits == version ? list : paragraphs())
    }

    /// The page's own inks (both looks): never saved as a line's color.
    static func isThemeColor(_ color: NSColor, includingAccent: Bool = true) -> Bool {
        let palette = [false, true].flatMap { dark -> [Color] in
            let theme = PlannerTheme(dark: dark)
            return includingAccent ? [theme.ink, theme.quiet, theme.accent] : [theme.ink, theme.quiet]
        }
        guard let color = color.usingColorSpace(.sRGB) else { return false }
        return palette.contains { NSColor($0).usingColorSpace(.sRGB).map {
            abs($0.redComponent - color.redComponent) + abs($0.greenComponent - color.greenComponent) + abs($0.blueComponent - color.blueComponent) < 0.08
        } ?? false }
    }

    /// Notes keep only colors someone chose: the text ink of either look is left out when saving and drawn in the
    /// current look's ink when loading (so a note written in light mode stays readable in dark, and back).
    static func neutralizeInk(_ text: NSMutableAttributedString, ink: NSColor?, quiet: NSColor? = nil) {
        let whole = NSRange(location: 0, length: text.length)
        // Saving as RTFD stamps a black line color on struck and underlined text: invisible on the dark look.
        // The line takes the text's color instead.
        text.removeAttribute(.strikethroughColor, range: whole)
        text.removeAttribute(.underlineColor, range: whole)
        text.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            guard let color = value as? NSColor, isThemeColor(color, includingAccent: false) else { return }
            if let ink { text.addAttribute(.foregroundColor, value: ink, range: range) }
            else { text.removeAttribute(.foregroundColor, range: range) }
        }
        // Struck words are drawn quiet, like a finished item: on Chinese the line alone runs along the strokes
        // (二 struck reads as 三) and disappears.
        if let quiet { strikeQuietly(text, in: whole, quiet: quiet) }
    }

    /// Struck words in the quiet ink; with `ink`, words no longer struck get their ink back (items keep their own look).
    static func strikeQuietly(_ text: NSMutableAttributedString, in range: NSRange, quiet: NSColor, ink: NSColor? = nil) {
        text.enumerateAttributes(in: range) { attributes, sub, _ in
            let struck = (attributes[.strikethroughStyle] as? Int ?? 0) != 0
            let color = attributes[.foregroundColor] as? NSColor
            if let color, !isThemeColor(color, includingAccent: false) { return }
            if struck {
                if color != quiet { text.addAttribute(.foregroundColor, value: quiet, range: sub) }
            } else if let ink, color == quiet, attributes[.asmoLine] == nil, attributes[.asmoTag] == nil, attributes[.asmoDay] == nil {
                text.addAttribute(.foregroundColor, value: ink, range: sub)
            }
        }
    }

    /// The formatting of an item line's title, read from its last written character (the time before it is
    /// drawn in its own style, so it's skipped).
    /// The formatting of one stretch of text, as style words (and its link).
    private func styleWords(_ attributes: [NSAttributedString.Key: Any]) -> (style: String, link: String?) {
        var parts: [String] = []
        if let font = attributes[.font] as? NSFont {
            let traits = NSFontManager.shared.traits(of: font)
            if font.isFixedPitch || font.fontName.lowercased().contains("mono") { parts.append("code") }
            else if traits.contains(.boldFontMask) || NSFontManager.shared.weight(of: font) >= 8 { parts.append("b") }
            if traits.contains(.italicFontMask) || ((attributes[.obliqueness] as? CGFloat) ?? 0) > 0.05 { parts.append("i") }
        }
        if attributes[.underlineStyle] != nil, attributes[.link] == nil { parts.append("u") }
        if attributes[.strikethroughStyle] != nil { parts.append("s") }
        // A color is the writer's only when it isn't one the page draws with, in either look.
        if let color = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB), !DocCoordinator.isThemeColor(color), attributes[.link] == nil {
            parts.append(String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255)))
        }
        if let background = attributes[.backgroundColor] as? NSColor, !parts.contains("code"), PageMarkdown.isHighlight(background) { parts.append("hl") }
        let link = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String
        return (parts.joined(separator: " "), link)
    }

    /// A line's words with their formatting, piece by piece (without its bullet, time and tag; trimmed).
    private func titleRuns(in range: NSRange) -> [TitleRun] {
        guard let storage = view?.textStorage, NSMaxRange(range) <= storage.length else { return [] }
        let string = storage.string as NSString
        var runs: [TitleRun] = []
        storage.enumerateAttributes(in: range) { attributes, sub, _ in
            if attributes[.asmoTag] != nil || attributes[.asmoCheck] != nil || attributes[.asmoTime] != nil || attributes[.attachment] != nil { return }
            let text = string.substring(with: sub).replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\t", with: "")
            guard !text.isEmpty else { return }
            let words = styleWords(attributes)
            if var last = runs.last, last.s == words.style, last.l == words.link {
                last.t += text
                runs[runs.count - 1] = last
            } else {
                runs.append(TitleRun(t: text, s: words.style, l: words.link))
            }
        }
        // Spaces at the ends aren't part of the title.
        while let first = runs.first, first.t.trimmingCharacters(in: .whitespaces).isEmpty { runs.removeFirst() }
        while let last = runs.last, last.t.trimmingCharacters(in: .whitespaces).isEmpty { runs.removeLast() }
        if !runs.isEmpty {
            runs[0].t = String(runs[0].t.drop { $0 == " " })
            while runs[runs.count - 1].t.hasSuffix(" ") { runs[runs.count - 1].t.removeLast() }
        }
        return runs
    }

    /// How a line's title is formatted, as stored, and whether the whole of it is struck through (= done).
    private func titleFormat(in range: NSRange) -> (style: String?, struck: Bool) {
        var runs = titleRuns(in: range)
        let struck = !runs.isEmpty && runs.allSatisfy { $0.s.split(separator: " ").contains("s") }
        if struck {
            // Done is the item's state, not a formatting of its words.
            runs = runs.map { run in
                var run = run
                run.s = run.s.split(separator: " ").filter { $0 != "s" }.joined(separator: " ")
                return run
            }
        }
        return (RichTitle.encode(runs), struck)
    }

    /// The lines as drawn match the store: remember them, so the next save only pushes what's edited after.
    private func markSynced() {
        let list = paragraphs()
        for (index, paragraph) in list.enumerated() where !paragraph.isHeading {
            guard let id = paragraph.id, let day = paragraph.day else { continue }
            let format = titleFormat(in: paragraph.range)
            synced[id] = "\(paragraph.text)|\(paragraph.depth)|\(parentID(for: index, in: list)?.uuidString ?? "")|\(format.style ?? "")|\(format.struck)|\(day.key)"
        }
    }

    private func saveNotes(_ list: [Paragraph]) {
        guard let storage = view?.textStorage else { return }
        var byDay: [PlanDate: NSMutableAttributedString] = [:]
        for paragraph in list where !paragraph.isHeading && paragraph.id == nil && paragraph.day != nil {
            guard NSMaxRange(paragraph.range) <= storage.length else { return }
            guard !paragraph.text.isEmpty || containsAttachment(paragraph.range) else { continue }
            let piece = storage.attributedSubstring(from: paragraph.range)
            // NSMutableAttributedString is a class: store the instance, don't mutate a temporary default.
            let text = byDay[paragraph.day!] ?? NSMutableAttributedString()
            text.append(piece)
            byDay[paragraph.day!] = text
        }
        // Each day's unorganized lines, gathered in one pass (years of history are thousands of days).
        var pendingByDay: [PlanDate: [String]] = [:]
        for paragraph in list where !paragraph.isHeading && paragraph.id == nil && !paragraph.isNote && !paragraph.text.isEmpty {
            if let day = paragraph.day { pendingByDay[day, default: []].append(Self.stripMarker(paragraph.text)) }
        }
        for day in Set(list.compactMap(\.day)) {
            let text = byDay[day]
            let pendingNow = pendingByDay[day] ?? []
            // Unchanged since the last save: nothing to encode or write. A day never written in stays unwritten.
            if savedNotes[day] == nil, text == nil, pendingNow.isEmpty, !daysWithNotes.contains(day) { savedNotes[day] = (nil, []); continue }
            if let last = savedNotes[day], last.pending == pendingNow,
               (last.text == nil && text == nil) || (text.map { last.text?.isEqual(to: $0) ?? false } ?? false) { continue }
            savedNotes[day] = (text?.copy() as? NSAttributedString, pendingNow)
            let data = text.flatMap { original -> Data? in
                let neutral = NSMutableAttributedString(attributedString: original)
                Self.neutralizeInk(neutral, ink: nil)
                return try? neutral.data(from: NSRange(location: 0, length: neutral.length),
                             documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            }
            let pending = pendingNow
            parent.actions.saveNotes(day, data, pending)
        }
    }

    private func containsAttachment(_ range: NSRange) -> Bool {
        var found = false
        view?.textStorage?.enumerateAttribute(.attachment, in: range) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    /// Organizes the finished lines of free writing: the model (or rules) decides which are things to do and which
    /// are notes; things to do become item lines in place (or move to their day), notes stay as written.
    func organize(includingCurrent: Bool) {
        guard let view, !applying, !organizingNow else { return }
        pendingSync?.cancel()
        idleOrganize?.cancel()
        syncEdits()
        let cursor = view.selectedRange().location
        let candidates = paragraphs().filter { paragraph in
            guard !paragraph.isHeading, paragraph.id == nil, !paragraph.isNote, paragraph.day != nil,
                  !paragraph.text.isEmpty else { return false }
            if !includingCurrent, self.isCurrent(paragraph, cursor: cursor) { return false }
            return true
        }
        guard !candidates.isEmpty else { return }
        // Headings, quotes, images: notes without asking.
        var asking: [Paragraph] = []
        for paragraph in candidates {
            if DocCoordinator.looksLikeNote(paragraph.text, heading: isHeadingStyled(paragraph.range)) || containsAttachment(paragraph.range) {
                mark(paragraph.range, note: true)
            } else {
                asking.append(paragraph)
            }
        }
        guard !asking.isEmpty else { syncEdits(); return }
        if parent.verbatim {
            // What was typed stays as typed: each finished line is one item in the writer's words. No model, no
            // rewording, no splitting, nothing moved under something else.
            guard let storage = view.textStorage else { return }
            let batchDay = asking.first?.day ?? parent.anchor
            parent.actions.batch(batchDay, true)
            // Saving an item refreshes the view; that refresh waits until every line is in place, or it would
            // draw an item whose line is still being replaced a second time.
            applying = true
            for original in asking.reversed() {
                let current = paragraphs()
                guard let position = current.firstIndex(where: {
                    $0.id == nil && !$0.isHeading && $0.range.location == original.range.location && $0.text == original.text
                }), let day = current[position].day else { continue }
                var paragraph = current[position]
                paragraph.text = Dictation.verbatimMarker + Self.stripMarker(paragraph.text)
                commitLine(paragraph, day: day, parent: parentID(for: position, in: current), storage: storage)
            }
            applying = false
            parent.actions.batch(batchDay, false)
            syncEdits()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reconciled = []
                self.reconcile(self.parent.days)
            }
            return
        }
        organizingNow = true
        parent.actions.organizing(true)
        // Indentation goes along (a tab per level): an indented line is a sub-point of the one above.
        let texts = asking.map { String(repeating: "\t", count: $0.depth) + RoutineParser.tagFirst(Self.stripMarker($0.text)) }
        Task { @MainActor in
            let judgements = await self.parent.actions.classify(texts, asking.first?.day ?? self.parent.anchor)
            // The page is gone (closed while the model was working): the lines are filed straight to their days.
            // A box the writing list scrolled away is still alive off-window and is organized in place, or
            // it would keep its old text and bring it back when scrolled to.
            if self.view == nil {
                let day = asking.first?.day ?? self.parent.anchor
                self.organizingNow = false
                self.parent.actions.organizing(false)
                self.parent.actions.fileLater(texts, judgements, day)
                return
            }
            self.apply(judgements, to: asking)
            self.organizingNow = false
            self.parent.actions.organizing(false)
            self.syncEdits()
        }
    }

    /// The line the cursor is on (a line's range includes its break, so the start of the next line isn't it).
    private func isCurrent(_ paragraph: Paragraph, cursor: Int) -> Bool {
        guard let storage = view?.textStorage else { return false }
        let end = NSMaxRange(paragraph.range)
        let endsWithBreak = end > 0 && end <= storage.length && (storage.string as NSString).character(at: end - 1) == 10
        return cursor >= paragraph.range.location && (cursor < end || (cursor == end && !endsWithBreak))
    }

    static func stripMarker(_ text: String) -> String { NoteRule.stripMarker(text) }

    /// Applies judgements bottom-up, re-finding each line by its text in case writing moved it.
    private func apply(_ judgements: [LineJudgement], to lines: [Paragraph]) {
        guard let storage = view?.textStorage else { return }
        // Saving items refreshes the view; hold that refresh off until every line is replaced, or it would
        // insert the new items itself and shift the ranges being edited.
        applying = true
        let batchDay = lines.first?.day ?? parent.anchor
        parent.actions.batch(batchDay, true)
        defer {
            applying = false
            parent.actions.batch(batchDay, false)
            organizeUndoArmed = true
            resetUndo()
            DispatchQueue.main.async { self.reconcile(self.parent.days) }
        }
        for (index, original) in lines.enumerated().reversed() {
            guard index < judgements.count else { continue }
            let judgement = judgements[index]
            let current = paragraphs()
            guard let position = current.firstIndex(where: {
                $0.id == nil && !$0.isHeading && $0.text == original.text && $0.day == original.day
            }), let day = current[position].day else { continue }
            let paragraph = current[position]
            if judgement.drop {
                storage.deleteCharacters(in: paragraph.range)
                continue
            }
            if judgement.isNote {
                mark(paragraph.range, note: true)
                continue
            }
            var parentTask = parentID(for: position, in: current)
            if judgement.sub, parentTask == nil {
                // "记得带上…" right under an item belongs to it.
                parentTask = current[..<position].last(where: { $0.kind == .task && !$0.isHeading }).flatMap { $0.id.flatMap(UUID.init) }
            }
            // Each piece's day: its own date words, else the day of the piece before it (a passage keeps talking
            // about "明天" until it names another day), starting from the page's day.
            var running = day
            var lines: [DocLine] = []
            var lastTop: UUID?
            for (pieceIndex, piece) in (judgement.pieces.isEmpty ? [Self.stripMarker(paragraph.text)] : judgement.pieces).enumerated() {
                // The piece's own date words, else its clause's ("明天记得买咖啡豆" → "买咖啡豆" is still tomorrow).
                let source = judgement.sources.indices.contains(pieceIndex) ? judgement.sources[pieceIndex] : piece
                // An organizer item names its own date; without one it is the page's day (not the item before's).
                let whole = piece.hasPrefix(Dictation.wholeMarker)
                let pieceDay = whole ? parent.actions.dayOf(piece, day, day) : parent.actions.dayOf(piece + "|" + source, day, running)
                running = pieceDay
                // "记得带上…", "顺便…", or a step the model saw as part of the item before.
                let marked = judgement.pieceSub.indices.contains(pieceIndex) && judgement.pieceSub[pieceIndex]
                let follows = pieceIndex > 0 && (marked || piece.range(of: #"^(记得|带上|带好|顺便|别忘了?|别忘记|看完|没定|定了)"#, options: .regularExpression) != nil)
                let done = judgement.done.indices.contains(pieceIndex) ? judgement.done[pieceIndex] : false
                if judgement.targets.indices.contains(pieceIndex), let target = judgement.targets[pieceIndex],
                   parent.actions.revise(target, piece, done, day) {
                    // Already an item (said again, done now, or moved): updated, nothing new to draw.
                    continue
                }
                var made = parent.actions.commit(piece, pieceDay, day, follows ? lastTop : parentTask, done) ?? []
                if !follows, let first = made.first(where: { $0.kind == .task }) { lastTop = UUID(uuidString: first.id) }
                if pieceDay != day {
                    if !made.isEmpty { parent.actions.moved(made.count, pieceDay) }
                    made = []
                }
                if follows { made = made.map { var line = $0; line.depth = 1; return line } }
                lines += made
            }
            let depth = paragraph.depth + (judgement.sub && paragraph.depth == 0 && parentTask != nil ? 1 : 0)
            let replacement = NSMutableAttributedString()
            for var line in lines {
                line.depth = depth + line.depth
                replacement.append(render(line, day: day))
            }
            if let note = judgement.noteText, !note.isEmpty {
                // The thoughts in a long line stay on the page, under its items.
                let text = NSMutableAttributedString(string: note + "\n", attributes: bodyAttributes)
                text.addAttribute(.asmoNote, value: true, range: NSRange(location: 0, length: text.length))
                replacement.append(text)
            }
            let hadBreak = (storage.string as NSString).substring(with: paragraph.range).hasSuffix("\n")
            if lines.isEmpty && replacement.length == 0 {
                // Everything went to other days.
                let blank = NSRange(location: paragraph.range.location, length: paragraph.range.length)
                storage.replaceCharacters(in: blank, with: NSAttributedString(string: "", attributes: bodyAttributes))
            } else {
                if !hadBreak, replacement.string.hasSuffix("\n") {
                    replacement.deleteCharacters(in: NSRange(location: replacement.length - 1, length: 1))
                }
                storage.replaceCharacters(in: paragraph.range, with: replacement)
            }
        }
    }

    /// Turns finished plain lines into items (or marks them as notes).
    func commitPending(except editing: NSRange? = nil) {
        guard let view, let storage = view.textStorage, !applying else { return }
        pendingSync?.cancel()
        syncEdits()
        var list = paragraphs()
        // Walk backwards so earlier ranges stay valid while lines are replaced.
        for index in list.indices.reversed() {
            let paragraph = list[index]
            guard !paragraph.isHeading, paragraph.id == nil, !paragraph.isNote, let day = paragraph.day,
                  !paragraph.text.isEmpty else { continue }
            if let editing, NSIntersectionRange(editing, paragraph.range).length > 0 || editing.location == paragraph.range.location { continue }
            commitLine(paragraph, day: day, parent: parentID(for: index, in: list), storage: storage)
            list = paragraphs()
        }
    }

    enum Committed { case note, replaced(NSRange), cleared(Int) }

    @discardableResult
    private func commitLine(_ paragraph: Paragraph, day: PlanDate, parent parentTask: UUID?, storage: NSTextStorage) -> Committed {
        let plain = paragraph.text.replacingOccurrences(of: Dictation.verbatimMarker, with: "")
        if DocCoordinator.looksLikeNote(plain, heading: isHeadingStyled(paragraph.range)) || containsAttachment(paragraph.range) {
            mark(paragraph.range, note: true)
            return .note
        }
        // A line struck through as it was written is a thing already done.
        let format = titleFormat(in: paragraph.range)
        let struck = format.struck
        guard var lines = parent.actions.commit(paragraph.text, day, day, parentTask, struck) else {
            mark(paragraph.range, note: true)
            return .note
        }
        let was = applying
        applying = true
        defer { applying = was }
        if lines.isEmpty {
            // Everything went to other days (or it was a command): leave an empty line where the writing was.
            let hasBreak = (storage.string as NSString).substring(with: paragraph.range).hasSuffix("\n")
            let blank = NSRange(location: paragraph.range.location, length: paragraph.range.length - (hasBreak ? 1 : 0))
            storage.replaceCharacters(in: blank, with: NSAttributedString(string: "", attributes: bodyAttributes))
            return .cleared(paragraph.range.location)
        }
        // The line keeps the formatting it was written with (bold words, links): the item is drawn with it now and
        // the next save stores it.
        if lines.count == 1, lines[0].kind == .task { lines[0].style = format.style }
        let replacement = NSMutableAttributedString()
        for line in lines {
            var line = line
            line.depth = paragraph.depth
            replacement.append(render(line, day: day))
            if line.style != nil { synced[line.id] = nil; drawn[line.id] = nil }
        }
        let hadBreak = (storage.string as NSString).substring(with: paragraph.range).hasSuffix("\n")
        if !hadBreak, replacement.string.hasSuffix("\n") {
            replacement.deleteCharacters(in: NSRange(location: replacement.length - 1, length: 1))
        }
        storage.replaceCharacters(in: paragraph.range, with: replacement)
        if lines.contains(where: { $0.style != nil }) { scheduleSync() }
        resetUndo()
        return .replaced(NSRange(location: paragraph.range.location, length: replacement.length))
    }

    private func isHeadingStyled(_ range: NSRange) -> Bool {
        guard let storage = view?.textStorage, range.length > 0 else { return false }
        let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        return (font?.pointSize ?? 15) > 16.5
    }

    private func mark(_ range: NSRange, note: Bool) {
        guard let storage = view?.textStorage else { return }
        let was = applying
        applying = true
        storage.addAttribute(.asmoNote, value: note, range: range)
        applying = was
    }

    static func looksLikeNote(_ text: String, heading: Bool) -> Bool { NoteRule.looksLikeNote(text, heading: heading) }

    // MARK: Keys

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let storage = textView.textStorage else { return false }
        let string = storage.string as NSString
        let cursor = textView.selectedRange().location
        let paragraph = string.paragraphRange(for: NSRange(location: min(cursor, max(0, string.length - 1)), length: 0))
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                organize(includingCurrent: true)
                return true
            }
            // Lists continue, like in any doc: Return after a bullet (an item or one just typed) starts the next
            // bullet at the same level; Return on an empty bullet steps out a level, then out of the list.
            let raw = string.substring(with: paragraph).trimmingCharacters(in: .newlines)
            let indent = String(raw.prefix { $0 == "\t" })
            let body = String(raw.dropFirst(indent.count))
            let isItem = string.length > 0 && storage.attribute(.asmoLine, at: min(paragraph.location, string.length - 1), effectiveRange: nil) != nil
            let selection = textView.selectedRange()
            // At the very start of a line: push the line down, nothing else.
            if selection.length == 0, cursor == paragraph.location, !raw.isEmpty {
                textView.insertText(NSAttributedString(string: "\n", attributes: bodyAttributes), replacementRange: selection)
                textView.setSelectedRange(NSRange(location: cursor, length: 0))
                return true
            }
            var marker: NSAttributedString?
            if isItem {
                marker = bullet(depth: indent.count)
            } else if let glyph = body.first, Self.bulletGlyphs.contains(String(glyph)) || glyph == "☐" || glyph == "☑" {
                if String(body.dropFirst()).trimmed.isEmpty {
                    // An empty bullet: one level out, or out of the list.
                    let range = NSRange(location: paragraph.location, length: raw.utf16.count)
                    if indent.isEmpty {
                        textView.insertText(NSAttributedString(string: "", attributes: bodyAttributes), replacementRange: range)
                    } else {
                        let out = NSMutableAttributedString(string: String(indent.dropLast()), attributes: bodyAttributes)
                        out.append(glyph == "☐" || glyph == "☑" ? NSAttributedString(string: "☐ ", attributes: bodyAttributes) : bullet(depth: indent.count - 1))
                        textView.insertText(out, replacementRange: range)
                    }
                    textView.typingAttributes = bodyAttributes
                    return true
                }
                marker = glyph == "☐" || glyph == "☑" ? NSAttributedString(string: "☐ ", attributes: bodyAttributes) : bullet(depth: indent.count)
            }
            let line = NSMutableAttributedString(string: "\n" + indent, attributes: bodyAttributes)
            if let marker { line.append(marker) }
            textView.insertText(line, replacementRange: selection)
            textView.typingAttributes = bodyAttributes
            return true
        case #selector(NSResponder.insertTab(_:)):
            shiftLevel(textView, by: 1)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            shiftLevel(textView, by: -1)
            return true
        default:
            return false
        }
    }

    /// Bullets by level, the same for items and for bullets being typed.
    static let bulletGlyphs = ["•", "◦", "▪", "‣"]

    /// A bullet as typed text (it looks like an item's bullet, so nothing shifts when the line becomes one).
    func bullet(depth: Int) -> NSAttributedString {
        let text = NSMutableAttributedString(string: Self.bulletGlyphs[max(0, min(depth, 3))],
                                             attributes: bodyAttributes.merging([.foregroundColor: accent.withAlphaComponent(0.85)]) { $1 })
        text.append(NSAttributedString(string: "  ", attributes: bodyAttributes))
        return text
    }

    /// Tab / ⇧Tab: every line in the selection goes a level in or out, and its bullet follows the level.
    private func shiftLevel(_ textView: NSTextView, by step: Int) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let string = storage.string as NSString
        let selection = textView.selectedRange()
        let covered = string.paragraphRange(for: NSRange(location: min(selection.location, string.length), length: selection.length))
        var starts: [Int] = []
        var location = covered.location
        repeat {
            let paragraph = string.paragraphRange(for: NSRange(location: min(location, string.length - 1), length: 0))
            let fixed = storage.attribute(.asmoDay, at: paragraph.location, effectiveRange: nil) != nil
                || ((storage.attribute(.asmoKind, at: paragraph.location, effectiveRange: nil) as? String).flatMap(DocLine.Kind.init)?.readOnly ?? false)
            if !fixed { starts.append(paragraph.location) }
            location = NSMaxRange(paragraph)
            if paragraph.length == 0 { break }
        } while location < NSMaxRange(covered)
        guard !starts.isEmpty else { return }
        let undo = textView.undoManager
        undo?.beginUndoGrouping()
        var caret = selection.location
        for start in starts.reversed() {
            let now = storage.string as NSString
            let paragraph = now.paragraphRange(for: NSRange(location: start, length: 0))
            let raw = now.substring(with: paragraph)
            let depth = raw.prefix { $0 == "\t" }.count
            let next = max(0, min(3, depth + step))
            guard next != depth else { continue }
            // The bullet after the tabs takes the new level's shape (an item's bullet keeps its markers).
            let glyphAt = start + depth
            if glyphAt < now.length, Self.bulletGlyphs.contains(now.substring(with: NSRange(location: glyphAt, length: 1))) {
                var attributes = storage.attributes(at: glyphAt, effectiveRange: nil)
                attributes[.paragraphStyle] = bodyAttributes[.paragraphStyle]
                textView.insertText(NSAttributedString(string: Self.bulletGlyphs[next], attributes: attributes),
                                    replacementRange: NSRange(location: glyphAt, length: 1))
            }
            if step > 0 {
                // The tab takes the line's own markers, so an item's line stays one line of that item.
                var attributes = storage.attributes(at: start, effectiveRange: nil)
                for key in [NSAttributedString.Key.asmoCheck, .asmoTag, .attachment, .cursor, .link] { attributes[key] = nil }
                attributes[.font] = bodyFont
                textView.insertText(NSAttributedString(string: "\t", attributes: attributes), replacementRange: NSRange(location: start, length: 0))
                if start <= caret { caret += 1 }
            } else {
                textView.insertText("", replacementRange: NSRange(location: start, length: 1))
                if start < caret { caret -= 1 }
            }
        }
        undo?.endUndoGrouping()
        if selection.length == 0 { textView.setSelectedRange(NSRange(location: min(caret, storage.length), length: 0)) }
    }

    /// The parts of the page that are fixed: each day's heading (with the line breaks on both sides, so it can't be
    /// merged into the line above or below) and read-only lines (events, important dates, the history).
    /// `readOnly` tells the two apart: typing that lands on a heading goes to that day's first line instead.
    struct Fixed { var range: NSRange; var heading: Bool }

    func fixedRanges(near range: NSRange, in storage: NSTextStorage) -> [Fixed] {
        let string = storage.string as NSString
        guard string.length > 0 else { return [] }
        var result: [Fixed] = []
        var location = string.paragraphRange(for: NSRange(location: min(max(0, range.location - 1), string.length - 1), length: 0)).location
        let end = min(string.length, NSMaxRange(range) + 1)
        while location < string.length, location <= end {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            let heading = storage.attribute(.asmoDay, at: paragraph.location, effectiveRange: nil) != nil
            let kind = (storage.attribute(.asmoKind, at: paragraph.location, effectiveRange: nil) as? String).flatMap(DocLine.Kind.init)
                ?? (paragraph.length > 1 ? (storage.attribute(.asmoKind, at: NSMaxRange(paragraph) - 2, effectiveRange: nil) as? String).flatMap(DocLine.Kind.init) : nil)
            if heading || kind?.readOnly == true {
                let start = max(0, paragraph.location - 1)
                result.append(Fixed(range: NSRange(location: start, length: NSMaxRange(paragraph) - start), heading: heading))
            }
            location = NSMaxRange(paragraph)
            if paragraph.length == 0 { break }
        }
        return result
    }

    /// Headings and read-only lines never change, whatever the edit: an edit across them changes everything else,
    /// and typing that would land inside them lands next to them. Nothing beeps and nothing is refused.
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard !applying, !redirecting, let storage = textView.textStorage else { return true }
        if let replacementString, redirectBuffer != nil, range.length == 0 { redirectBuffer! += replacementString; return false }
        let fixed = fixedRanges(near: range, in: storage)
        let text = replacementString ?? ""
        if range.length == 0 {
            // Inserting at a fixed range's first position is the end of the line above: fine.
            guard let hit = fixed.first(where: { range.location > $0.range.location && range.location < NSMaxRange($0.range) }) else {
                return finishChange(textView, range: range, replacement: replacementString)
            }
            guard !text.isEmpty else { return false }
            // Keys typed before the moved text lands join it (fast typing stays in order, on one line).
            if redirectBuffer != nil { redirectBuffer! += text; return false }
            redirectBuffer = text
            let string = storage.string as NSString
            let end = min(NSMaxRange(hit.range), string.length)
            // On a date: write on the day's first line. On an event or the history: on a new line below it.
            let target = hit.heading ? end : (end > 0 && string.character(at: end - 1) == 10 ? end - 1 : end)
            // Under a heading, a line of its own unless the day's first line is empty (never glued onto an item).
            let nextEmpty = target >= string.length || string.character(at: target) == 10
            let heading = hit.heading
            // Made right after AppKit's question, not inside it.
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self else { return }
                let typed = self.redirectBuffer ?? ""
                self.redirectBuffer = nil
                guard let textView, let storage = textView.textStorage, target <= storage.length, !typed.isEmpty else { return }
                let insert = heading ? (nextEmpty ? typed : typed + "\n") : "\n" + typed
                let caret = target + (insert as NSString).length - (heading && !nextEmpty ? 1 : 0)
                self.redirecting = true
                textView.insertText(NSAttributedString(string: insert, attributes: self.bodyAttributes),
                                    replacementRange: NSRange(location: target, length: 0))
                textView.setSelectedRange(NSRange(location: min(caret, storage.length), length: 0))
                self.redirecting = false
            }
            return false
        }
        let hits = fixed.filter { NSIntersectionRange(range, $0.range).length > 0 }
        guard !hits.isEmpty else { return finishChange(textView, range: range, replacement: replacementString) }
        // What's left of the edit once the fixed parts are taken out.
        var pieces: [NSRange] = []
        var cursor = range.location
        for hit in hits.sorted(by: { $0.range.location < $1.range.location }) {
            if hit.range.location > cursor { pieces.append(NSRange(location: cursor, length: hit.range.location - cursor)) }
            cursor = max(cursor, NSMaxRange(hit.range))
        }
        if cursor < NSMaxRange(range) { pieces.append(NSRange(location: cursor, length: NSMaxRange(range) - cursor)) }
        // Only fixed text selected (part of a date): typing over it is typing on it.
        if pieces.isEmpty, let last = hits.last, last.range.length > 1 {
            return self.textView(textView, shouldChangeTextIn: NSRange(location: last.range.location + 1, length: 0), replacementString: replacementString)
        }
        let target = pieces.first?.location ?? min(NSMaxRange(hits.last!.range), storage.length)
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self, let textView, let storage = textView.textStorage,
                  pieces.allSatisfy({ NSMaxRange($0) <= storage.length }) else { return }
            let undo = textView.undoManager
            undo?.beginUndoGrouping()
            self.redirecting = true
            for piece in pieces.reversed() { textView.insertText("", replacementRange: piece) }
            if !text.isEmpty {
                textView.insertText(NSAttributedString(string: text, attributes: self.bodyAttributes),
                                    replacementRange: NSRange(location: min(target, storage.length), length: 0))
            } else {
                textView.setSelectedRange(NSRange(location: min(target, storage.length), length: 0))
            }
            self.redirecting = false
            undo?.endUndoGrouping()
        }
        return false
    }

    /// An ordinary edit: as-you-type Markdown and clean typing attributes.
    private func finishChange(_ textView: NSTextView, range: NSRange, replacement replacementString: String?) -> Bool {
        cleanTypingAttributes(textView)
        if let replacementString, range.length == 0, markdownShortcut(textView, at: range.location, typed: replacementString) {
            return false
        }
        return true
    }

    /// Markdown as you write it: "# " a heading, "- " a bullet, "[] " a checkbox at the start of a line;
    /// **bold**, *italic*, ~~strike~~, `code` and ==highlight== when the closing mark is typed.
    private func markdownShortcut(_ textView: NSTextView, at location: Int, typed: String) -> Bool {
        guard typed.count == 1, let storage = textView.textStorage, textView.markedRange().length == 0 else { return false }
        let string = storage.string as NSString
        let line = string.paragraphRange(for: NSRange(location: min(location, string.length), length: 0))
        guard storage.length == 0 || line.location >= storage.length
                || storage.attribute(.asmoLine, at: line.location, effectiveRange: nil) == nil else { return false }
        let before = string.substring(with: NSRange(location: line.location, length: location - line.location))
        let indent = before.prefix { $0 == "\t" }
        let typedBody = String(before.dropFirst(indent.count))
        let lineStart = line.location + indent.utf16.count
        var body = bodyAttributes
        if typed == " " || typed == "\u{3000}" {
            let bullets = ["-": "• ", "*": "• ", "+": "• ", "[]": "☐ ", "[ ]": "☐ ", "【】": "☐ ", "[x]": "☑ ", "[X]": "☑ "]
            if let marker = bullets[typedBody] {
                textView.insertText(marker == "• " ? bullet(depth: indent.count) : NSAttributedString(string: marker, attributes: body),
                                    replacementRange: NSRange(location: lineStart, length: typedBody.utf16.count))
                textView.typingAttributes = bodyAttributes
                return true
            }
            let sizes: [String: CGFloat] = ["#": 19, "##": 17, "###": 16]
            if let size = sizes[typedBody] {
                body[.font] = NSFont.systemFont(ofSize: size, weight: .semibold)
                textView.insertText(NSAttributedString(string: "", attributes: body),
                                    replacementRange: NSRange(location: lineStart, length: typedBody.utf16.count))
                let rest = string.paragraphRange(for: NSRange(location: lineStart, length: 0))
                if rest.length > 0 { storage.addAttribute(.font, value: body[.font]!, range: rest) }
                textView.typingAttributes[.font] = body[.font]
                return true
            }
            return false
        }
        // Inline marks: the closing mark finishes the span.
        let typedText = before + typed
        let patterns: [(String, (inout [NSAttributedString.Key: Any]) -> Void)] = [
            (#"\*\*([^*\n]+)\*\*$"#, { $0[.font] = NSFont.systemFont(ofSize: 15, weight: .semibold) }),
            (#"__([^_\n]+)__$"#, { $0[.font] = NSFont.systemFont(ofSize: 15, weight: .semibold) }),
            (#"(?<![*])\*([^*\s][^*\n]*)\*$"#, { $0[.obliqueness] = 0.18 }),
            (#"[~～]{2}([^~～\n]+)[~～]{2}$"#, { [quiet] in $0[.strikethroughStyle] = NSUnderlineStyle.single.rawValue; $0[.foregroundColor] = quiet }),
            (#"`([^`\n]+)`$"#, {
                $0[.font] = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
                $0[.backgroundColor] = PageMarkdown.codeBackground
            }),
            (#"==([^=\n]+)==$"#, { $0[.backgroundColor] = PageMarkdown.highlightBackground }),
        ]
        guard "*_~～`=".contains(typed) else { return false }
        for (pattern, style) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: typedText, range: NSRange(location: 0, length: (typedText as NSString).length)) else { continue }
            let inner = (typedText as NSString).substring(with: match.range(at: 1))
            var attributes = bodyAttributes
            style(&attributes)
            let replaced = NSRange(location: line.location + match.range.location, length: match.range.length - typed.utf16.count)
            textView.insertText(NSAttributedString(string: inner, attributes: attributes), replacementRange: replaced)
            // What comes next is plain again.
            textView.typingAttributes = bodyAttributes
            return true
        }
        return false
    }

    /// Typed text keeps the user's formatting but never item, heading or note markers.
    private func cleanTypingAttributes(_ textView: NSTextView) {
        var attributes = textView.typingAttributes
        for key in [NSAttributedString.Key.asmoLine, .asmoKind, .asmoCheck, .asmoTag, .asmoDay, .asmoNote, .attachment, .cursor] {
            attributes[key] = nil
        }
        // After a day heading (or with no font) writing starts plain; a heading the writer made keeps its size.
        if textView.typingAttributes[.asmoDay] != nil || attributes[.font] == nil { attributes[.font] = bodyFont }
        if attributes[.strikethroughStyle] != nil { attributes[.strikethroughStyle] = nil; attributes[.foregroundColor] = ink }
        textView.typingAttributes = attributes
    }

    /// The cursor never stands on a date: a click on a heading puts it at the start of that day's writing, and
    /// moving up past a heading goes on to the end of the day before. (Selections can cross headings freely, to
    /// copy; what an edit can't change is decided in shouldChangeTextIn.)
    func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange,
                  toCharacterRange new: NSRange) -> NSRange {
        guard !applying, new.length == 0, let storage = textView.textStorage, storage.length > 0 else { return new }
        let string = storage.string as NSString
        let probe = min(new.location, string.length - 1)
        let paragraph = string.paragraphRange(for: NSRange(location: probe, length: 0))
        guard new.location < string.length || string.character(at: string.length - 1) != 10,
              storage.attribute(.asmoDay, at: paragraph.location, effectiveRange: nil) != nil,
              NSLocationInRange(new.location, paragraph) || new.location == string.length else { return new }
        let below = min(NSMaxRange(paragraph), string.length)
        // Only ↑ / ← continue up to the day before; a click (or anything else) lands below the date.
        let event = NSApp.currentEvent
        let arrowUp = event?.type == .keyDown && [123, 126, 115, 116].contains(event?.keyCode ?? 0)
        let goingUp = arrowUp && new.location < old.location
        if goingUp, paragraph.location > 0 { return NSRange(location: paragraph.location - 1, length: 0) }
        if event?.type == .keyDown { return NSRange(location: below, length: 0) }
        // A click on a date: write in that day, on its writing line (the empty line at the end of its section),
        // never at the start of its first item.
        var line = below
        var last = below
        while line < string.length {
            let next = string.paragraphRange(for: NSRange(location: line, length: 0))
            if storage.attribute(.asmoDay, at: next.location, effectiveRange: nil) != nil { break }
            last = next.location
            line = NSMaxRange(next)
            if next.length == 0 { break }
        }
        let writing = string.paragraphRange(for: NSRange(location: min(last, max(0, string.length - 1)), length: 0))
        let empty = string.substring(with: writing).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && storage.attribute(.asmoLine, at: writing.location, effectiveRange: nil) == nil
        if empty { return NSRange(location: writing.location, length: 0) }
        return NSRange(location: below, length: 0)
    }

    /// The day a position is in: the nearest date heading above it. Looked up on every cursor move, so it only
    /// walks up the few lines to that heading (never reads the whole page).
    private func day(at location: Int) -> PlanDate? {
        guard let storage = view?.textStorage, storage.length > 0 else { return nil }
        let string = storage.string as NSString
        var probe = min(location, string.length - 1)
        while true {
            let paragraph = string.paragraphRange(for: NSRange(location: probe, length: 0))
            if let key = storage.attribute(.asmoDay, at: paragraph.location, effectiveRange: nil) as? String {
                if let known = dayKeys[key] { return known }
                let day = JournalDays.date(forKey: key)
                dayKeys[key] = day
                return day
            }
            guard paragraph.location > 0 else { return nil }
            probe = paragraph.location - 1
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView, !applying else { return }
        // The format bar follows a selection made with the keyboard too (a mouse selection shows it on mouse up).
        if NSEvent.pressedMouseButtons & 1 == 0 { (textView as? DocTextView)?.refreshSelectionBar(after: 0.25) }
        cleanTypingAttributes(textView)
        // The cursor moved to another day: what was written in the day it left is organized now.
        if !parent.organizeWhenIdle {
            let day = self.day(at: textView.selectedRange().location)
            if let day, day != cursorDay {
                let left = cursorDay
                cursorDay = day
                if left != nil { DispatchQueue.main.async { [weak self] in self?.organize(includingCurrent: false) } }
            }
        }
    }

    // MARK: Checkboxes

    func toggleCheck(at index: Int) {
        guard let storage = view?.textStorage,
              let id = storage.attribute(.asmoCheck, at: index, effectiveRange: nil) as? String,
              let kind = kinds[id], let day = lineDays[id] else { return }
        parent.actions.toggle(DocLine(kind: kind, id: id, title: ""), day)
    }

    // MARK: Store → document

    /// Brings the document in line with stored data without disturbing the line being edited:
    /// redraws lines that changed elsewhere, adds lines for new items, removes lines for items that are gone.
    func reconcile(_ days: [DocDay]) {
        guard let view, let storage = view.textStorage, !applying else { return }
        #if DEBUG
        let started = Date.now
        defer { PerfLog.note("reconcile", since: started) }
        #endif
        // Edits not saved yet (deleting lines, say): save them first and wait for the store to catch up, or the
        // stale store would draw the deleted lines right back.
        if let pending = pendingSync, !pending.isCancelled {
            pending.cancel()
            pendingSync = nil
            syncEdits()
            return
        }
        // Nothing the page shows changed (most updates: a timer, the window, another view): nothing to do.
        // Reading a long page back costs real time, so don't.
        if days == reconciled { return }
        reconciled = days
        let list = paragraphs()
        let editing = view.window?.firstResponder === view ? view.selectedRange() : nil
        var wanted: [String: (DocLine, PlanDate)] = [:]
        for day in days { for line in day.lines { wanted[line.id] = (line, day.day) } }
        confirmed.formUnion(wanted.keys)
        applying = true
        var changed = false
        defer {
            applying = false
            if changed { resetUndo() }
        }
        // Redraw or remove, bottom-up.
        for paragraph in list.reversed() where !paragraph.isHeading {
            guard let id = paragraph.id else { continue }
            let underCursor = editing.map { NSLocationInRange($0.location, paragraph.range) } ?? false
            if let (line, day) = wanted[id] {
                if paragraph.day != day {
                    storage.deleteCharacters(in: paragraph.range)
                    changed = true
                    drawn[id] = nil
                } else if drawn[id] != line.signature && underCursor {
                    // Left alone while being written in: look again next time.
                    reconciled = []
                } else if drawn[id] != line.signature {
                    var redrawn = line
                    redrawn.depth = paragraph.depth
                    storage.replaceCharacters(in: paragraph.range, with: render(redrawn, day: day))
                    changed = true
                }
            } else if confirmed.contains(id) {
                // The item is gone (turned into a repeating one, deleted elsewhere): its line goes, even under
                // the cursor (the cursor stays where the line was).
                _ = underCursor
                confirmed.remove(id)
                storage.deleteCharacters(in: paragraph.range)
                changed = true
                drawn[id] = nil
                kinds[id] = nil
                lineDays[id] = nil
            }
        }
        // Add lines for items that aren't in the document yet, after the day's last item line.
        // (Never one just deleted here: the store may not have caught up yet.)
        let present = Set(paragraphs().compactMap(\.id))
        let fresh = Set(removedHere.filter { Date.now.timeIntervalSince($0.value) < 3 }.keys)
        for day in days {
            for line in day.lines where !present.contains(line.id) && !fresh.contains(line.id) {
                let current = paragraphs()
                guard let headingIndex = current.firstIndex(where: { $0.isHeading && $0.day == day.day }) else { continue }
                var insertAt = NSMaxRange(current[headingIndex].range)
                var cursor = headingIndex + 1
                while cursor < current.count, !current[cursor].isHeading, current[cursor].id != nil {
                    insertAt = NSMaxRange(current[cursor].range)
                    cursor += 1
                }
                storage.insert(render(line, day: day.day), at: insertAt)
                changed = true
            }
        }
    }

    func scroll(to day: PlanDate) {
        anchor = day
        guard let view else { return }
        // Put the cursor on the day's empty writing line (the last line of its section).
        let list = paragraphs()
        if let start = list.firstIndex(where: { $0.isHeading && $0.day == day }) {
            var last = list[start]
            var cursor = start + 1
            while cursor < list.count, !list[cursor].isHeading { last = list[cursor]; cursor += 1 }
            view.setSelectedRange(NSRange(location: last.range.location + (last.id == nil ? max(0, last.range.length - 1) : last.range.length), length: 0))
            // In a long document (many days), bring the day's heading to the top of the window.
            if let layout = view.layoutManager, let container = view.textContainer, let clip = view.enclosingScrollView?.contentView {
                layout.ensureLayout(for: container)
                let glyphs = layout.glyphRange(forCharacterRange: list[start].range, actualCharacterRange: nil)
                let top = layout.boundingRect(forGlyphRange: glyphs, in: container).minY + view.textContainerInset.height
                if clip.bounds.height > 0, view.bounds.height > clip.bounds.height {
                    view.scrollToVisible(NSRect(x: 0, y: max(0, top - 14), width: 1, height: clip.bounds.height))
                }
            }
        }
    }
}
#endif
