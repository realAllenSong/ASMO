import Foundation

/// A mind map read from free writing: headings become branches, indented or bulleted lines become their
/// children, plain paragraphs become leaves (shortened). Built instantly while typing; no model needed.
struct IdeaNode: Identifiable, Sendable, Equatable {
    var id: String
    var title: String
    /// The full line, when the title had to be shortened.
    var detail: String?
    var isTodo = false
    var children: [IdeaNode] = []

    var count: Int { 1 + children.reduce(0) { $0 + $1.count } }
}

struct IdeaLine: Sendable, Equatable {
    var level: Int
    var isHeading: Bool
    var text: String
}

enum IdeaMap {
    static let titleLimit = 28

    /// Splits plain text into lines with indentation levels; "# " marks a heading.
    static func lines(from text: String) -> [IdeaLine] {
        text.components(separatedBy: .newlines).compactMap { raw in
            var indent = 0
            var rest = Substring(raw)
            while let first = rest.first, first == " " || first == "\t" || first == "\u{3000}" {
                indent += first == "\t" ? 2 : 1
                rest = rest.dropFirst()
            }
            var body = String(rest).trimmed
            guard !body.isEmpty else { return nil }
            var heading = false
            if let marks = body.match(#"^(#{1,6})\s+"#)?.first {
                heading = true
                body = String(body.dropFirst(marks.count))
            }
            return IdeaLine(level: indent / 2, isHeading: heading, text: body)
        }
    }

    static func build(title: String, lines: [IdeaLine]) -> IdeaNode {
        var root = IdeaNode(id: "root", title: title.isEmpty ? String(localized: "想法") : title)
        // Path of child indexes from the root to the current parent, with the level that opened it.
        var stack: [(level: Int, heading: Bool, path: [Int])] = []
        for (index, line) in lines.enumerated() {
            let (todo, body) = todoMarker(line.text)
            let short = shorten(body)
            let node = IdeaNode(id: "n\(index)", title: short, detail: short == body ? nil : body, isTodo: todo)
            if line.isHeading {
                // A heading closes everything below the previous heading at its level or deeper.
                while let top = stack.last, !top.heading || top.level >= line.level { stack.removeLast() }
            } else {
                while let top = stack.last, !top.heading && top.level >= line.level { stack.removeLast() }
            }
            let parentPath = stack.last?.path ?? []
            let childIndex = append(node, at: parentPath, in: &root)
            stack.append((line.level, line.isHeading, parentPath + [childIndex]))
        }
        return root
    }

    /// Mermaid "mindmap" source for the tree, for pasting into a blog or notes.
    static func mermaid(_ root: IdeaNode) -> String {
        var out = ["mindmap", "  root((\(escape(root.title))))"]
        func walk(_ node: IdeaNode, depth: Int) {
            for child in node.children {
                let text = escape(child.title)
                out.append(String(repeating: "  ", count: depth + 2) + (child.isTodo ? "[☐ \(text)]" : "(\(text))"))
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return out.joined(separator: "\n")
    }

    /// Regroups the top-level lines under themes (from the model). Every line keeps its own text and details;
    /// lines no theme claimed go under 其他, so nothing is lost.
    static func grouped(title: String, lines: [IdeaLine], themes: [(title: String, lines: [Int])]) -> IdeaNode {
        let structural = build(title: title, lines: lines)
        let tops = structural.children
        var used = Set<Int>()
        var root = IdeaNode(id: "root", title: structural.title)
        for (index, theme) in themes.enumerated() {
            let members = theme.lines.filter { tops.indices.contains($0) && used.insert($0).inserted }
            guard !members.isEmpty else { continue }
            root.children.append(IdeaNode(id: "theme\(index)", title: theme.title, children: members.map { tops[$0] }))
        }
        let rest = tops.indices.filter { !used.contains($0) }
        if !rest.isEmpty {
            root.children.append(IdeaNode(id: "theme-rest", title: String(localized: "其他"), children: rest.map { tops[$0] }))
        }
        return root
    }

    static func todos(in root: IdeaNode) -> [IdeaNode] {
        root.children.flatMap { node in (node.isTodo ? [node] : []) + todos(in: node) }
    }

    private static func todoMarker(_ text: String) -> (Bool, String) {
        for marker in ["☐ ", "☑ ", "[ ] ", "[] ", "- [ ] "] where text.hasPrefix(marker) {
            return (true, String(text.dropFirst(marker.count)).trimmed)
        }
        for marker in ["• ", "- ", "* ", "· "] where text.hasPrefix(marker) {
            return (false, String(text.dropFirst(marker.count)).trimmed)
        }
        return (false, text)
    }

    private static func shorten(_ text: String) -> String {
        guard text.count > titleLimit else { return text }
        // Prefer the first clause.
        if let cut = text.firstIndex(where: { "，。；;,.!！？?：:".contains($0) }),
           text.distance(from: text.startIndex, to: cut) >= 4,
           text.distance(from: text.startIndex, to: cut) <= titleLimit {
            return String(text[..<cut])
        }
        return String(text.prefix(titleLimit - 1)) + "…"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "(", with: "（").replacingOccurrences(of: ")", with: "）")
            .replacingOccurrences(of: "[", with: "【").replacingOccurrences(of: "]", with: "】")
    }

    private static func append(_ node: IdeaNode, at path: [Int], in root: inout IdeaNode) -> Int {
        guard let first = path.first else {
            root.children.append(node)
            return root.children.count - 1
        }
        return append(node, at: Array(path.dropFirst()), in: &root.children[first])
    }
}
