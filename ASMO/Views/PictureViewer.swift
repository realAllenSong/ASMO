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

// MARK: Tapped open, in place

/// A picture opened the way a phone opens one: over the window, the rest dimmed. Pinch or ⌘+ / ⌘− to zoom, drag
/// to move, double-click to switch between fitting and close up; the bar below copies, saves, opens it in Preview or
/// edits its source. A click beside the picture, or Esc, closes it.
@MainActor
final class PictureLightbox: NSView {
    private let image: NSImage
    private let file: URL?
    private let title: String
    private let edit: (() -> Void)?
    private let scroll = NSScrollView()
    private let picture = PanningImageView()
    private weak var returnTo: NSResponder?
    private var fitScale: CGFloat = 1

    static func show(_ image: NSImage, title: String, file: URL?, in window: NSWindow?, from responder: NSResponder?, edit: (() -> Void)?) {
        guard let content = window?.contentView, image.size.width > 0 else { return }
        content.subviews.compactMap { $0 as? PictureLightbox }.forEach { $0.removeFromSuperview() }
        let box = PictureLightbox(image: image, title: title, file: file, edit: edit)
        box.returnTo = responder
        box.frame = content.bounds
        box.autoresizingMask = [.width, .height]
        content.addSubview(box)
        box.window?.makeFirstResponder(box)
        box.layoutPicture()
        // From the size it had on the page to the size that fits, the dimming fading in.
        let start = box.scroll.magnification
        box.alphaValue = 0
        box.scroll.magnification = max(box.scroll.minMagnification, start * 0.85)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            box.animator().alphaValue = 1
            box.scroll.animator().magnification = start
        }
    }

    private init(image: NSImage, title: String, file: URL?, edit: (() -> Void)?) {
        self.image = image
        self.file = file
        self.title = title
        self.edit = edit
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.84).cgColor

        picture.image = image
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.frame = NSRect(origin: .zero, size: image.size)
        picture.toggle = { [weak self] in self?.toggleZoom() }
        let clip = LightboxClipView()
        clip.drawsBackground = false
        clip.onBackground = { [weak self] in self?.close() }
        scroll.contentView = clip
        scroll.documentView = picture
        scroll.drawsBackground = false
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 16
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        addSubview(scroll)

        let bar = NSVisualEffectView()
        bar.material = .hudWindow
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.appearance = NSAppearance(named: .darkAqua)
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 12
        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: self, action: action)
            b.isBordered = false
            b.contentTintColor = .white
            b.toolTip = tip
            b.setAccessibilityLabel(tip)
            b.widthAnchor.constraint(equalToConstant: 34).isActive = true
            b.heightAnchor.constraint(equalToConstant: 30).isActive = true
            return b
        }
        var buttons = [
            button("minus.magnifyingglass", String(localized: "缩小 ⌘−"), #selector(zoomOut)),
            button("arrow.up.left.and.arrow.down.right", String(localized: "适合屏幕 ⌘0"), #selector(fit)),
            button("1.magnifyingglass", String(localized: "原始大小 ⌘1"), #selector(actualSize)),
            button("plus.magnifyingglass", String(localized: "放大 ⌘+"), #selector(zoomIn)),
            button("doc.on.doc", String(localized: "拷贝图片 ⌘C"), #selector(copyImage)),
            button("square.and.arrow.down", String(localized: "存储为 PNG…"), #selector(saveImage)),
        ]
        if file != nil { buttons.append(button("eye", String(localized: "用「预览」打开"), #selector(openInPreview))) }
        if edit != nil { buttons.append(button("chevron.left.forwardslash.chevron.right", String(localized: "编辑源码"), #selector(editSource))) }
        let row = NSStackView(views: buttons)
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        let close = button("xmark", String(localized: "关闭 Esc"), #selector(closeAction))
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(close)
        let name = NSTextField(labelWithString: title)
        name.textColor = NSColor.white.withAlphaComponent(0.8)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.translatesAutoresizingMaskIntoConstraints = false
        addSubview(name)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor), row.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            row.topAnchor.constraint(equalTo: bar.topAnchor), row.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bar.centerXAnchor.constraint(equalTo: centerXAnchor), bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            close.topAnchor.constraint(equalTo: topAnchor, constant: 16), close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            name.centerYAnchor.constraint(equalTo: close.centerYAnchor), name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        layoutPicture()
    }

    /// The picture fills the window above the bar; it opens fitted (a small one, like a formula, up to three
    /// times its size).
    func layoutPicture() {
        let area = bounds.insetBy(dx: 24, dy: 0)
        let frame = NSRect(x: area.minX, y: 76, width: area.width, height: max(100, bounds.height - 76 - 56))
        guard scroll.frame != frame else { return }
        let first = scroll.frame == .zero
        scroll.frame = frame
        fitScale = min(frame.width / image.size.width, frame.height / image.size.height) * 0.94
        if first { scroll.magnification = min(fitScale, 3) }
    }

    // Anything on the page under it is out of reach while it's open.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) ?? self }
    override func mouseDown(with event: NSEvent) { close() }
    override func scrollWheel(with event: NSEvent) { scroll.scrollWheel(with: event) }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch (command, event.charactersIgnoringModifiers ?? "") {
        case (true, "="), (true, "+"): zoomIn()
        case (true, "-"): zoomOut()
        case (true, "0"): fit()
        case (true, "1"): actualSize()
        case (true, "c"): copyImage()
        case (false, "\u{1b}"), (false, " "): close()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { close() }

    private func toggleZoom() {
        let fitted = min(fitScale, 3)
        scroll.animator().magnification = abs(scroll.magnification - fitted) < 0.05 ? max(fitted * 2.5, 1) : fitted
    }

    @objc private func zoomIn() { scroll.animator().magnification = min(scroll.maxMagnification, scroll.magnification * 1.25) }
    @objc private func zoomOut() { scroll.animator().magnification = max(scroll.minMagnification, scroll.magnification / 1.25) }
    @objc private func actualSize() { scroll.animator().magnification = 1 }
    @objc private func fit() { scroll.animator().magnification = min(fitScale, 3) }
    @objc private func copyImage() { PictureViewer.copy(image) }
    @objc private func saveImage() { PictureViewer.save(image, suggested: title, from: window) }
    @objc private func openInPreview() { if let file { PictureViewer.openInPreview(file) } }
    @objc private func editSource() { let edit = edit; close(); edit?() }
    @objc private func closeAction() { close() }

    func close() {
        let back = returnTo
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.removeFromSuperview()
                if let back = back as? NSView { back.window?.makeFirstResponder(back) }
            }
        })
    }
}

/// The picture in the light box: dragged to move around it, double-clicked to zoom.
private final class PanningImageView: NSImageView {
    var toggle: (() -> Void)?
    private var last: NSPoint?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { toggle?(); return }
        last = event.locationInWindow
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last, let clip = enclosingScrollView?.contentView else { return }
        let now = event.locationInWindow
        let scale = enclosingScrollView?.magnification ?? 1
        var origin = clip.bounds.origin
        origin.x -= (now.x - last.x) / scale
        origin.y -= (now.y - last.y) / scale * (isFlipped ? -1 : 1)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
        self.last = now
    }

    override func mouseUp(with event: NSEvent) {
        if last != nil { NSCursor.pop() }
        last = nil
    }
}

/// Keeps the picture centred; a click beside the picture closes the light box.
private final class LightboxClipView: NSClipView {
    var onBackground: (() -> Void)?

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }

    override func mouseDown(with event: NSEvent) { onBackground?() }
}

// MARK: The bar over a picture

import SwiftUI

/// Over the picture under the pointer: view it large, copy it, edit its source (diagrams, formulas, tables) and the
/// rest of its menu.
struct PictureHoverBar: View {
    let editable: Bool
    let dark: Bool
    let action: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            button("arrow.up.left.and.arrow.down.right", String(localized: "查看大图（双击也可以）"), "view")
            button("doc.on.doc", String(localized: "拷贝图片"), "copy")
            if editable { button("chevron.left.forwardslash.chevron.right", String(localized: "编辑源码"), "edit") }
            button("ellipsis", String(localized: "更多"), "more")
        }
        .padding(3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    private func button(_ symbol: String, _ help: String, _ name: String) -> some View {
        Button { action(name) } label: {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

extension NoteTextView {
    func showHoverBar(for key: Int) {
        guard let picture = drawn[key] else { hideHoverBar(); return }
        hideHoverBar()
        let editable = ["math", "mermaid", "table"].contains(picture.kind) && picture.source != nil
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let host = NSHostingView(rootView: PictureHoverBar(editable: editable, dark: dark) { [weak self] name in
            self?.hoverAction(name, key: key)
        })
        let size = host.fittingSize
        // Top right of the picture, inside it (small pictures: just above).
        let rect = picture.rect
        let y = rect.height > size.height + 20 ? rect.minY + 8 : rect.minY - size.height - 4
        host.frame = NSRect(x: max(rect.minX, rect.maxX - size.width - 8), y: y, width: size.width, height: size.height)
        addSubview(host)
        hoverBar = host
        hoverKey = key
    }

    func hideHoverBar() {
        hoverBar?.removeFromSuperview()
        hoverBar = nil
        hoverKey = nil
    }

    private func hoverAction(_ name: String, key: Int) {
        let item = NSMenuItem()
        item.representedObject = key
        switch name {
        case "view": viewPicture(item)
        case "copy": copyPicture(item)
        case "edit": hideHoverBar(); editSource(item)
        default:
            guard let picture = drawn[key], let bar = hoverBar,
                  let event = NSEvent.mouseEvent(with: .rightMouseDown, location: convert(NSPoint(x: picture.rect.midX, y: picture.rect.midY), to: nil),
                                                 modifierFlags: [], timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1),
                  let menu = menu(for: event) else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: bar.frame.maxX - 20, y: bar.frame.maxY + 2), in: self)
        }
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
        guard let key = (sender as? NSMenuItem)?.representedObject as? Int else { return }
        openLightbox(key)
    }

    /// The picture opened in place, over the window (a click on a picture, diagram or formula).
    func openLightbox(_ key: Int) {
        guard let picture = drawn[key] else { return }
        hideHoverBar()
        let editable = ["math", "mermaid", "table"].contains(picture.kind) && picture.source != nil
        PictureLightbox.show(picture.image, title: viewerTitle(picture), file: picture.kind == "picture" ? picture.file : nil,
                             in: window, from: self, edit: editable ? { [weak self] in
                                 let item = NSMenuItem(); item.representedObject = key; self?.editSource(item)
                             } : nil)
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
