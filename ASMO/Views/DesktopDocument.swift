#if os(macOS)
import AppKit
#endif
import SwiftUI

// MARK: Data handed to the document

/// One line that stands for a stored item.
struct DocLine: Equatable {
    enum Kind: String { case task, routine, event }
    var kind: Kind
    /// Task UUID, "routineUUID|dayKey", or event id.
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

// MARK: Attributes

extension NSAttributedString.Key {
    static let asmoDay = NSAttributedString.Key("asmo.day")
    static let asmoLine = NSAttributedString.Key("asmo.line")
    static let asmoKind = NSAttributedString.Key("asmo.kind")
    static let asmoCheck = NSAttributedString.Key("asmo.check")
    static let asmoTag = NSAttributedString.Key("asmo.tag")
    static let asmoNote = NSAttributedString.Key("asmo.note")
}

// MARK: View

/// The whole planner as one document: each day a heading, items as checklist lines, notes as text.
/// Writing is plain typing; finished lines become items without asking.
enum NoteRule {
    static func stripMarker(_ text: String) -> String {
        for marker in ["• ", "◦ ", "▪ ", "☐ ", "☑ ", "- ", "* "] where text.hasPrefix(marker) { return String(text.dropFirst(marker.count)) }
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

    func makeCoordinator() -> DocCoordinator { DocCoordinator(self) }

    /// Leaving the page by any route (another view, ⌘1/⌘2, closing): what was written is organized, the same as
    /// when it loses the cursor. Results land in their days even though the page is gone.
    static func dismantleNSView(_ view: DocTextView, coordinator: DocCoordinator) {
        coordinator.organize(includingCurrent: true)
    }

    /// The page lives inside the 逐日 card: no scroll view of its own, it grows with what's written.
    func makeNSView(context: Context) -> DocTextView {
        let view = DocTextView(frame: .zero)
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
        container.containerSize = NSSize(width: max(60, width - view.textContainerInset.width * 2), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        return CGSize(width: width, height: max(minHeight, ceil(used + view.textContainerInset.height * 2 + 8)))
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

    override func mouseDown(with event: NSEvent) {
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

final class DocCoordinator: NSObject, NSTextViewDelegate {
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
    }

    deinit {
        if let agentWrites { NotificationCenter.default.removeObserver(agentWrites) }
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
        syncEdits()
        let cursor = view.selectedRange().location
        let fromEnd = storage.length - cursor
        // The line the cursor is in (its text and day) and how far into it: found again after drawing.
        let before = paragraphs()
        let here = before.first { $0.range.location <= cursor && cursor <= $0.range.location + ($0.text as NSString).length }
        let visible = view.enclosingScrollView?.contentView.bounds.origin
        let hadFocus = view.window?.firstResponder === view
        build(days, anchor: anchor ?? days.first?.day ?? PlanDate.from(.now, calendar: .current), scrolls: false)
        var location = max(0, min(storage.length, storage.length - fromEnd))
        if let here, let again = paragraphs().first(where: { $0.text == here.text && $0.day == here.day && !$0.isHeading }) {
            location = min(storage.length, again.range.location + cursor - here.range.location)
        }
        view.setSelectedRange(NSRange(location: location, length: 0))
        if let visible, let clip = view.enclosingScrollView?.contentView {
            clip.scroll(to: visible)
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
                .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold),
            ]) { $1 }))
        }
        var titleAttributes = base
        if !line.done, let style = line.style { apply(style, to: &titleAttributes) }
        result.append(NSAttributedString(string: line.title, attributes: titleAttributes))
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

    func paragraphs() -> [Paragraph] {
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
                currentDay = JournalDays.date(forKey: key)
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
        // (Markdown as you type is handled before the change, in markdownShortcut, so it can be undone.)
        // Struck words go quiet right away, however they were struck (toolbar, ⌘ key, ~~ ~~).
        if let view, let storage = view.textStorage, storage.length > 0 {
            let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: min(view.selectedRange().location, storage.length - 1), length: 0))
            Self.strikeQuietly(storage, in: paragraph, quiet: quiet, ink: ink)
        }
        pendingSync?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncEdits() }
        pendingSync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        // A pause in writing is when the finished lines get organized (never the line being written).
        idleOrganize?.cancel()
        guard parent.organizeWhenIdle else { return }
        let idle = DispatchWorkItem { [weak self] in self?.organize(includingCurrent: false) }
        idleOrganize = idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: idle)
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
            guard kind != .event else { continue }
            if paragraph.text.isEmpty {
                // An emptied item line that the cursor has left: the item is gone.
                if !NSLocationInRange(cursor, paragraph.range) || cursor == NSMaxRange(paragraph.range) {
                    continue
                }
                continue
            }
            // Only lines that changed since the last save are pushed (re-reading every line on each pause was slow).
            let style = titleStyle(in: paragraph.range) ?? ""
            let parentLine = parentID(for: index, in: list)
            let signature = "\(paragraph.text)|\(paragraph.depth)|\(parentLine?.uuidString ?? "")|\(style)|\(day.key)"
            if synced[id] == signature { continue }
            synced[id] = signature
            let line = DocLine(kind: kind, id: id, depth: paragraph.depth, title: paragraph.text)
            parent.actions.update(line, paragraph.text, day, parentLine)
            // Striking an item through is how a doc says "done" (there are no checkboxes while writing).
            let parts = style.split(separator: " ").map(String.init)
            if kind == .task {
                let rest = parts.filter { $0 != "s" }
                parent.actions.restyle(id, rest.isEmpty ? nil : rest.joined(separator: " "))
            }
            parent.actions.strike(line, day, parts.contains("s"))
        }
        for (id, kind) in kinds where !present.contains(id) && kind != .event && confirmed.contains(id) {
            if let day = lineDays[id] {
                parent.actions.delete(DocLine(kind: kind, id: id, title: ""), day)
                removedHere[id] = .now
            }
            kinds[id] = nil
            drawn[id] = nil
            lineDays[id] = nil
        }
        saveNotes(list)
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
    private func titleStyle(in range: NSRange) -> String? {
        guard let storage = view?.textStorage else { return nil }
        let string = storage.string as NSString
        var index = NSMaxRange(range) - 1
        while index >= range.location {
            let character = string.character(at: index)
            let skip = character == 10 || character == 32 || character == 9
                || storage.attribute(.asmoTag, at: index, effectiveRange: nil) != nil
            if !skip { break }
            index -= 1
        }
        guard index >= range.location else { return nil }
        let attributes = storage.attributes(at: index, effectiveRange: nil)
        var parts: [String] = []
        if let font = attributes[.font] as? NSFont {
            let traits = NSFontManager.shared.traits(of: font)
            if traits.contains(.boldFontMask) || NSFontManager.shared.weight(of: font) >= 8 { parts.append("b") }
            if traits.contains(.italicFontMask) || ((attributes[.obliqueness] as? CGFloat) ?? 0) > 0.05 { parts.append("i") }
        }
        if attributes[.underlineStyle] != nil { parts.append("u") }
        // Struck through = done (drawn that way for done items, or struck by the writer).
        if attributes[.strikethroughStyle] != nil { parts.append("s") }
        // A color is the writer's only when it isn't one the page draws with, in either look.
        if let color = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB), !DocCoordinator.isThemeColor(color) {
            parts.append(String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The lines as drawn match the store: remember them, so the next save only pushes what's edited after.
    private func markSynced() {
        let list = paragraphs()
        for (index, paragraph) in list.enumerated() where !paragraph.isHeading {
            guard let id = paragraph.id, let day = paragraph.day else { continue }
            let style = titleStyle(in: paragraph.range) ?? ""
            synced[id] = "\(paragraph.text)|\(paragraph.depth)|\(parentID(for: index, in: list)?.uuidString ?? "")|\(style)|\(day.key)"
        }
    }

    private func saveNotes(_ list: [Paragraph]) {
        guard let storage = view?.textStorage else { return }
        var byDay: [PlanDate: NSMutableAttributedString] = [:]
        for paragraph in list where !paragraph.isHeading && paragraph.id == nil && paragraph.day != nil {
            guard !paragraph.text.isEmpty || containsAttachment(paragraph.range) else { continue }
            let piece = storage.attributedSubstring(from: paragraph.range)
            // NSMutableAttributedString is a class: store the instance, don't mutate a temporary default.
            let text = byDay[paragraph.day!] ?? NSMutableAttributedString()
            text.append(piece)
            byDay[paragraph.day!] = text
        }
        for day in Set(list.compactMap(\.day)) {
            let text = byDay[day]
            let pendingNow = list.filter { $0.day == day && !$0.isHeading && $0.id == nil && !$0.isNote && !$0.text.isEmpty }
                .map { Self.stripMarker($0.text) }
            // Unchanged since the last save: nothing to encode or write.
            if let last = savedNotes[day], last.pending == pendingNow,
               (last.text == nil && text == nil) || (text.map { last.text?.isEqual(to: $0) ?? false } ?? false) { continue }
            savedNotes[day] = (text?.copy() as? NSAttributedString, pendingNow)
            let data = text.flatMap { original -> Data? in
                let neutral = NSMutableAttributedString(attributedString: original)
                Self.neutralizeInk(neutral, ink: nil)
                return try? neutral.data(from: NSRange(location: 0, length: neutral.length),
                             documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            }
            let pending = list.filter { $0.day == day && !$0.isHeading && $0.id == nil && !$0.isNote && !$0.text.isEmpty }
                .map { Self.stripMarker($0.text) }
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
        if DocCoordinator.looksLikeNote(paragraph.text, heading: isHeadingStyled(paragraph.range)) || containsAttachment(paragraph.range) {
            mark(paragraph.range, note: true)
            return .note
        }
        guard let lines = parent.actions.commit(paragraph.text, day, day, parentTask, false) else {
            mark(paragraph.range, note: true)
            return .note
        }
        applying = true
        defer { applying = false }
        if lines.isEmpty {
            // Everything went to other days (or it was a command): leave an empty line where the writing was.
            let hasBreak = (storage.string as NSString).substring(with: paragraph.range).hasSuffix("\n")
            let blank = NSRange(location: paragraph.range.location, length: paragraph.range.length - (hasBreak ? 1 : 0))
            storage.replaceCharacters(in: blank, with: NSAttributedString(string: "", attributes: bodyAttributes))
            return .cleared(paragraph.range.location)
        }
        let replacement = NSMutableAttributedString()
        for line in lines {
            var line = line
            line.depth = paragraph.depth
            replacement.append(render(line, day: day))
        }
        let hadBreak = (storage.string as NSString).substring(with: paragraph.range).hasSuffix("\n")
        if !hadBreak, replacement.string.hasSuffix("\n") {
            replacement.deleteCharacters(in: NSRange(location: replacement.length - 1, length: 1))
        }
        storage.replaceCharacters(in: paragraph.range, with: replacement)
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
            // Writing stays free: Return is just a new line at the same indent (lists continue).
            let raw = string.substring(with: paragraph).trimmingCharacters(in: .newlines)
            let indent = String(raw.prefix { $0 == "\t" })
            var marker = ""
            let isItem = storage.attribute(.asmoLine, at: min(paragraph.location, max(0, string.length - 1)), effectiveRange: nil) != nil
            if !isItem {
                let body = raw.dropFirst(indent.count)
                for candidate in ["• ", "☐ ", "☑ "] where body.hasPrefix(candidate) {
                    if body.count == candidate.count {
                        textView.insertText("", replacementRange: NSRange(location: paragraph.location, length: raw.utf16.count))
                        return true
                    }
                    marker = candidate == "☑ " ? "☐ " : candidate
                }
            }
            textView.insertText(NSAttributedString(string: "\n" + indent + marker, attributes: bodyAttributes),
                                replacementRange: textView.selectedRange())
            textView.typingAttributes = bodyAttributes
            return true
        case #selector(NSResponder.insertTab(_:)):
            textView.insertText("\t", replacementRange: NSRange(location: paragraph.location, length: 0))
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            if string.length > paragraph.location, string.character(at: paragraph.location) == 9 {
                textView.insertText("", replacementRange: NSRange(location: paragraph.location, length: 1))
            }
            return true
        default:
            return false
        }
    }

    /// Day headings and calendar events can't be edited in the document.
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard !applying, let storage = textView.textStorage else { return true }
        let string = storage.string as NSString
        var location = range.location
        let end = max(range.location, NSMaxRange(range))
        while location <= end, location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            let protected = storage.attribute(.asmoDay, at: paragraph.location, effectiveRange: nil) != nil
                || (storage.attribute(.asmoKind, at: paragraph.location, effectiveRange: nil) as? String) == DocLine.Kind.event.rawValue
            if protected {
                let touches = range.length == 0
                    ? (range.location > paragraph.location && range.location < NSMaxRange(paragraph))
                    : NSIntersectionRange(range, paragraph).length > 0
                if touches { NSSound.beep(); return false }
            }
            location = NSMaxRange(paragraph)
            if paragraph.length == 0 { break }
        }
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
                textView.insertText(NSAttributedString(string: marker, attributes: body),
                                    replacementRange: NSRange(location: lineStart, length: typedBody.utf16.count))
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

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView, let storage = textView.textStorage, !applying else { return }
        // The date heading isn't writable: keep the cursor and selections below it.
        let selection = textView.selectedRange()
        let string = storage.string as NSString
        if selection.location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: selection.location, length: 0))
            if storage.attribute(.asmoDay, at: paragraph.location, effectiveRange: nil) != nil {
                let start = NSMaxRange(paragraph)
                let end = max(start, NSMaxRange(selection))
                applying = true
                textView.setSelectedRange(NSRange(location: min(start, string.length), length: min(end, string.length) - min(start, string.length)))
                applying = false
            }
        }
        cleanTypingAttributes(textView)
        // The cursor moved to another day: what was written in the day it left is organized now.
        if !parent.organizeWhenIdle {
            let day = paragraphs().last(where: { $0.isHeading && $0.range.location <= textView.selectedRange().location })?.day
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
                } else if drawn[id] != line.signature && !underCursor {
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
