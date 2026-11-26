#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// A picture, diagram, formula or table from a note, shown large in its own window: zoom with the trackpad, the
/// buttons or ⌘+ / ⌘− / ⌘0 (fit) / ⌘1 (actual size), drag to move around, ⌘C to copy, Esc to close.
@MainActor
final class PictureViewer: NSObject, NSWindowDelegate {
    private static var open: [PictureViewer] = []

    private let window: NSWindow
    private let scroll = NSScrollView()
    private let imageView = NSImageView()
    private let image: NSImage
    private let file: URL?
    private var keys: Any?

    static func show(_ image: NSImage, title: String, file: URL?, over parent: NSWindow?) {
        let viewer = PictureViewer(image: image, title: title, file: file, over: parent)
        open.append(viewer)
        viewer.window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { viewer.fit() }
    }

    private init(image: NSImage, title: String, file: URL?, over parent: NSWindow?) {
        self.image = image
        self.file = file
        let screen = (parent?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let bar: CGFloat = 44
        let width = min(max(image.size.width + 40, 420), screen.width * 0.8)
        let height = min(max(image.size.height + 40 + bar, 320), screen.height * 0.85)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 260)
        window.delegate = self
        if let parent { window.setFrameOrigin(NSPoint(x: parent.frame.midX - width / 2, y: parent.frame.midY - height / 2)) } else { window.center() }

        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = NSRect(origin: .zero, size: image.size)
        let clip = CenteringClipView()
        scroll.contentView = clip
        scroll.documentView = imageView
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 16
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = .underPageBackgroundColor
        scroll.drawsBackground = true

        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: self, action: action)
            b.bezelStyle = .texturedRounded
            b.toolTip = tip
            return b
        }
        var buttons = [
            button("minus.magnifyingglass", String(localized: "缩小 ⌘−"), #selector(zoomOut)),
            button("arrow.up.left.and.down.right.and.arrow.up.right.and.down.left", String(localized: "适合窗口 ⌘0"), #selector(fitAction)),
            button("1.magnifyingglass", String(localized: "原始大小 ⌘1"), #selector(actualSize)),
            button("plus.magnifyingglass", String(localized: "放大 ⌘+"), #selector(zoomIn)),
            button("doc.on.doc", String(localized: "拷贝图片 ⌘C"), #selector(copyImage)),
            button("square.and.arrow.down", String(localized: "存储为 PNG…"), #selector(saveImage)),
        ]
        if file != nil { buttons.append(button("eye", String(localized: "用「预览」打开"), #selector(openInPreview))) }
        let row = NSStackView(views: buttons)
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        let stack = NSStackView(views: [scroll, row])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .centerX
        scroll.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = stack
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])

        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let command = event.modifierFlags.contains(.command)
            switch (command, event.charactersIgnoringModifiers ?? "") {
            case (true, "="), (true, "+"): self.zoomIn(); return nil
            case (true, "-"): self.zoomOut(); return nil
            case (true, "0"): self.fit(); return nil
            case (true, "1"): self.actualSize(); return nil
            case (true, "c"): self.copyImage(); return nil
            case (false, "\u{1b}"): self.window.close(); return nil
            default: return event
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let keys { NSEvent.removeMonitor(keys) }
        PictureViewer.open.removeAll { $0 === self }
    }

    @objc private func zoomIn() { scroll.animator().magnification = min(scroll.maxMagnification, scroll.magnification * 1.25) }
    @objc private func zoomOut() { scroll.animator().magnification = max(scroll.minMagnification, scroll.magnification / 1.25) }
    @objc private func actualSize() { scroll.animator().magnification = 1 }
    @objc private func fitAction() { fit() }

    func fit() {
        let visible = scroll.contentSize
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(visible.width / image.size.width, visible.height / image.size.height) * 0.96
        scroll.magnification = min(max(scale, scroll.minMagnification), 4)
    }

    @objc private func copyImage() { PictureViewer.copy(image) }
    @objc private func saveImage() { PictureViewer.save(image, suggested: window.title, from: window) }
    @objc private func openInPreview() { if let file { PictureViewer.openInPreview(file) } }

    // MARK: Shared actions (the note's menu uses them too)

    /// The picture as PNG, drawn at twice its size (diagrams, formulas and tables are drawn, so stay sharp).
    static func png(_ image: NSImage) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    static func copy(_ image: NSImage) {
        let board = NSPasteboard.general
        board.clearContents()
        if let png = png(image) { board.setData(png, forType: .png) }
        board.writeObjects([image])
    }

    static func save(_ image: NSImage, suggested: String, from window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = (suggested.isEmpty ? String(localized: "图片") : suggested)
            .replacingOccurrences(of: "/", with: "-") + ".png"
        let write = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url, let data = png(image) else { return }
            try? data.write(to: url)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: write) } else { write(panel.runModal()) }
    }

    static func openInPreview(_ file: URL) {
        guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
            NSWorkspace.shared.open(file); return
        }
        NSWorkspace.shared.open([file], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Keeps a picture smaller than the window in the middle of it.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

// MARK: The note's menu on a picture

extension NoteTextView {
    func viewerTitle(_ picture: DrawnPicture) -> String {
        if let file = picture.file { return NotesLibrary.title(of: file) }
        switch picture.kind {
        case "math": return String(localized: "公式")
        case "mermaid": return String(localized: "图表")
        case "table": return String(localized: "表格")
        default: return String(localized: "图片")
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = picture(at: point) else { return super.menu(for: event) }
        let picture = hit.picture
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, tag: Int = 0, to target: NSMenu? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = hit.key
            item.tag = tag
            (target ?? menu).addItem(item)
        }
        if picture.kind == "note" || picture.kind == "drawing" {
            add(String(localized: "打开"), #selector(openEmbedded(_:)))
            if picture.kind == "note" { return menu }
            menu.addItem(.separator())
        }
        add(String(localized: "查看大图"), #selector(viewPicture(_:)))
        add(String(localized: "拷贝图片"), #selector(copyPicture(_:)))
        add(String(localized: "存储为 PNG…"), #selector(savePicture(_:)))
        if picture.kind == "picture", picture.file != nil {
            menu.addItem(.separator())
            add(String(localized: "在访达中显示"), #selector(revealPicture(_:)))
            add(String(localized: "用「预览」打开"), #selector(previewPicture(_:)))
            menu.addItem(.separator())
            let sizes = NSMenu()
            add(String(localized: "小（240）"), #selector(resizePicture(_:)), tag: 240, to: sizes)
            add(String(localized: "中（400）"), #selector(resizePicture(_:)), tag: 400, to: sizes)
            add(String(localized: "适合一栏"), #selector(resizePicture(_:)), tag: 0, to: sizes)
            let item = NSMenuItem(title: String(localized: "大小"), action: nil, keyEquivalent: "")
            item.submenu = sizes
            menu.addItem(item)
        }
        if ["math", "mermaid", "table"].contains(picture.kind), picture.source != nil {
            menu.addItem(.separator())
            add(String(localized: "编辑源码"), #selector(editSource(_:)))
            add(String(localized: "拷贝源码"), #selector(copySource(_:)))
        }
        return menu
    }

    private func hit(_ sender: Any?) -> DrawnPicture? {
        ((sender as? NSMenuItem)?.representedObject as? Int).flatMap { drawn[$0] }
    }

    @objc func viewPicture(_ sender: Any?) {
        guard let picture = hit(sender) else { return }
        PictureViewer.show(picture.image, title: viewerTitle(picture), file: picture.kind == "picture" ? picture.file : nil, over: window)
    }

    @objc func copyPicture(_ sender: Any?) { if let picture = hit(sender) { PictureViewer.copy(picture.image) } }
    @objc func savePicture(_ sender: Any?) { if let picture = hit(sender) { PictureViewer.save(picture.image, suggested: viewerTitle(picture), from: window) } }
    @objc func revealPicture(_ sender: Any?) { if let file = hit(sender)?.file { NSWorkspace.shared.activateFileViewerSelecting([file]) } }
    @objc func previewPicture(_ sender: Any?) { if let file = hit(sender)?.file { PictureViewer.openInPreview(file) } }

    @objc func openEmbedded(_ sender: Any?) {
        guard let file = hit(sender)?.file else { return }
        coordinator?.openLink(NotesLibrary.title(of: file))
    }

    @objc func editSource(_ sender: Any?) {
        guard let source = hit(sender)?.source, source.location <= string.utf16.count else { return }
        engaged = true
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: source.location, length: 0))
        scrollRangeToVisible(NSRange(location: source.location, length: 0))
    }

    @objc func copySource(_ sender: Any?) {
        guard let source = hit(sender)?.source, NSMaxRange(source) <= string.utf16.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((string as NSString).substring(with: source), forType: .string)
    }

    /// "![[a.png]]" ⇄ "![[a.png|240]]" (and "![alt|240](a.png)"): the width the picture is shown at, Obsidian's way.
    @objc func resizePicture(_ sender: Any?) {
        guard let source = hit(sender)?.source, NSMaxRange(source) <= string.utf16.count else { return }
        let width = (sender as? NSMenuItem)?.tag ?? 0
        let line = (string as NSString).substring(with: source)
        let suffix = width > 0 ? "|\(width)" : ""
        var changed = line.replacingOccurrences(of: #"!\[\[([^\]|]+)(\|[^\]]*)?\]\]"#, with: "![[$1\(suffix)]]", options: .regularExpression)
        if changed == line {
            changed = line.replacingOccurrences(of: #"!\[([^\]|]*)(\|\d+)?\]\("#, with: "![$1\(suffix)](", options: .regularExpression)
        }
        guard changed != line, shouldChangeText(in: source, replacementString: changed) else { return }
        textStorage?.replaceCharacters(in: source, with: changed)
        didChangeText()
    }
}
#endif
