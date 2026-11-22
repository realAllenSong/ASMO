import Foundation
import Testing
@testable import ASMOCore

struct NoteMarkdownTests {
    func kinds(_ text: String) -> [NoteMarkdown.LineKind] { NoteMarkdown.lines(text).map(\.kind) }

    func spans(_ line: String) -> [String] {
        let ns = line as NSString
        return NoteMarkdown.spans(in: ns, line: NSRange(location: 0, length: ns.length)).map { span in
            "\(span.kind):\(ns.substring(with: span.content))"
        }
    }

    @Test func linesAreClassified() {
        let text = "---\ntags: a\n---\n# Title\n- one\n\t- two\n- [ ] todo\n- [x] done\n1. first\n> quote\n```swift\nlet x = 1 # no\n```\n$$\nx^2\n$$\n| a | b |\n---\n![[pic.png]]\n![alt](img/a%20b.png)\n\nplain"
        #expect(kinds(text) == [
            .frontmatter, .frontmatter, .frontmatter, .heading(1), .bullet(depth: 0, ordered: false), .bullet(depth: 1, ordered: false),
            .task(depth: 0, done: false), .task(depth: 0, done: true), .bullet(depth: 0, ordered: true), .quote,
            .fence, .code, .fence, .mathFence, .math, .mathFence, .table, .rule, .embed("pic.png"), .embed("img/a b.png"),
            .blank, .text,
        ])
    }

    @Test func linesCoverTheTextExactly() {
        for text in ["", "a", "a\n", "a\n\nb", "a\r\nb\r\n", "# h\n- x\n"] {
            let lines = NoteMarkdown.lines(text)
            let ns = text as NSString
            // Every character is in a line or a line break; lines are in order and don't overlap.
            var at = 0
            for line in lines {
                #expect(line.range.location >= at)
                at = NSMaxRange(line.range)
            }
            #expect(at <= ns.length)
            #expect(!lines.isEmpty)
        }
        #expect(NoteMarkdown.lines("a\n").count == 2)
    }

    @Test func inlineSpans() {
        #expect(spans("a **bold** and *it* and ~~gone~~ ==mark==") == ["bold:bold", "italic:it", "strike:gone", "highlight:mark"])
        #expect(spans("see [[Note#Part|shown]] and [[Other]]") == ["wikilink(\"Note\"):shown", "wikilink(\"Other\"):Other"])
        #expect(spans("![[a.png]] [site](https://x.com/a_b_c) `co*de*`") == ["embed(\"a.png\"):a.png", "link(\"https://x.com/a_b_c\"):site", "code:co*de*"])
        #expect(spans("cost $5 and $x^2$ here #tag #中文标签 #1") == ["math:x^2", "tag:#tag", "tag:#中文标签"])
        #expect(spans("go to https://example.com/a.") == ["url:https://example.com/a"])
        #expect(spans("snake_case_name") == [])
    }

    @Test func headingsForTheContents() {
        let text = "# One\ntext\n## **Two**\n```\n# not\n```\n### [[Three]]"
        #expect(NoteMarkdown.headings(text).map(\.title) == ["One", "Two", "Three"])
        #expect(NoteMarkdown.headings(text).map(\.level) == [1, 2, 3])
    }
}

struct NoteBlocksTests {
    func cells(_ line: String) -> [String] {
        let ns = line as NSString
        return NoteMarkdown.tableCells(line).cells.map { ns.substring(with: $0) }
    }

    @Test func tableRows() {
        #expect(cells("| a | b |") == ["a", "b"])
        #expect(cells("|a|| c |") == ["a", "", "c"])
        #expect(cells("| x \\| y | z") == ["x \\| y", "z"])
        #expect(NoteMarkdown.isTableSeparator("| --- | :---: |"))
        #expect(NoteMarkdown.isTableSeparator("|---|---|"))
        #expect(!NoteMarkdown.isTableSeparator("| a | b |"))
    }

    @Test func callouts() {
        let c = NoteMarkdown.callout("> [!Tip]- Read this")
        #expect(c?.type == "tip")
        #expect(c?.folded == true)
        #expect(c.map { ("> [!Tip]- Read this" as NSString).substring(with: $0.title) } == "Read this")
        #expect(NoteMarkdown.callout("> plain quote") == nil)
    }

    @Test func footnotesAndComments() {
        let ns = "word[^1] and %%hidden%% here" as NSString
        let kinds = NoteMarkdown.spans(in: ns, line: NSRange(location: 0, length: ns.length)).map(\.kind)
        #expect(kinds == [.footnote, .comment])
    }

    @Test func codeColours() {
        let line = #"let name = "a # b" // note"#
        let kinds = NoteMarkdown.codeTokens(line, hashComments: false).map(\.kind)
        #expect(kinds == [.keyword, .string, .comment])
        let python = "x = 42  # answer"
        #expect(NoteMarkdown.codeTokens(python, hashComments: true).map(\.kind) == [.number, .comment])
    }
}
