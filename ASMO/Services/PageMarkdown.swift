#if os(macOS)
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Markdown ⇄ a day's page. Agents write Markdown; the page keeps it as the same rich text the editor makes by hand
/// (bullets as "• ", checkboxes as "☐ ", headings by size, tables as text tables, pictures as attachments), so what
/// an agent wrote can be edited in the app and read back as Markdown.
enum PageMarkdown {
    struct Failure: Error { let message: String }

    /// Pictures a piece of Markdown refers to, by the target written in `![…](target)`, and drawn diagrams by source.
    struct Sources {
        var images: [String: Data] = [:]
        var diagrams: [String: Data] = [:]
    }

    /// One part of a page an agent can replace or remove: a heading, a paragraph, a whole list, a table, a code
    /// block, a picture or a diagram.
    struct Block {
        var id: String
        var range: NSRange
        var markdown: String
    }

    static let bodySize: CGFloat = 14.5
    /// How wide a picture or diagram is shown at most, in points.
    static let pictureWidth: CGFloat = 640
    /// A diagram's source travels inside its picture (the PNG's description), so it can be read back and redrawn.
    static let diagramMark = "asmo-mermaid:"
    static let imageScheme = "asmo-image:"
    /// Holds an empty table cell or code line open (the editor drops paragraphs that are only whitespace, and a
    /// zero-width space counts as whitespace; a word joiner doesn't).
    private static let emptyCell = "\u{2060}"
    private static let rule = "— — —"
    private static let headingSizes: [CGFloat] = [21, 18, 16]

    private static var paragraph: NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 4
        style.defaultTabInterval = 26
        style.tabStops = []
        return style
    }

    static var body: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: bodySize), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }

    private static var codeFont: NSFont { .monospacedSystemFont(ofSize: 13, weight: .regular) }

    // MARK: Markdown → page

    private struct Run {
        var text: String
        var inline: InlinePresentationIntent
        var link: URL?
        var image: URL?
    }

    private struct Piece {
        var intent: PresentationIntent?
        var runs: [Run]
        var text: String { runs.map(\.text).joined() }
    }

    private static func pieces(_ markdown: String) throws -> [Piece] {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: true, interpretedSyntax: .full,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            throw Failure(message: "The Markdown could not be read.")
        }
        var result: [Piece] = []
        for run in parsed.runs {
            let item = Run(text: String(parsed[run.range].characters), inline: run.inlinePresentationIntent ?? [],
                           link: run.link, image: run.imageURL)
            if let last = result.indices.last, result[last].intent == run.presentationIntent { result[last].runs.append(item) }
            else { result.append(Piece(intent: run.presentationIntent, runs: [item])) }
        }
        return result
    }

    /// The mermaid diagrams in a piece of Markdown, to be drawn before it is rendered.
    static func diagrams(in markdown: String) throws -> [String] {
        try pieces(markdown).compactMap { piece in
            guard case .codeBlock(let language)? = piece.intent?.components.first?.kind,
                  language?.lowercased() == "mermaid" else { return nil }
            return piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func render(_ markdown: String, sources: Sources) throws -> NSAttributedString {
        let all = try pieces(markdown)
        let output = NSMutableAttributedString()
        var startedItems = Set<Int>()
        var index = 0
        while index < all.count {
            let piece = all[index]
            let components = piece.intent?.components ?? []
            // A table: all its cells come as consecutive pieces.
            if let table = components.first(where: { if case .table = $0.kind { true } else { false } }) {
                var cells: [Piece] = []
                while index < all.count, all[index].intent?.components.contains(where: { $0.identity == table.identity }) == true {
                    cells.append(all[index])
                    index += 1
                }
                output.append(try renderTable(cells, sources: sources))
                continue
            }
            index += 1
            guard let first = components.first else {
                output.append(try inline(piece.runs, base: body, sources: sources))
                output.append(NSAttributedString(string: "\n", attributes: body))
                continue
            }
            switch first.kind {
            case .header(let level):
                var attributes = body
                attributes[.font] = NSFont.systemFont(ofSize: headingSizes[min(max(level, 1), 3) - 1], weight: .semibold)
                let style = paragraph
                style.paragraphSpacingBefore = output.length == 0 ? 0 : 8
                attributes[.paragraphStyle] = style
                output.append(try inline(piece.runs, base: attributes, sources: sources, emphasis: false))
                output.append(NSAttributedString(string: "\n", attributes: attributes))
            case .codeBlock(let language):
                let source = piece.text.trimmingCharacters(in: .newlines)
                if language?.lowercased() == "mermaid" {
                    let key = source.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let png = sources.diagrams[key], let picture = picture(png, name: "diagram.png") else {
                        throw Failure(message: "A mermaid diagram could not be drawn.")
                    }
                    output.append(picture)
                    output.append(NSAttributedString(string: "\n", attributes: body))
                } else {
                    output.append(renderCode(source))
                }
            case .thematicBreak:
                output.append(NSAttributedString(string: rule + "\n", attributes: body.merging([.foregroundColor: NSColor.tertiaryLabelColor]) { $1 }))
            default:
                // A paragraph: on its own, in a list (nested by tabs), or in a quote.
                let items = components.filter { if case .listItem = $0.kind { true } else { false } }
                var runs = piece.runs
                var prefix = ""
                if let item = items.first, let at = components.firstIndex(where: { $0.identity == item.identity }) {
                    prefix = String(repeating: "\t", count: items.count - 1)
                    if startedItems.insert(item.identity).inserted {
                        var marker = "• "
                        if at + 1 < components.count, case .orderedList = components[at + 1].kind, case .listItem(let ordinal) = item.kind {
                            marker = "\(ordinal). "
                        }
                        if let text = runs.first?.text {
                            for (box, glyph) in [("[ ] ", "☐ "), ("[x] ", "☑ "), ("[X] ", "☑ ")] where text.hasPrefix(box) {
                                marker = glyph
                                runs[0].text = String(text.dropFirst(box.count))
                            }
                        }
                        prefix += marker
                    } else {
                        prefix += "\t"
                    }
                }
                if components.contains(where: { if case .blockQuote = $0.kind { true } else { false } }) { prefix += "> " }
                output.append(NSAttributedString(string: prefix, attributes: body))
                output.append(try inline(runs, base: body, sources: sources))
                output.append(NSAttributedString(string: "\n", attributes: body))
            }
        }
        return output
    }

    private static func inline(_ runs: [Run], base: [NSAttributedString.Key: Any], sources: Sources,
                               emphasis: Bool = true) throws -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for run in runs {
            if let image = run.image {
                let target = image.absoluteString.removingPercentEncoding ?? image.absoluteString
                guard let data = sources.images[target] ?? sources.images[image.absoluteString],
                      let picture = picture(data, name: image.lastPathComponent.isEmpty ? "image" : image.lastPathComponent) else {
                    throw Failure(message: "The picture \"\(target)\" was not sent or is not an image.")
                }
                result.append(picture)
                continue
            }
            var attributes = base
            var font = base[.font] as? NSFont ?? .systemFont(ofSize: bodySize)
            if run.inline.contains(.code) {
                font = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
            } else if emphasis {
                if run.inline.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if run.inline.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            }
            attributes[.font] = font
            if run.inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            let text = run.inline.contains(.lineBreak) ? "\u{2028}" : run.inline.contains(.softBreak) ? " " : run.text
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }

    private static func block(in table: NSTextTable, row: Int, column: Int, last: Bool = true) -> NSMutableParagraphStyle {
        let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
        // A little air above and below the whole table.
        if row == 0 { cell.setWidth(8, type: .absoluteValueType, for: .margin, edge: .minY) }
        if last { cell.setWidth(8, type: .absoluteValueType, for: .margin, edge: .maxY) }
        cell.setBorderColor(NSColor(white: 0.62, alpha: 1))
        cell.setWidth(0.5, type: .absoluteValueType, for: .border)
        cell.setWidth(5, type: .absoluteValueType, for: .padding)
        let style = paragraph
        style.paragraphSpacing = 0
        style.textBlocks = [cell]
        return style
    }

    private static func renderTable(_ cells: [Piece], sources: Sources) throws -> NSAttributedString {
        // Rows in order; the header row first.
        var rows: [(key: Int, header: Bool, cells: [Int: Piece])] = []
        var columns = 1
        for cell in cells {
            var column = 0, header = false, key = 0
            for component in cell.intent?.components ?? [] {
                switch component.kind {
                case .tableCell(let index): column = index
                case .tableHeaderRow: header = true; key = component.identity
                case .tableRow: key = component.identity
                case .table(let all): columns = max(columns, all.count)
                default: break
                }
            }
            if let at = rows.firstIndex(where: { $0.key == key }) { rows[at].cells[column] = cell }
            else { rows.append((key, header, [column: cell])) }
        }
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        let output = NSMutableAttributedString()
        for (rowIndex, row) in rows.enumerated() {
            for column in 0..<columns {
                var attributes = body
                attributes[.paragraphStyle] = block(in: table, row: rowIndex, column: column, last: rowIndex == rows.count - 1)
                if row.header { attributes[.font] = NSFont.systemFont(ofSize: bodySize, weight: .semibold) }
                let content = try row.cells[column].map { try inline($0.runs, base: attributes, sources: sources, emphasis: !row.header) }
                    ?? NSMutableAttributedString()
                // An empty cell still needs a character, or the editor drops its paragraph and the table shifts.
                if content.string.trimmed.isEmpty { content.setAttributedString(NSAttributedString(string: emptyCell, attributes: attributes)) }
                content.append(NSAttributedString(string: "\n", attributes: attributes))
                output.append(content)
            }
        }
        return output
    }

    /// Code sits in a one-cell table (a box), in a fixed-width font, one paragraph per line.
    private static func renderCode(_ source: String) -> NSAttributedString {
        let table = NSTextTable()
        table.numberOfColumns = 1
        var attributes = body
        attributes[.paragraphStyle] = block(in: table, row: 0, column: 0)
        attributes[.font] = codeFont
        let output = NSMutableAttributedString()
        for line in source.components(separatedBy: "\n") {
            output.append(NSAttributedString(string: (line.isEmpty ? emptyCell : line) + "\n", attributes: attributes))
        }
        return output
    }

    // MARK: Pictures

    /// A picture as it sits on the page: no wider than the page (stored at twice that for sharp screens).
    /// `description` is kept inside the file (a diagram's source).
    static func picture(_ data: Data, name: String, description: String? = nil) -> NSAttributedString? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var note = description
        // A diagram keeps its source and its size through being read and written again.
        let saved = (properties?[kCGImagePropertyPNGDictionary] as? [CFString: Any])?[kCGImagePropertyPNGDescription] as? String
        if note == nil, let saved, saved.hasPrefix(diagramMark) { note = saved }
        let dpi = properties?[kCGImagePropertyDPIWidth] as? CGFloat ?? 72
        // Shown at its own size in points (a 2× screenshot at half its pixels), never wider than the page.
        let natural = CGFloat(image.width) * 72 / max(dpi, 72)
        let shown = min(natural, pictureWidth)
        let pixels = min(CGFloat(image.width), shown * 2)
        if pixels < CGFloat(image.width) {
            let height = (CGFloat(image.height) * pixels / CGFloat(image.width)).rounded()
            guard let context = CGContext(data: nil, width: Int(pixels), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: height))
            guard let scaled = context.makeImage() else { return nil }
            image = scaled
        }
        let opaque = [.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo)
        let photo = opaque && note == nil && (CGImageSourceGetType(source) as String?) != UTType.png.identifier
        let type = photo ? UTType.jpeg : UTType.png
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, type.identifier as CFString, 1, nil) else { return nil }
        let density = 72 * CGFloat(image.width) / shown
        var options: [CFString: Any] = [kCGImagePropertyDPIWidth: density, kCGImagePropertyDPIHeight: density,
                                        kCGImageDestinationLossyCompressionQuality: 0.86]
        if let note { options[kCGImagePropertyPNGDictionary] = [kCGImagePropertyPNGDescription: note] }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let wrapper = FileWrapper(regularFileWithContents: encoded as Data)
        let base = (name as NSString).deletingPathExtension
        wrapper.preferredFilename = (base.isEmpty ? "image" : base) + (photo ? ".jpg" : ".png")
        let style = paragraph
        style.paragraphSpacingBefore = 4
        let text = NSMutableAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper))
        text.addAttributes(body.merging([.paragraphStyle: style]) { $1 }, range: NSRange(location: 0, length: text.length))
        return text
    }

    /// A drawn diagram (a PDF page from the web view) as a picture that carries its source.
    static func diagram(pdf: Data, source: String) -> Data? {
        guard let page = NSPDFImageRep(data: pdf) else { return nil }
        let size = page.bounds.size
        let scale: CGFloat = 2
        guard size.width > 1, size.height > 1,
              let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // On white, so it reads the same in the light and the dark look.
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        page.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale,
            kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: diagramMark + source],
        ] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? encoded as Data : nil
    }

    private static func diagramSource(_ attachment: NSTextAttachment) -> String? {
        guard let data = attachment.fileWrapper?.regularFileContents, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let note = (properties[kCGImagePropertyPNGDictionary] as? [CFString: Any])?[kCGImagePropertyPNGDescription] as? String,
              note.hasPrefix(diagramMark) else { return nil }
        return String(note.dropFirst(diagramMark.count))
    }

    /// The pictures already on a page, by the name they are read back under ("asmo-image:2"), so Markdown that
    /// mentions one keeps it.
    static func pictures(on page: NSAttributedString) -> [String: Data] {
        var found: [String: Data] = [:]
        var count = 0
        page.enumerateAttribute(.attachment, in: NSRange(location: 0, length: page.length)) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            count += 1
            if let data = attachment.fileWrapper?.regularFileContents ?? attachment.image?.tiffRepresentation {
                found[imageScheme + String(count)] = data
            }
        }
        return found
    }

    // MARK: Page → Markdown

    private struct Line {
        var range: NSRange
        var markdown: String
        enum Kind: Equatable { case blank, list, table(ObjectIdentifier), other }
        var kind: Kind
        /// For a list line that isn't nested: numbered or not (a change starts a new list).
        var numbered: Bool? = nil
    }

    static func markdown(_ page: NSAttributedString) -> String {
        blocks(page).map(\.markdown).joined(separator: "\n\n")
    }

    static func blocks(_ page: NSAttributedString) -> [Block] {
        let string = page.string as NSString
        var lines: [Line] = []
        var location = 0
        var pictureCount = 0
        // Table cells are gathered per table, then written as one table (or a code block).
        var tables: [ObjectIdentifier: [(row: Int, column: Int, text: String, mono: Bool)]] = [:]
        var widths: [ObjectIdentifier: Int] = [:]
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            var content = range
            if content.length > 0, string.character(at: NSMaxRange(content) - 1) == 10 { content.length -= 1 }
            let style = content.length > 0 || range.length > 0
                ? page.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle : nil
            if let cell = style?.textBlocks.first as? NSTextTableBlock {
                let id = ObjectIdentifier(cell.table)
                let font = content.length > 0 ? page.attribute(.font, at: content.location, effectiveRange: nil) as? NSFont : nil
                let mono = font?.isFixedPitch ?? false
                let text = mono ? string.substring(with: content).replacingOccurrences(of: emptyCell, with: "")
                    : inlineMarkdown(page, content, pictures: &pictureCount, heading: cell.startingRow == 0)
                tables[id, default: []].append((cell.startingRow, cell.startingColumn, text, mono))
                widths[id] = cell.table.numberOfColumns
                lines.append(Line(range: range, markdown: "", kind: .table(id)))
                continue
            }
            let raw = string.substring(with: content)
            let hasPicture = raw.contains("\u{FFFC}")
            if raw.trimmed.isEmpty && !hasPicture { lines.append(Line(range: range, markdown: "", kind: .blank)); continue }
            if raw.trimmed == rule { lines.append(Line(range: range, markdown: "---", kind: .other)); continue }
            let font = page.attribute(.font, at: content.location, effectiveRange: nil) as? NSFont
            let size = font?.pointSize ?? bodySize
            if size > 15.5, !hasPicture {
                let level = size >= 20 ? "# " : size >= 17.5 ? "## " : "### "
                lines.append(Line(range: range, markdown: level + inlineMarkdown(page, content, pictures: &pictureCount, heading: true), kind: .other))
                continue
            }
            // Indentation and the list marker, then the text.
            let depth = raw.prefix { $0 == "\t" }.count
            var rest = content
            rest.location += depth
            rest.length -= depth
            let text = string.substring(with: rest)
            var marker: String?
            var numbered = false
            var skip = 0
            for (glyph, written) in [("• ", "- "), ("◦ ", "- "), ("▪ ", "- "), ("☐ ", "- [ ] "), ("☑ ", "- [x] ")] where text.hasPrefix(glyph) {
                marker = written
                skip = (glyph as NSString).length
            }
            if marker == nil, let number = text.range(of: #"^\d{1,3}\. "#, options: .regularExpression) {
                marker = String(text[number])
                numbered = true
                skip = (marker! as NSString).length
            }
            rest.location += skip
            rest.length -= skip
            let words = inlineMarkdown(page, rest, pictures: &pictureCount, heading: false)
            if let marker {
                lines.append(Line(range: range, markdown: String(repeating: "  ", count: depth) + marker + words, kind: .list,
                                  numbered: depth == 0 ? numbered : nil))
            } else if depth > 0, lines.last?.kind == .list {
                lines.append(Line(range: range, markdown: String(repeating: "  ", count: depth + 1) + words, kind: .list))
            } else {
                lines.append(Line(range: range, markdown: words, kind: .other))
            }
        }
        // Lines → blocks: a run of list lines is one block, a table is one block, blank lines only separate.
        var result: [Block] = []
        var index = 0
        func add(_ range: NSRange, _ markdown: String) {
            result.append(Block(id: "b\(result.count + 1)", range: range, markdown: markdown))
        }
        while index < lines.count {
            let line = lines[index]
            switch line.kind {
            case .blank:
                index += 1
            case .other:
                add(line.range, line.markdown)
                index += 1
            case .list:
                var range = line.range
                var text = [line.markdown]
                index += 1
                while index < lines.count, lines[index].kind == .list, lines[index].numbered ?? line.numbered == line.numbered {
                    range = NSUnionRange(range, lines[index].range)
                    text.append(lines[index].markdown)
                    index += 1
                }
                add(range, text.joined(separator: "\n"))
            case .table(let id):
                var range = line.range
                index += 1
                while index < lines.count, lines[index].kind == .table(id) {
                    range = NSUnionRange(range, lines[index].range)
                    index += 1
                }
                let cells = tables[id] ?? []
                let columns = widths[id] ?? 1
                if columns == 1, cells.allSatisfy(\.mono), Set(cells.map(\.row)).count == 1 {
                    add(range, "```\n" + cells.map(\.text).joined(separator: "\n") + "\n```")
                } else {
                    var rows: [[String]] = []
                    for row in Set(cells.map(\.row)).sorted() {
                        rows.append((0..<columns).map { column in
                            cells.filter { $0.row == row && $0.column == column }.map(\.text).joined(separator: "<br>")
                                .replacingOccurrences(of: "|", with: "\\|")
                        })
                    }
                    var text = rows.prefix(1).map { "| " + $0.joined(separator: " | ") + " |" }
                    text.append("|" + String(repeating: " --- |", count: columns))
                    text += rows.dropFirst().map { "| " + $0.joined(separator: " | ") + " |" }
                    add(range, text.joined(separator: "\n"))
                }
            }
        }
        return result
    }

    /// The words of one paragraph with their formatting, pictures as `![…](asmo-image:N)` and diagrams as their source.
    private static func inlineMarkdown(_ page: NSAttributedString, _ range: NSRange, pictures: inout Int, heading: Bool) -> String {
        guard range.length > 0 else { return "" }
        var result = ""
        var count = pictures
        page.enumerateAttributes(in: range) { attributes, sub, _ in
            var text = (page.string as NSString).substring(with: sub).replacingOccurrences(of: emptyCell, with: "")
                .replacingOccurrences(of: "\u{2028}", with: "  \n")
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                count += 1
                if let source = diagramSource(attachment) { result += "```mermaid\n" + source + "\n```" }
                else { result += "![\(attachment.fileWrapper?.preferredFilename ?? "image")](\(imageScheme)\(count))" }
                return
            }
            guard !text.isEmpty else { return }
            // Formatting marks go around the words, not around the spaces at their ends.
            let lead = String(text.prefix { $0 == " " }), trail = String(text.reversed().prefix { $0 == " " })
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: " "))
            guard !text.isEmpty else { result += lead; return }
            let font = attributes[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            if font?.isFixedPitch == true { text = "`" + text + "`" }
            else if !heading {
                if traits.contains(.boldFontMask) { text = "**" + text + "**" }
                if traits.contains(.italicFontMask) { text = "*" + text + "*" }
            }
            if attributes[.strikethroughStyle] != nil { text = "~~" + text + "~~" }
            if let link = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String {
                text = text == link ? link : "[" + text + "](" + link + ")"
            }
            result += lead + text + trail
        }
        pictures = count
        return result
    }
}
#endif
