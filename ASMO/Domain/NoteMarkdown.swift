import Foundation

/// Reads a note's Markdown for drawing it: what each line is and the marked spans inside it. Reading never changes
/// the text (the note is the file, byte for byte; Obsidian and Git read the same file). Ranges are UTF-16 offsets
/// into the whole text, as NSString and NSTextView use them.
public enum NoteMarkdown {
    public enum LineKind: Equatable, Sendable {
        case text, blank
        case heading(Int)
        /// "- ", "* ", "+ ", "1. " (depth: how far it is indented).
        case bullet(depth: Int, ordered: Bool)
        case task(depth: Int, done: Bool)
        case quote
        /// A ``` line, and the lines between two of them.
        case fence, code
        /// The "---" block at the very top (Obsidian's properties).
        case frontmatter
        /// A $$ line, and the lines between two of them.
        case mathFence, math
        case table
        case rule
        /// A line that is only a picture or a drawing: ![[target]] or ![alt](target).
        case embed(String)
    }

    public struct Line: Equatable, Sendable {
        /// The line without its break.
        public var range: NSRange
        public var kind: LineKind
        /// The part before the words that preview hides or draws as something else: "## ", "- ", "- [ ] ", "> ".
        public var marker: NSRange?
        /// A task's "[ ]" / "[x]".
        public var box: NSRange?
    }

    public enum SpanKind: Equatable, Sendable {
        case bold, italic, strike, highlight, code, math, tag, url
        /// "[^1]": a footnote's mark.
        case footnote
        /// "%%…%%": a comment (hidden in reading).
        case comment
        case link(String)
        case wikilink(String)
        case embed(String)
    }

    public struct Span: Equatable, Sendable {
        public var kind: SpanKind
        /// Everything, markers included.
        public var range: NSRange
        /// What shows when the markers are hidden.
        public var content: NSRange
    }

    public struct Heading: Equatable, Sendable {
        public var level: Int
        public var title: String
        public var range: NSRange
    }

    // MARK: Lines

    public static func lines(_ text: String) -> [Line] {
        let string = text as NSString
        var result: [Line] = []
        var location = 0
        var inFence = false
        var inMath = false
        var inFront = false
        var index = 0
        while location < string.length || (location == string.length && index == 0) {
            let full = string.lineRange(for: NSRange(location: location, length: 0))
            var content = full
            while content.length > 0 {
                let last = string.character(at: NSMaxRange(content) - 1)
                guard last == 10 || last == 13 else { break }
                content.length -= 1
            }
            let raw = string.substring(with: content)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            var line = Line(range: content, kind: .text)
            if index == 0 && trimmed == "---" {
                inFront = true
                line.kind = .frontmatter
            } else if inFront {
                line.kind = .frontmatter
                if trimmed == "---" || trimmed == "..." { inFront = false }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                line.kind = .fence
            } else if inFence {
                line.kind = .code
            } else if trimmed == "$$" {
                inMath.toggle()
                line.kind = .mathFence
            } else if inMath {
                line.kind = .math
            } else if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count > 4 {
                line.kind = .math
            } else if trimmed.isEmpty {
                line.kind = .blank
            } else {
                classify(raw, at: content.location, into: &line)
            }
            result.append(line)
            index += 1
            if NSMaxRange(full) == location { break }
            location = NSMaxRange(full)
            if location == string.length {
                // A text ending in a line break has one more, empty line.
                let last = string.character(at: string.length - 1)
                if last == 10 || last == 13 { result.append(Line(range: NSRange(location: location, length: 0), kind: .blank)) }
                break
            }
        }
        return result
    }

    private static func classify(_ raw: String, at start: Int, into line: inout Line) {
        let ns = raw as NSString
        func range(_ r: NSRange) -> NSRange { NSRange(location: start + r.location, length: r.length) }
        if let m = first(#"^(#{1,6})[ \t]+"#, in: raw) {
            line.kind = .heading(m.range(at: 1).length)
            line.marker = range(m.range)
            return
        }
        if let m = first(#"^(\s*)(?:[-*+]|\d{1,3}[.)])[ \t]+\[([ xX])\](?:[ \t]+|$)"#, in: raw) {
            let done = ns.substring(with: m.range(at: 2)) != " "
            line.kind = .task(depth: depth(ns.substring(with: m.range(at: 1))), done: done)
            line.marker = range(m.range)
            line.box = range(NSRange(location: m.range(at: 2).location - 1, length: 3))
            return
        }
        if let m = first(#"^(\s*)([-*+]|\d{1,3}[.)])[ \t]+"#, in: raw) {
            let ordered = ns.substring(with: m.range(at: 2)).first?.isNumber == true
            // "---" and "* * *" are rules, not bullets.
            if !isRule(raw) {
                line.kind = .bullet(depth: depth(ns.substring(with: m.range(at: 1))), ordered: ordered)
                line.marker = range(m.range)
                return
            }
        }
        if isRule(raw) {
            line.kind = .rule
            return
        }
        if let m = first(#"^\s*>[ \t]?"#, in: raw) {
            line.kind = .quote
            line.marker = range(m.range)
            return
        }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") {
            line.kind = .table
            return
        }
        if let m = first(#"^\s*!\[\[([^\]|#]+)(?:[|#][^\]]*)?\]\]\s*$"#, in: raw) {
            line.kind = .embed(ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces))
            return
        }
        if let m = first(#"^\s*!\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)\s*$"#, in: raw) {
            line.kind = .embed(ns.substring(with: m.range(at: 1)).removingPercentEncoding ?? ns.substring(with: m.range(at: 1)))
            return
        }
    }

    private static func isRule(_ raw: String) -> Bool {
        first(#"^\s*([-*_])(?:\s*\1){2,}\s*$"#, in: raw) != nil
    }

    private static func depth(_ indent: String) -> Int {
        var width = 0
        for character in indent { width += character == "\t" ? 4 : 1 }
        return min(6, width / 2 == 0 ? 0 : (width + 1) / 3)
    }

    // MARK: Spans

    private static let patterns: [(SpanKind, String, Int)] = [
        // (kind, pattern, capture group of the shown content)
        (.comment, #"%%(.+?)%%"#, 1),
        (.footnote, #"\[\^([^\]\s]+)\](?!:)"#, 1),
        (.embed(""), #"!\[\[([^\]]+)\]\]"#, 1),
        (.wikilink(""), #"\[\[([^\]]+)\]\]"#, 1),
        (.link(""), #"!?\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#, 1),
        (.math, #"(?<![\\$])\$(?=[^\s$])([^$\n]+?)(?<=[^\s\\])\$(?![\d$])"#, 1),
        (.url, #"(?<![(<\[])\bhttps?://[^\s<>()\[\]]+[^\s<>()\[\].,;:!?。，；：！？）)]"#, 0),
        (.bold, #"\*\*(?=\S)(.+?)(?<=\S)\*\*"#, 1),
        (.bold, #"(?<![\w_])__(?=\S)(.+?)(?<=\S)__(?![\w_])"#, 1),
        (.strike, #"~~(?=\S)(.+?)(?<=\S)~~"#, 1),
        (.highlight, #"==(?=\S)(.+?)(?<=\S)=="#, 1),
        (.italic, #"(?<![*\\])\*(?=[^\s*])(.+?)(?<=[^\s*\\])\*(?!\*)"#, 1),
        (.italic, #"(?<![\w_\\])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![\w_])"#, 1),
        (.tag, #"(?<![\w#&/\\])#([^\s#\d!-/:-@\[-^`{-~，。、；：？！（）【】《》“”‘’][^\s#!-/:-@\[-^`{-~，。、；：？！（）【】《》“”‘’]*)"#, 0),
    ]

    private static let compiled: [(SpanKind, NSRegularExpression, Int)] = patterns.compactMap { kind, pattern, group in
        (try? NSRegularExpression(pattern: pattern)).map { (kind, $0, group) }
    }
    private static let codePattern = try! NSRegularExpression(pattern: #"(`+)(?=[^`])(.+?)(?<=[^`])\1(?!`)"#)

    /// The marked spans in one line (code first: nothing inside it is anything else; then links, whose addresses
    /// aren't read for emphasis; then the rest, which may nest inside each other).
    public static func spans(in text: NSString, line: NSRange) -> [Span] {
        guard line.length > 0 else { return [] }
        let source = text.substring(with: line)
        let ns = source as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var spans: [Span] = []
        var blocked: [NSRange] = []
        func shift(_ r: NSRange) -> NSRange { NSRange(location: line.location + r.location, length: r.length) }
        func free(_ r: NSRange) -> Bool { !blocked.contains { NSIntersectionRange($0, r).length > 0 } }
        for match in codePattern.matches(in: source, range: whole) {
            spans.append(Span(kind: .code, range: shift(match.range), content: shift(match.range(at: 2))))
            blocked.append(match.range)
        }
        for (kind, regex, group) in compiled {
            for match in regex.matches(in: source, range: whole) where free(match.range) {
                var actual = kind
                let content = match.range(at: group)
                switch kind {
                case .embed:
                    actual = .embed(target(ns.substring(with: match.range(at: 1))))
                case .wikilink:
                    let inner = ns.substring(with: match.range(at: 1))
                    actual = .wikilink(target(inner))
                    // "[[note|shown]]": what shows is after the bar.
                    if let bar = inner.firstIndex(of: "|") {
                        let offset = inner.utf16.distance(from: inner.utf16.startIndex, to: bar.samePosition(in: inner.utf16)!) + 1
                        spans.append(Span(kind: actual, range: shift(match.range),
                                          content: shift(NSRange(location: match.range(at: 1).location + offset,
                                                                 length: match.range(at: 1).length - offset))))
                        blocked.append(match.range)
                        continue
                    }
                case .link:
                    let address = ns.substring(with: match.range(at: 2))
                    actual = .link(address)
                    if ns.substring(with: NSRange(location: match.range.location, length: 1)) == "!" {
                        actual = .embed(address.removingPercentEncoding ?? address)
                    }
                default:
                    break
                }
                spans.append(Span(kind: actual, range: shift(match.range), content: shift(content)))
                // Addresses, code-like and math spans hold no emphasis; emphasis may hold emphasis.
                switch actual {
                case .bold, .italic, .strike, .highlight: break
                default: blocked.append(match.range)
                }
            }
        }
        return spans.sorted { $0.range.location < $1.range.location }
    }

    /// "Note#Heading|shown" → "Note".
    static func target(_ inner: String) -> String {
        var value = inner
        if let bar = value.firstIndex(of: "|") { value = String(value[..<bar]) }
        if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]) }
        return value.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Tables

    /// "| --- | :---: |": the line under a table's header.
    public static func isTableSeparator(_ line: String) -> Bool {
        first(#"^\s*\|?(\s*:?-{2,}:?\s*\|)+\s*:?-{0,}:?\s*\|?\s*$"#, in: line) != nil
    }

    /// A table row's cells: each cell's words (trimmed; empty for an empty cell), as ranges into the line, and the
    /// bars between them. "\|" inside a cell is not a bar.
    public static func tableCells(_ line: String) -> (cells: [NSRange], bars: [Int]) {
        let ns = line as NSString
        var bars: [Int] = []
        var index = 0
        while index < ns.length {
            let character = ns.character(at: index)
            if character == 92 { index += 2; continue } // backslash
            if character == 124 { bars.append(index) }
            index += 1
        }
        // A row needs a bar at its start (as the lines classified as tables have).
        guard let firstBar = bars.first else { return ([], []) }
        let lastIsClosing = ns.substring(from: bars.last! + 1).trimmingCharacters(in: .whitespaces).isEmpty
        var edges = bars
        if !lastIsClosing { edges.append(ns.length) }
        var cells: [NSRange] = []
        for (a, b) in zip(edges, edges.dropFirst()) {
            var start = a + 1, end = b
            while start < end, ns.character(at: start) == 32 || ns.character(at: start) == 9 { start += 1 }
            while end > start, ns.character(at: end - 1) == 32 || ns.character(at: end - 1) == 9 { end -= 1 }
            cells.append(NSRange(location: start, length: end - start))
        }
        _ = firstBar
        return (cells, bars)
    }

    // MARK: Callouts

    public struct Callout: Equatable, Sendable {
        /// "note", "tip", "warning"… (lowercased).
        public var type: String
        /// "> [!note]-" in the line: hidden in reading.
        public var marker: NSRange
        /// The title written after it (empty: the type is the title).
        public var title: NSRange
        public var folded: Bool
    }

    /// The first line of an Obsidian callout: "> [!tip] Title".
    public static func callout(_ line: String) -> Callout? {
        guard let m = first(#"^(\s*>\s*\[!([A-Za-z-]+)\]([+-]?))\s*(.*)$"#, in: line) else { return nil }
        let ns = line as NSString
        return Callout(type: ns.substring(with: m.range(at: 2)).lowercased(), marker: m.range(at: 1), title: m.range(at: 4),
                       folded: ns.substring(with: m.range(at: 3)) == "-")
    }

    // MARK: Code

    public enum TokenKind: Equatable, Sendable { case keyword, string, comment, number }

    public struct Token: Equatable, Sendable {
        public var kind: TokenKind
        public var range: NSRange
    }

    private static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "return", "import", "from", "class", "struct", "enum", "def",
        "in", "of", "const", "function", "async", "await", "try", "catch", "throw", "throws", "guard", "switch", "case",
        "break", "continue", "true", "false", "nil", "null", "None", "True", "False", "self", "this", "new", "public",
        "private", "static", "extension", "protocol", "interface", "type", "export", "default", "do", "with", "as",
        "and", "or", "not", "is", "lambda", "yield", "pass", "raise", "except", "finally", "elif", "fn", "pub", "mut",
        "impl", "use", "mod", "match", "go", "package", "int", "float", "string", "bool", "void", "echo", "then",
        "fi", "done", "select", "where", "SELECT", "FROM", "WHERE", "INSERT", "UPDATE", "DELETE", "JOIN", "ON",
    ]

    /// Colours for one line of code: strings, comments, numbers and the common keywords of most languages.
    /// `hashComments`: "#" starts a comment (Python, shell, YAML, Ruby, R…).
    public static func codeTokens(_ line: String, hashComments: Bool) -> [Token] {
        let ns = line as NSString
        var tokens: [Token] = []
        var taken: [NSRange] = []
        func free(_ r: NSRange) -> Bool { !taken.contains { NSIntersectionRange($0, r).length > 0 } }
        let comment = hashComments ? #"(?<![\w$"'])#(?![!{\[]).*$|//.*$|--\s.*$"# : #"//.*$|/\*.*?(\*/|$)|<!--.*?(-->|$)"#
        let pieces: [(TokenKind, String)] = [
            (.string, #""(?:[^"\\]|\\.)*"?|'(?:[^'\\]|\\.)*'?|`(?:[^`\\]|\\.)*`?"#),
            (.comment, comment),
        ]
        // Strings and comments: whichever starts first wins.
        var found: [(TokenKind, NSRange)] = []
        for (kind, pattern) in pieces {
            guard let regex = cache(pattern) else { continue }
            for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) { found.append((kind, m.range)) }
        }
        for (kind, range) in found.sorted(by: { $0.1.location < $1.1.location }) where free(range) {
            tokens.append(Token(kind: kind, range: range))
            taken.append(range)
        }
        if let regex = cache(#"\b(\d+(?:\.\d+)?)\b|\b([A-Za-z_]+)\b"#) {
            for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) where free(m.range) {
                if m.range(at: 1).location != NSNotFound {
                    tokens.append(Token(kind: .number, range: m.range))
                } else if keywords.contains(ns.substring(with: m.range)) {
                    tokens.append(Token(kind: .keyword, range: m.range))
                }
            }
        }
        return tokens.sorted { $0.range.location < $1.range.location }
    }

    // MARK: Headings

    public static func headings(_ text: String) -> [Heading] {
        let string = text as NSString
        return lines(text).compactMap { line in
            guard case .heading(let level) = line.kind, let marker = line.marker else { return nil }
            let title = string.substring(with: NSRange(location: NSMaxRange(marker), length: NSMaxRange(line.range) - NSMaxRange(marker)))
                .replacingOccurrences(of: #"[*_=~`]|\[\[|\]\]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : Heading(level: level, title: title, range: line.range)
        }
    }

    private static func first(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = cache(pattern) else { return nil }
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    nonisolated(unsafe) private static var regexes: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()
    private static func cache(_ pattern: String) -> NSRegularExpression? {
        lock.lock(); defer { lock.unlock() }
        if let known = regexes[pattern] { return known }
        let made = try? NSRegularExpression(pattern: pattern)
        regexes[pattern] = made
        return made
    }
}
