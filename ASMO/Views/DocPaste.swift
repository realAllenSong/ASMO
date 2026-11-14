#if os(macOS)
import AppKit
import AVFoundation
import CryptoKit
import ImageIO
import LinkPresentation
import SwiftUI
import UniformTypeIdentifiers

/// What pasting or dropping does in the document, so anything can be put down the way it was meant:
/// a link on a line of its own becomes a preview card (inside a sentence it stays a link), a picture is shown,
/// a video becomes a poster that plays it, Markdown is drawn as what it describes, and text from another app keeps
/// its bold, italics and links but takes on the page's own fonts and colors.
@MainActor
enum DocPaste {
    /// Handles the pasteboard, or returns false to let the text view paste as usual.
    static func insert(from board: NSPasteboard, into view: NSTextView, body: [NSAttributedString.Key: Any]) -> Bool {
        let types = board.types ?? []
        // Files from Finder: pictures, videos, anything else as a link to the file.
        if let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            let text = NSMutableAttributedString()
            for file in files {
                text.append(piece(forFile: file, body: body))
            }
            put(text, in: view, body: body)
            return true
        }
        let string = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let singleURL = string.flatMap(webURL)
        // A copied picture (a screenshot, "Copy Image" in a browser).
        if string == nil || singleURL != nil, !types.contains(.rtf), !types.contains(.rtfd),
           let data = imageData(board), let picture = PageMarkdown.picture(data, name: "image") {
            put(picture, in: view, body: body)
            return true
        }
        if let url = singleURL {
            if lineIsEmpty(view) { linkCard(url, in: view, body: body) }
            else {
                view.insertText(NSAttributedString(string: url.absoluteString, attributes: body.merging([.link: url]) { $1 }),
                                replacementRange: view.selectedRange())
            }
            return true
        }
        guard let string, !string.isEmpty else { return false }
        if looksLikeMarkdown(string) {
            markdown(string, into: view, body: body)
            return true
        }
        // Rich text from another app: its structure, the page's look.
        for type in [NSPasteboard.PasteboardType.rtfd, .rtf, .html] where types.contains(type) {
            guard let data = board.data(forType: type) else { continue }
            let kind: NSAttributedString.DocumentType = type == .html ? .html : type == .rtfd ? .rtfd : .rtf
            if let rich = try? NSAttributedString(data: data, options: [.documentType: kind, .characterEncoding: String.Encoding.utf8.rawValue],
                                                  documentAttributes: nil) {
                view.insertText(restyled(rich, body: body), replacementRange: view.selectedRange())
                return true
            }
        }
        return false
    }

    // MARK: Pieces

    private static func put(_ text: NSAttributedString, in view: NSTextView, body: [NSAttributedString.Key: Any]) {
        let piece = NSMutableAttributedString(attributedString: text)
        // A picture or card sits on a line of its own.
        if !lineIsEmpty(view) { piece.insert(NSAttributedString(string: "\n", attributes: body), at: 0) }
        if !piece.string.hasSuffix("\n") { piece.append(NSAttributedString(string: "\n", attributes: body)) }
        view.insertText(piece, replacementRange: view.selectedRange())
    }

    private static func piece(forFile file: URL, body: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let type = UTType(filenameExtension: file.pathExtension)
        if type?.conforms(to: .image) == true, let data = try? Data(contentsOf: file),
           let picture = PageMarkdown.picture(data, name: file.lastPathComponent) {
            let text = NSMutableAttributedString(attributedString: picture)
            text.append(NSAttributedString(string: "\n", attributes: body))
            return text
        }
        if type?.conforms(to: .audiovisualContent) == true, let poster = videoPoster(file) {
            let text = NSMutableAttributedString(attributedString: poster)
            text.append(NSAttributedString(string: "\n", attributes: body))
            return text
        }
        // Any other file: its name, linked to it.
        return NSAttributedString(string: "📎 " + file.lastPathComponent + "\n", attributes: body.merging([.link: file]) { $1 })
    }

    private static func imageData(_ board: NSPasteboard) -> Data? {
        if let png = board.data(forType: .png) { return png }
        if let tiff = board.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }

    static func webURL(_ text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace), let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    private static func lineIsEmpty(_ view: NSTextView) -> Bool {
        guard let storage = view.textStorage else { return true }
        let string = storage.string as NSString
        let selection = view.selectedRange()
        let start = string.paragraphRange(for: NSRange(location: min(selection.location, string.length), length: 0))
        let end = string.paragraphRange(for: NSRange(location: min(NSMaxRange(selection), string.length), length: 0))
        // What stays on the line around the selection (which the paste replaces).
        let before = string.substring(with: NSRange(location: start.location, length: selection.location - start.location))
        let afterStart = min(NSMaxRange(selection), string.length)
        let after = string.substring(with: NSRange(location: afterStart, length: max(0, NSMaxRange(end) - afterStart)))
        return (before + after).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Text from elsewhere

    /// Keeps bold, italics, strikethrough, underline, links, headings (by size) and pictures; drops other fonts,
    /// colors and backgrounds, which would be unreadable on the other look.
    static func restyled(_ rich: NSAttributedString, body: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: rich.string, attributes: body)
        let base = (body[.font] as? NSFont) ?? .systemFont(ofSize: 15)
        let manager = NSFontManager.shared
        rich.enumerateAttributes(in: NSRange(location: 0, length: rich.length)) { attributes, range, _ in
            if let font = attributes[.font] as? NSFont {
                let traits = manager.traits(of: font)
                var mine = font.pointSize >= 22 ? NSFont.systemFont(ofSize: 19, weight: .semibold)
                    : font.pointSize >= 17.5 ? NSFont.systemFont(ofSize: 17, weight: .semibold) : base
                if font.isFixedPitch { mine = .monospacedSystemFont(ofSize: 13.5, weight: .regular) }
                if traits.contains(.boldFontMask) { mine = manager.convert(mine, toHaveTrait: .boldFontMask) }
                if traits.contains(.italicFontMask) {
                    mine = manager.convert(mine, toHaveTrait: .italicFontMask)
                    result.addAttribute(.obliqueness, value: 0.18, range: range)
                }
                result.addAttribute(.font, value: mine, range: range)
            }
            for key in [NSAttributedString.Key.link, .strikethroughStyle, .underlineStyle, .attachment] {
                if let value = attributes[key] { result.addAttribute(key, value: value, range: range) }
            }
        }
        // Web pages end with stray blank lines.
        while result.string.hasSuffix("\n\n") { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
        return result
    }

    static func looksLikeMarkdown(_ text: String) -> Bool {
        let block = #"(?m)^(#{1,6} \S|[-*+] \S|\d+[.)] \S|> |```|\|.+\|\s*$|- \[[ xX]\] )"#
        let inline = #"\*\*[^*\n]+\*\*|\[[^\]\n]+\]\([^)\s]+\)|`[^`\n]+`|~~[^~\n]+~~|!\[[^\]\n]*\]\([^)\s]+\)"#
        return text.range(of: block, options: .regularExpression) != nil || text.range(of: inline, options: .regularExpression) != nil
    }

    /// Markdown drawn as the page draws it: diagrams drawn, web pictures fetched. Anything that fails is pasted as text.
    private static func markdown(_ text: String, into view: NSTextView, body: [NSAttributedString.Key: Any]) {
        let selection = view.selectedRange()
        // Shown at once as text, then replaced by the drawn version (which can take a moment for diagrams and pictures).
        let plain = NSAttributedString(string: text, attributes: body)
        view.insertText(plain, replacementRange: selection)
        let placed = NSRange(location: selection.location, length: plain.length)
        weak var weakView = view
        Task { @MainActor in
            var sources = PageMarkdown.Sources()
            for source in (try? PageMarkdown.diagrams(in: text)) ?? [] {
                sources.diagrams[source] = try? await DiagramRenderer.shared.render(source)
            }
            for target in pictureTargets(text) {
                guard let url = URL(string: target), url.scheme?.hasPrefix("http") == true else {
                    let file = URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
                    if let data = try? Data(contentsOf: file) { sources.images[target] = data }
                    continue
                }
                var request = URLRequest(url: url)
                request.timeoutInterval = 8
                if let (data, _) = try? await URLSession.shared.data(for: request), NSImage(data: data) != nil { sources.images[target] = data }
            }
            guard let view = weakView, let storage = view.textStorage, NSMaxRange(placed) <= storage.length,
                  storage.attributedSubstring(from: placed).string == text,
                  let drawn = try? PageMarkdown.render(text, sources: sources) else { return }
            let page = NSMutableAttributedString(attributedString: drawn)
            // The page's ink, not the label color the renderer uses.
            DocCoordinator.neutralizeInk(page, ink: body[.foregroundColor] as? NSColor)
            if !page.string.hasSuffix("\n"), !text.hasSuffix("\n") {
                while page.string.hasSuffix("\n") { page.deleteCharacters(in: NSRange(location: page.length - 1, length: 1)) }
            }
            if view.shouldChangeText(in: placed, replacementString: page.string) {
                storage.replaceCharacters(in: placed, with: page)
                view.didChangeText()
            }
        }
    }

    private static func pictureTargets(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(<?([^)>\s]+)>?\)"#) else { return [] }
        let string = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: string.length)).map { string.substring(with: $0.range(at: 1)) }
    }

    // MARK: Link cards

    /// A card at once (the address), filled in with the page's title, summary and picture when they arrive.
    private static func linkCard(_ url: URL, in view: NSTextView, body: [NSAttributedString.Key: Any]) {
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let host = url.host(percentEncoded: false)?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
        guard let first = linkCardPicture(url: url, title: host, summary: url.absoluteString, dark: dark) else {
            view.insertText(NSAttributedString(string: url.absoluteString, attributes: body.merging([.link: url]) { $1 }),
                            replacementRange: view.selectedRange())
            return
        }
        let placeholder = first.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        put(first, in: view, body: body)
        weak var weakView = view
        Task { @MainActor in
            let provider = LPMetadataProvider()
            provider.timeout = 10
            guard let metadata = try? await provider.startFetchingMetadata(for: url) else { return }
            // Kept next to ASMO's data, so the card can be drawn again (the other look) without the network.
            if let image = await load(metadata.imageProvider) { save(image, as: cacheFile(url, "image")) }
            if let icon = await load(metadata.iconProvider) { save(icon, as: cacheFile(url, "icon")) }
            let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? host
            let summary = (metadata.value(forKey: "summary") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            guard let view = weakView, let storage = view.textStorage, let placeholder,
                  let card = linkCardPicture(url: url, title: title, summary: summary, dark: dark) else { return }
            var at: NSRange?
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                if (value as? NSTextAttachment) === placeholder { at = range; stop.pointee = true }
            }
            guard let at, view.shouldChangeText(in: at, replacementString: card.string) else { return }
            storage.replaceCharacters(in: at, with: card)
            view.didChangeText()
        }
    }

    /// A link card for one look, from what is known about the page (pictures from the cache).
    static func linkCardPicture(url: URL, title: String, summary: String?, dark: Bool) -> NSAttributedString? {
        let host = url.host(percentEncoded: false)?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
        let oneLine = { (text: String) in text.replacingOccurrences(of: "\n", with: " ") }
        let note = PageMarkdown.linkMark + url.absoluteString + "\n" + oneLine(title) + "\n" + oneLine(summary ?? "") + "\n" + (dark ? "dark" : "light")
        return cardPicture(LinkCardPicture(title: title, summary: summary, site: host, image: NSImage(contentsOf: cacheFile(url, "image")),
                                           icon: NSImage(contentsOf: cacheFile(url, "icon")), dark: dark),
                           note: note, url: url, body: [:])
    }

    /// Link cards drawn for the other look are drawn again for this one (light ↔ dark), when a page is loaded.
    static func redrawCards(in text: NSMutableAttributedString, dark: Bool) {
        let look = dark ? "dark" : "light"
        var replacements: [(NSRange, NSAttributedString)] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment, let card = PageMarkdown.cardTarget(attachment), !card.video,
                  card.look != look, let url = URL(string: card.url),
                  let drawn = linkCardPicture(url: url, title: card.title, summary: card.summary, dark: dark) else { return }
            let fresh = NSMutableAttributedString(attributedString: drawn)
            // Keeps the line's own attributes (note marker, paragraph) around the new picture.
            let around = text.attributes(at: range.location, effectiveRange: nil)
            for (key, value) in around where key != .attachment { fresh.addAttribute(key, value: value, range: NSRange(location: 0, length: fresh.length)) }
            replacements.append((range, fresh))
        }
        for (range, fresh) in replacements.reversed() { text.replaceCharacters(in: range, with: fresh) }
    }

    private static func cacheFile(_ url: URL, _ kind: String) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return AppPaths.support.appendingPathComponent("Media/Links", isDirectory: true).appendingPathComponent("\(digest)-\(kind).png")
    }

    private static func save(_ image: NSImage, as file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        // Small enough for a card: at most 640 pixels across.
        let scale = min(1, 640 / max(CGFloat(rep.pixelsWide), 1))
        let size = NSSize(width: CGFloat(rep.pixelsWide) * scale, height: CGFloat(rep.pixelsHigh) * scale)
        let resized = NSImage(size: size)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        resized.unlockFocus()
        if let data = resized.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]) {
            try? data.write(to: file)
        }
    }

    private static func load(_ provider: NSItemProvider?) async -> NSImage? {
        guard let provider, provider.canLoadObject(ofClass: NSImage.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                continuation.resume(returning: object as? NSImage)
            }
        }
    }

    // MARK: Videos

    /// A frame of the video with a play mark; the file is kept with ASMO's data so the poster always plays it.
    private static func videoPoster(_ file: URL) -> NSAttributedString? {
        let kept = keep(file) ?? file
        let asset = AVURLAsset(url: kept)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let frame = (try? generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)).map {
            NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
        }
        let seconds = CMTimeGetSeconds(asset.duration)
        let length = seconds.isFinite && seconds > 0 ? String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) : nil
        return cardPicture(VideoPosterPicture(frame: frame, name: file.deletingPathExtension().lastPathComponent, length: length),
                           note: PageMarkdown.videoMark + kept.absoluteString + "\n" + file.lastPathComponent, url: kept, body: [:])
    }

    /// Copies a pasted file into ~/Library/Application Support/ASMO/Media (the original may be moved or deleted).
    private static func keep(_ file: URL) -> URL? {
        let folder = AppPaths.support.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if file.path.hasPrefix(folder.path) { return file }
        let target = folder.appendingPathComponent(UUID().uuidString.prefix(8) + "-" + file.lastPathComponent)
        return (try? FileManager.default.copyItem(at: file, to: target)) != nil ? target : nil
    }

    // MARK: Drawing a card as a picture

    /// Draws a card at twice the pixels and makes it a page picture that remembers where it points.
    private static func cardPicture<Card: View>(_ card: Card, note: String, url: URL, body: [NSAttributedString.Key: Any]) -> NSAttributedString? {
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144,
                                                        kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: note]] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let picture = PageMarkdown.picture(encoded as Data, name: "card", description: note) else { return nil }
        let text = NSMutableAttributedString(attributedString: picture)
        text.addAttribute(.link, value: url, range: NSRange(location: 0, length: text.length))
        return text
    }
}

/// A web page as a card: title, a line about it, the site, and its picture on the right.
private struct LinkCardPicture: View {
    let title: String
    let summary: String?
    let site: String
    let image: NSImage?
    let icon: NSImage?
    let dark: Bool

    var body: some View {
        let ink = dark ? Color(white: 0.93) : Color(white: 0.12)
        let quiet = dark ? Color(white: 0.62) : Color(white: 0.45)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(ink).lineLimit(2)
                if let summary {
                    Text(summary).font(.system(size: 12)).foregroundStyle(quiet).lineLimit(2)
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    if let icon { Image(nsImage: icon).resizable().scaledToFit().frame(width: 14, height: 14) }
                    else { Image(systemName: "link").font(.system(size: 11, weight: .semibold)).foregroundStyle(quiet) }
                    Text(site).font(.system(size: 11.5, weight: .medium)).foregroundStyle(quiet).lineLimit(1)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let image {
                Image(nsImage: image).resizable().scaledToFill().frame(width: 168, height: 108).clipped()
            }
        }
        .frame(width: 520, height: 108)
        .background(dark ? Color(white: 0.17) : Color(white: 0.985))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1)))
        .padding(1)
    }
}

/// A video as its first frame with a play mark, its name and length along the bottom.
private struct VideoPosterPicture: View {
    let frame: NSImage?
    let name: String
    let length: String?

    var body: some View {
        let ratio = frame.map { $0.size.width / max($0.size.height, 1) } ?? 16 / 9
        let width: CGFloat = ratio >= 1 ? 480 : 300
        ZStack {
            if let frame { Image(nsImage: frame).resizable().scaledToFill() } else { Color(white: 0.15) }
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            Image(systemName: "play.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 54, height: 54).background(.black.opacity(0.45), in: Circle())
            VStack {
                Spacer()
                HStack {
                    Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer()
                    if let length { Text(length).font(.system(size: 11.5, weight: .medium).monospacedDigit()) }
                }
                .foregroundStyle(.white).padding(.horizontal, 12).padding(.bottom, 9)
            }
        }
        .frame(width: width, height: min(width / ratio, 360))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
#endif
