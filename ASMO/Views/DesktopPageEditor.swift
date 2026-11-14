#if os(macOS)
import AppKit
import SwiftUI

/// Drives the page's NSTextView from SwiftUI: formatting commands and taking out the lines that become tasks.
@MainActor
final class PageController: ObservableObject {
    /// The text view being formatted: a day page in 逐日, or the day document.
    weak var textView: NSTextView?
    @Published var recording = false
    @Published var isEditing = false

    var isEmpty: Bool { (textView?.string.trimmed ?? "").isEmpty }

    /// The page as stored data (nil when empty).
    func encoded() -> Data? { textView.flatMap(DayPageEditor.Coordinator.encode) }

    /// Inserts text at the cursor (used by dictation in the toolbar).
    func insert(_ text: String) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    /// Adds a line at the end of the page (a note arriving from the bar while this page is open).
    func appendLine(_ text: String) {
        guard let textView, let storage = textView.textStorage else { return }
        var attributes = textView.typingAttributes
        for key in [NSAttributedString.Key("asmo.line"), NSAttributedString.Key("asmo.kind"), NSAttributedString.Key("asmo.check"),
                    NSAttributedString.Key("asmo.day"), .attachment] { attributes[key] = nil }
        let prefix = storage.string.hasSuffix("\n") || storage.length == 0 ? "" : "\n"
        storage.append(NSAttributedString(string: prefix + text + "\n", attributes: attributes))
        textView.didChangeText()
    }

    func highlight() {
        apply { storage, range in
            let has = storage.attribute(.backgroundColor, at: range.location, effectiveRange: nil) != nil
            if has { storage.removeAttribute(.backgroundColor, range: range) }
            else { storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.32), range: range) }
        }
    }

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
    }

    func resignFocus() {
        guard let textView, textView.window?.firstResponder === textView else { return }
        textView.window?.makeFirstResponder(nil)
    }

    // MARK: Formatting

    func toggleBold() { toggleTrait(.boldFontMask) }
    func toggleItalic() { toggleTrait(.italicFontMask) }

    func toggleUnderline() { toggle(.underlineStyle, on: NSUnderlineStyle.single.rawValue) }
    func toggleStrike() { toggle(.strikethroughStyle, on: NSUnderlineStyle.single.rawValue) }

    func color(_ color: NSColor?) {
        apply { storage, range in
            if let color { storage.addAttribute(.foregroundColor, value: color, range: range) }
            else { storage.removeAttribute(.foregroundColor, range: range) }
        }
    }

    func toggleHeading() {
        guard let textView, let storage = textView.textStorage else { return }
        let range = (storage.string as NSString).paragraphRange(for: textView.selectedRange())
        let current = (storage.attribute(.font, at: min(range.location, max(0, storage.length - 1)), effectiveRange: nil) as? NSFont)
        let isHeading = (current?.pointSize ?? PageTextView.bodySize) > PageTextView.bodySize + 1
        let font = isHeading ? PageTextView.bodyFont : NSFont.systemFont(ofSize: 19, weight: .semibold)
        if range.length > 0 { edit { storage.addAttribute(.font, value: font, range: range) } }
        textView.typingAttributes[.font] = font
    }

    /// Prefixes the current line(s) with a bullet or checkbox, or removes it.
    func toggleLinePrefix(_ marker: String) {
        guard let textView, let storage = textView.textStorage else { return }
        let text = storage.string as NSString
        let range = text.paragraphRange(for: textView.selectedRange())
        var location = range.location
        edit {
            while location < range.location + range.length || (range.length == 0 && location == range.location) {
                let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
                let line = (storage.string as NSString).substring(with: paragraph)
                let indent = line.prefix { $0 == "\t" || $0 == " " }.count
                let body = String(line.dropFirst(indent))
                let markers = ["• ", "☐ ", "☑ "]
                let start = NSRange(location: paragraph.location + indent, length: 0)
                if let existing = markers.first(where: { body.hasPrefix($0) }) {
                    storage.replaceCharacters(in: NSRange(location: start.location, length: existing.utf16.count), with: "")
                    if existing != marker {
                        storage.replaceCharacters(in: start, with: NSAttributedString(string: marker, attributes: textView.typingAttributes))
                    }
                } else {
                    storage.replaceCharacters(in: start, with: NSAttributedString(string: marker, attributes: textView.typingAttributes))
                }
                let updated = (storage.string as NSString).paragraphRange(for: NSRange(location: paragraph.location, length: 0))
                location = updated.location + max(updated.length, 1)
                if range.length == 0 || location >= storage.length { break }
            }
        }
    }

    /// The line with the cursor repeats every day: " #每天" goes on its end (the page turns it into a routine;
    /// click the tag afterwards to choose other days).
    func makeRepeating() {
        guard let textView, let storage = textView.textStorage else { return }
        let string = storage.string as NSString
        let paragraph = string.paragraphRange(for: textView.selectedRange())
        var end = NSMaxRange(paragraph)
        if end > paragraph.location, string.character(at: end - 1) == 10 { end -= 1 }
        let line = string.substring(with: NSRange(location: paragraph.location, length: end - paragraph.location))
        guard !line.trimmed.isEmpty, line.range(of: #"[#＃]\s*(每天|每日|工作日|周末|每周)"#, options: .regularExpression) == nil else { return }
        var attributes = textView.typingAttributes
        for key in [NSAttributedString.Key("asmo.tag"), NSAttributedString.Key("asmo.check"), .attachment] { attributes[key] = nil }
        edit { storage.insert(NSAttributedString(string: " #每天", attributes: attributes), at: end) }
        textView.setSelectedRange(NSRange(location: end + 4, length: 0))
    }

    /// Links the selected words: a small box by the selection asks for the address (filled in from the clipboard
    /// when a link was just copied; Return confirms). Selected text that is itself an address is linked at once.
    func link() {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        let selected = (storage.string as NSString).substring(with: range).trimmed
        if let url = Self.address(selected), selected.hasPrefix("http") { setLink(url, range: range, text: nil); return }
        let probe = min(range.location, max(0, storage.length - 1))
        let existing = storage.length > 0 ? (storage.attribute(.link, at: probe, effectiveRange: nil) as? URL)?.absoluteString
            ?? storage.attribute(.link, at: probe, effectiveRange: nil) as? String : nil
        let copied = NSPasteboard.general.string(forType: .string)?.trimmed ?? ""
        let suggestion = existing ?? (copied.hasPrefix("http") && Self.address(copied) != nil ? copied : "")
        let popover = NSPopover()
        popover.behavior = .transient
        let dark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        popover.contentViewController = NSHostingController(rootView: LinkBox(address: suggestion, hasLink: existing != nil, theme: PlannerTheme(dark: dark)) { [weak self, weak popover] address in
            popover?.close()
            guard let self else { return }
            if let address { if let url = Self.address(address) { self.setLink(url, range: range, text: range.length == 0 ? address : nil) } }
            else { self.setLink(nil, range: range, text: nil) }
            self.textView?.window?.makeFirstResponder(self.textView)
        })
        var rect = textView.firstRect(forCharacterRange: range, actualRange: nil)
        rect = textView.window?.convertFromScreen(rect) ?? rect
        rect = textView.convert(rect, from: nil)
        if rect.width < 1 { rect.size.width = 1 }
        popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
    }

    /// "example.com/page" → https://example.com/page; nil when it isn't an address.
    static func address(_ text: String) -> URL? {
        let raw = text.trimmed
        guard !raw.isEmpty, !raw.contains(" "), raw.contains(".") || raw.contains(":") else { return nil }
        let full = raw.contains("://") || raw.hasPrefix("mailto:") ? raw : "https://" + raw
        return URL(string: full)
    }

    /// Adds, changes or (nil) removes the link on a range; with no selection the address itself is inserted, linked.
    private func setLink(_ url: URL?, range: NSRange, text: String?) {
        guard let textView, let storage = textView.textStorage, NSMaxRange(range) <= storage.length else { return }
        edit {
            if range.length > 0 {
                if let url { storage.addAttribute(.link, value: url, range: range) }
                else { storage.removeAttribute(.link, range: range) }
            } else if let url, let text {
                storage.insert(NSAttributedString(string: text, attributes: textView.typingAttributes.merging([.link: url]) { $1 }), at: range.location)
            } else if url == nil, storage.length > 0 {
                // The cursor sits in a link: the whole link goes.
                var whole = NSRange()
                if storage.attribute(.link, at: min(range.location, storage.length - 1), longestEffectiveRange: &whole,
                                     in: NSRange(location: 0, length: storage.length)) != nil {
                    storage.removeAttribute(.link, range: whole)
                }
            }
        }
    }

    func insertImage() {
        guard let textView else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        textView.insertImage(image)
    }

    /// The page as idea lines for the mind map: indentation, headings (by font size) and markers kept.
    func ideaLines() -> [IdeaLine] {
        guard let storage = textView?.textStorage else { return [] }
        let text = storage.string as NSString
        var lines: [IdeaLine] = []
        var location = 0
        while location < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            location = paragraph.location + max(paragraph.length, 1)
            let raw = text.substring(with: paragraph).trimmingCharacters(in: .newlines)
                .replacingOccurrences(of: "\u{FFFC}", with: "")
            let indent = raw.prefix { $0 == "\t" || $0 == " " || $0 == "\u{3000}" }
            let body = String(raw.dropFirst(indent.count)).trimmed
            guard !body.isEmpty else { continue }
            let font = storage.attribute(.font, at: paragraph.location, effectiveRange: nil) as? NSFont
            let heading = (font?.pointSize ?? PageTextView.bodySize) > PageTextView.bodySize + 1
            lines.append(IdeaLine(level: indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2, isHeading: heading, text: body))
        }
        return lines
    }

    // MARK: Turning lines into tasks

    struct Candidate {
        var range: NSRange
        var text: String
        var level: Int
        var style: String?
    }

    /// The lines that could be things to do: everything except headings, images and long paragraphs,
    /// which always stay on the page as notes.
    func candidates() -> [Candidate] {
        guard let textView, let storage = textView.textStorage else { return [] }
        var result: [Candidate] = []
        let text = storage.string as NSString
        var location = 0
        while location < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            location = paragraph.location + max(paragraph.length, 1)
            let raw = text.substring(with: paragraph).trimmingCharacters(in: .newlines)
            let indent = raw.prefix { $0 == "\t" || $0 == " " || $0 == "\u{3000}" }
            var body = String(raw.dropFirst(indent.count))
            if body.trimmed.isEmpty { continue }
            let font = storage.attribute(.font, at: paragraph.location, effectiveRange: nil) as? NSFont
            let isHeading = (font?.pointSize ?? PageTextView.bodySize) > PageTextView.bodySize + 1
            var hasImage = false
            storage.enumerateAttribute(.attachment, in: paragraph) { value, _, _ in if value != nil { hasImage = true } }
            if isHeading || hasImage || body.count > 80 { continue }
            for marker in ["• ", "☐ ", "☑ "] where body.hasPrefix(marker) { body = String(body.dropFirst(marker.count)); break }
            let level = indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
            result.append(Candidate(range: paragraph, text: body.replacingOccurrences(of: "\u{FFFC}", with: ""),
                                    level: level, style: style(at: paragraph, in: storage, skipping: indent.count)))
        }
        return result
    }

    /// Removes the given lines from the page, skipping any that changed since they were read.
    func remove(_ lines: [Candidate]) {
        guard let textView, let storage = textView.textStorage else { return }
        edit {
            for line in lines.sorted(by: { $0.range.location > $1.range.location }) {
                guard NSMaxRange(line.range) <= storage.length else { continue }
                let current = (storage.string as NSString).substring(with: line.range)
                guard current.contains(line.text) else { continue }
                storage.deleteCharacters(in: line.range)
            }
            while storage.string.hasSuffix("\n\n") { storage.deleteCharacters(in: NSRange(location: storage.length - 1, length: 1)) }
            if storage.string.trimmed.isEmpty { storage.setAttributedString(NSAttributedString()) }
        }
    }

    /// The formatting most of the line uses, so a bold or red line stays bold or red as an item.
    private func style(at range: NSRange, in storage: NSTextStorage, skipping indent: Int) -> String? {
        let start = min(range.location + indent, max(0, storage.length - 1))
        let attributes = storage.attributes(at: start, effectiveRange: nil)
        var parts: [String] = []
        if let font = attributes[.font] as? NSFont {
            let traits = NSFontManager.shared.traits(of: font)
            if traits.contains(.boldFontMask) { parts.append("b") }
            if traits.contains(.italicFontMask) { parts.append("i") }
        }
        if (attributes[.underlineStyle] as? Int ?? 0) != 0 { parts.append("u") }
        if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { parts.append("s") }
        if let color = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB),
           let ink = textView?.typingAttributes[.foregroundColor] as? NSColor, !color.isClose(to: ink) {
            parts.append(String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255),
                                Int(color.blueComponent * 255)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: Helpers

    private func toggleTrait(_ trait: NSFontTraitMask) {
        guard let textView else { return }
        let manager = NSFontManager.shared
        let range = textView.selectedRange()
        guard let storage = textView.textStorage else { return }
        if range.length == 0 {
            let font = (textView.typingAttributes[.font] as? NSFont) ?? PageTextView.bodyFont
            let slanted = ((textView.typingAttributes[.obliqueness] as? CGFloat) ?? 0) > 0.05
            let has = manager.traits(of: font).contains(trait) || (trait == .italicFontMask && slanted)
            textView.typingAttributes[.font] = has ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
            if trait == .italicFontMask { textView.typingAttributes[.obliqueness] = has ? nil : 0.18 }
            return
        }
        let first = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? PageTextView.bodyFont
        let slanted = ((storage.attribute(.obliqueness, at: range.location, effectiveRange: nil) as? CGFloat) ?? 0) > 0.05
        let adding = trait == .italicFontMask ? !(manager.traits(of: first).contains(trait) || slanted) : !manager.traits(of: first).contains(trait)
        edit {
            storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                let font = (value as? NSFont) ?? PageTextView.bodyFont
                storage.addAttribute(.font, value: adding ? manager.convert(font, toHaveTrait: trait)
                                                          : manager.convert(font, toNotHaveTrait: trait), range: sub)
            }
            // Chinese fonts have no italic face: italic is a slant.
            if trait == .italicFontMask {
                if adding { storage.addAttribute(.obliqueness, value: 0.18, range: range) }
                else { storage.removeAttribute(.obliqueness, range: range) }
            }
        }
    }

    private func toggle(_ key: NSAttributedString.Key, on value: Int) {
        guard let textView else { return }
        let range = textView.selectedRange()
        if range.length == 0 {
            let has = (textView.typingAttributes[key] as? Int ?? 0) != 0
            textView.typingAttributes[key] = has ? 0 : value
            return
        }
        guard let storage = textView.textStorage else { return }
        let has = (storage.attribute(key, at: range.location, effectiveRange: nil) as? Int ?? 0) != 0
        edit {
            if has { storage.removeAttribute(key, range: range) } else { storage.addAttribute(key, value: value, range: range) }
        }
    }

    private func apply(_ change: (NSTextStorage, NSRange) -> Void) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else { return }
        edit { change(storage, range) }
    }

    private func edit(_ change: () -> Void) {
        guard let textView, let storage = textView.textStorage else { return }
        storage.beginEditing()
        change()
        storage.endEditing()
        textView.didChangeText()
    }
}

private extension NSColor {
    func isClose(to other: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent) < 0.12
    }
}

extension NSTextView {
    /// Inserts an image scaled to the text width, followed by a line break.
    func insertImage(_ image: NSImage) {
        let width = min(image.size.width, max(160, bounds.width - 24 - textContainerInset.width * 2))
        let scale = image.size.width > 0 ? width / image.size.width : 1
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: 0, width: width, height: image.size.height * scale)
        let text = NSMutableAttributedString(attachment: attachment)
        text.append(NSAttributedString(string: "\n", attributes: typingAttributes))
        insertText(text, replacementRange: selectedRange())
    }
}

final class PageTextView: NSTextView {
    static let bodySize: CGFloat = 14.5
    static var bodyFont: NSFont { .systemFont(ofSize: bodySize) }
    var onFocusChange: ((Bool) -> Void)?
    /// The page's own undo history. With the window's shared one, ⌘Z after the page was closed (or reloaded
    /// after organizing) replayed edits on a text view that no longer existed and crashed the app.
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

    /// Replacing the whole text (loading, organizing) starts a fresh history.
    func resetUndo() { pageUndo.removeAllActions() }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }

}

/// The free page under a day: rich text with images and links, growing with its content.
struct DayPageEditor: NSViewRepresentable {
    let data: Data?
    let controller: PageController
    let theme: PlannerTheme
    let save: (Data?) -> Void
    let focusChanged: (Bool) -> Void
    let commandReturn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PageTextView {
        let view = PageTextView()
        view.isRichText = true
        view.importsGraphics = true
        view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticLinkDetectionEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.textContainerInset = NSSize(width: 2, height: 6)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 3
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.font = PageTextView.bodyFont
        view.textColor = NSColor(theme.ink)
        view.insertionPointColor = NSColor(theme.accent)
        view.linkTextAttributes = [.foregroundColor: NSColor(theme.accent), .underlineStyle: NSUnderlineStyle.single.rawValue,
                                   .cursor: NSCursor.pointingHand]
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 2
        view.defaultParagraphStyle = paragraph
        view.typingAttributes = [.font: PageTextView.bodyFont, .foregroundColor: NSColor(theme.ink), .paragraphStyle: paragraph]
        if let data, let text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                                         documentAttributes: nil) {
            view.textStorage?.setAttributedString(text)
        }
        view.delegate = context.coordinator
        view.onFocusChange = { focused in
            DispatchQueue.main.async {
                controller.isEditing = focused
                focusChanged(focused)
            }
        }
        controller.textView = view
        return view
    }

    func updateNSView(_ view: PageTextView, context: Context) {
        context.coordinator.parent = self
        controller.textView = view
        view.textColor = view.textColor ?? NSColor(theme.ink)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: PageTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.containerSize = NSSize(width: max(40, width - view.textContainerInset.width * 2), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        return CGSize(width: width, height: max(30, ceil(used + view.textContainerInset.height * 2)))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DayPageEditor
        private var pending: DispatchWorkItem?

        init(_ parent: DayPageEditor) { self.parent = parent }

        @MainActor private func applyShortcuts(_ view: NSTextView) { MarkdownShortcuts.apply(view) }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? PageTextView else { return }
            applyShortcuts(view)
            view.invalidateIntrinsicContentSize()
            // Save shortly after typing pauses.
            pending?.cancel()
            let work = DispatchWorkItem { [weak self, weak view] in
                guard let self, let view else { return }
                self.parent.save(Self.encode(view))
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)),
               NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                parent.commandReturn()
                return true
            }
            // A new line after "• " or "☐ " continues the list, like a doc.
            if selector == #selector(NSResponder.insertNewline(_:)), let storage = textView.textStorage {
                let text = storage.string as NSString
                let paragraph = text.paragraphRange(for: NSRange(location: textView.selectedRange().location, length: 0))
                let line = text.substring(with: paragraph).trimmingCharacters(in: .newlines)
                let indent = String(line.prefix { $0 == "\t" || $0 == " " })
                let body = line.dropFirst(indent.count)
                for marker in ["• ", "☐ ", "☑ "] where body.hasPrefix(marker) {
                    if body.count == marker.count {
                        // An empty bullet ends the list.
                        textView.insertText("", replacementRange: NSRange(location: paragraph.location, length: line.utf16.count))
                        return true
                    }
                    textView.insertText("\n" + indent + (marker == "☑ " ? "☐ " : marker), replacementRange: textView.selectedRange())
                    return true
                }
            }
            return false
        }

        func flush(_ view: PageTextView) {
            pending?.cancel()
            parent.save(Self.encode(view))
        }

        static func encode(_ view: NSTextView) -> Data? {
            guard let storage = view.textStorage, !storage.string.trimmed.isEmpty || storage.containsAttachments else { return nil }
            return try? storage.data(from: NSRange(location: 0, length: storage.length),
                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        }
    }
}


/// Markdown-style shortcuts while typing: "# " heading, "- "/"* " bullet, "[] " checkbox, "**粗体**" bold,
/// "~~删除~~" strike, "==高亮==" highlight. Shared by the day page and the day document.
enum MarkdownShortcuts {
    @MainActor private static var applyingShortcut = false

    @MainActor
    static func apply(_ view: NSTextView) {
            guard !applyingShortcut, let storage = view.textStorage else { return }
            let cursor = view.selectedRange().location
            guard cursor > 0, cursor <= storage.length else { return }
            let text = storage.string as NSString
            let paragraph = text.paragraphRange(for: NSRange(location: max(0, cursor - 1), length: 0))
            let head = text.substring(with: NSRange(location: paragraph.location, length: cursor - paragraph.location))
            let indent = head.prefix { $0 == "\t" || $0 == " " }.count
            let body = String(head.dropFirst(indent))
            applyingShortcut = true
            defer { applyingShortcut = false }
            let lineStart = paragraph.location + indent
            func replacePrefix(_ length: Int, with marker: String) {
                storage.replaceCharacters(in: NSRange(location: lineStart, length: length),
                                          with: NSAttributedString(string: marker, attributes: view.typingAttributes))
                view.setSelectedRange(NSRange(location: cursor - length + marker.utf16.count, length: 0))
            }
            if body == "- " || body == "* " { replacePrefix(2, with: "• "); return }
            if body == "[] " || body == "[ ] " { replacePrefix(body.utf16.count, with: "☐ "); return }
            if body == "# " || body == "## " || body == "### " {
                let size: CGFloat = body == "# " ? 21 : body == "## " ? 18 : 16
                storage.replaceCharacters(in: NSRange(location: lineStart, length: body.utf16.count), with: "")
                let font = NSFont.systemFont(ofSize: size, weight: .semibold)
                let range = (storage.string as NSString).paragraphRange(for: NSRange(location: lineStart, length: 0))
                if range.length > 0 { storage.addAttribute(.font, value: font, range: range) }
                view.typingAttributes[.font] = font
                view.setSelectedRange(NSRange(location: lineStart, length: 0))
                return
            }
            for (marker, apply) in [("**", "b"), ("~~", "s"), ("==", "h")] {
                guard body.hasSuffix(marker), body.count > marker.count * 2 else { continue }
                let inner = body.dropLast(marker.count)
                guard let open = inner.range(of: marker, options: .backwards) else { continue }
                let content = inner[open.upperBound...]
                guard !content.isEmpty, !content.hasPrefix(" ") else { continue }
                let openOffset = lineStart + body.utf16.distance(from: body.startIndex, to: open.lowerBound)
                let contentLength = String(content).utf16.count
                let closeStart = cursor - marker.utf16.count
                storage.replaceCharacters(in: NSRange(location: closeStart, length: marker.utf16.count), with: "")
                storage.replaceCharacters(in: NSRange(location: openOffset, length: marker.utf16.count), with: "")
                let styled = NSRange(location: openOffset, length: contentLength)
                if apply == "b" {
                    storage.enumerateAttribute(.font, in: styled) { value, sub, _ in
                        let font = (value as? NSFont) ?? PageTextView.bodyFont
                        storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: sub)
                    }
                } else if apply == "h" {
                    storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.32), range: styled)
                } else {
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: styled)
                }
                view.setSelectedRange(NSRange(location: NSMaxRange(styled), length: 0))
                return
            }
        }

}

/// The small formatting bar that shows while the page is being edited.
struct PageToolbar: View {
    let controller: PageController
    let theme: PlannerTheme
    var organizeTitle = String(localized: "整理成待办")
    var organizing = false
    /// A button that turns the page's lines into to-dos now; nil shows none (the Mac does it quietly when the page
    /// closes, by the date and time rules).
    var organize: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 2) {
            tool("bold", "加粗 ⌘B", controller.toggleBold)
            tool("italic", "斜体 ⌘I", controller.toggleItalic)
            tool("underline", "下划线 ⌘U", controller.toggleUnderline)
            tool("strikethrough", "删除线", controller.toggleStrike)
            divider
            tool("highlighter", "高亮 ==文字==", controller.highlight)
            colorDot(.systemRed, "标红")
            colorDot(NSColor(theme.accent), "标紫")
            tool("eraser", "恢复默认颜色") { controller.color(nil) }
            divider
            tool("textformat.size.larger", "标题（留在页面上，不变成待办）", controller.toggleHeading)
            tool("list.bullet", "项目符号", { controller.toggleLinePrefix("• ") })
            tool("checklist", "勾选框", { controller.toggleLinePrefix("☐ ") })
            tool("repeat", "设为每天重复（这一行）· 也可以写「每天…」或「… #每周一三」", controller.makeRepeating)
            tool("link", "链接 ⌘K", controller.link)
            tool("photo", "插入图片", controller.insertImage)
            if let organize {
            Spacer(minLength: 8)
            Button(action: organize) {
                HStack(spacing: 5) {
                    if organizing { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)) }
                    Text(organizeTitle).font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(theme.onAccent)
                .padding(.horizontal, 10).frame(height: 26)
                .background(theme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("⌘↵ · 普通行变成待办，缩进变子任务；标题、图片和长段落留在页面上")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(theme.surface.opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var divider: some View {
        Rectangle().fill(theme.line).frame(width: 1, height: 18).padding(.horizontal, 5)
    }

    private func tool(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.ink.opacity(0.8))
                .frame(width: 32, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(DesktopButtonStyle(theme: theme))
        .help(help.localized)
        .accessibilityLabel(help.localized)
    }

    private func colorDot(_ color: NSColor, _ help: String) -> some View {
        Button { controller.color(color) } label: {
            Circle().fill(Color(nsColor: color)).frame(width: 14, height: 14)
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(DesktopButtonStyle(theme: theme))
        .help(help.localized)
        .accessibilityLabel(help.localized)
    }
}
/// The few things one does to selected words, right where they are: shown next to a selection, gone when it goes.
struct SelectionBar: View {
    let controller: PageController
    let theme: PlannerTheme

    var body: some View {
        HStack(spacing: 1) {
            tool("bold", "加粗 ⌘B", controller.toggleBold)
            tool("italic", "斜体 ⌘I", controller.toggleItalic)
            tool("underline", "下划线 ⌘U", controller.toggleUnderline)
            tool("strikethrough", "删除线（待办划掉就是完成）", controller.toggleStrike)
            Rectangle().fill(theme.line).frame(width: 1, height: 16).padding(.horizontal, 4)
            tool("highlighter", "高亮", controller.highlight)
            dot(.systemRed, "标红")
            dot(NSColor(theme.accent), "标紫")
            tool("eraser", "恢复默认颜色") { controller.color(nil) }
            Rectangle().fill(theme.line).frame(width: 1, height: 16).padding(.horizontal, 4)
            tool("link", "链接 ⌘K", controller.link)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(theme.dark ? 0.45 : 0.14), radius: 10, y: 4)
        .padding(12)   // room for the shadow
    }

    private func tool(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(theme.ink.opacity(0.85))
                .frame(width: 30, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(DesktopButtonStyle(theme: theme))
        .help(help.localized)
        .accessibilityLabel(help.localized)
    }

    private func dot(_ color: NSColor, _ help: String) -> some View {
        Button { controller.color(color) } label: {
            Circle().fill(Color(nsColor: color)).frame(width: 13, height: 13)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(DesktopButtonStyle(theme: theme))
        .help(help.localized)
        .accessibilityLabel(help.localized)
    }
}
/// The address box that opens by the selection when linking.
struct LinkBox: View {
    @State var address: String
    let hasLink: Bool
    let theme: PlannerTheme
    /// The address to link to, or nil to remove the link.
    let done: (String?) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "link").font(.system(size: 12, weight: .medium)).foregroundStyle(theme.quiet)
            TextField("粘贴或输入网址", text: $address)
                .textFieldStyle(.plain).font(.system(size: 13)).frame(width: 260)
                .focused($focused)
                .onSubmit { if !address.trimmed.isEmpty { done(address) } }
            if hasLink {
                Button("移除") { done(nil) }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.quiet)
            }
            Button("链接") { done(address) }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(address.trimmed.isEmpty ? theme.quiet : theme.accent)
                .disabled(address.trimmed.isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .onAppear { focused = true }
    }
}
#endif
