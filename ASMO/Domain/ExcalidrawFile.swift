import Foundation

/// An Obsidian Excalidraw drawing ("name.excalidraw.md"): Markdown whose "## Drawing" section holds the scene as
/// JSON (compressed with LZString, or plain), and whose "## Text Elements" lists the drawing's words (so search and
/// links find them). 逐日 reads and writes the same layout as the Obsidian plugin.
public enum ExcalidrawFile {
    public struct Drawing: Equatable, Sendable {
        /// The scene: LZString base64 (compressed) or JSON.
        public var data: String
        public var compressed: Bool
    }

    public static func isDrawing(_ name: String) -> Bool { name.lowercased().hasSuffix(".excalidraw.md") }

    /// The fenced block under "## Drawing".
    private static func block(in text: String) -> (fence: Range<String.Index>, body: Range<String.Index>, compressed: Bool)? {
        guard let heading = text.range(of: "## Drawing") else { return nil }
        for (opener, compressed) in [("```compressed-json", true), ("```json", false)] {
            guard let open = text.range(of: opener, range: heading.upperBound..<text.endIndex),
                  text[heading.upperBound..<open.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let lineEnd = text.range(of: "\n", range: open.upperBound..<text.endIndex),
                  let close = text.range(of: "\n```", range: lineEnd.lowerBound..<text.endIndex) else { continue }
            // An empty block: the closing fence is the next line.
            let body = close.lowerBound > lineEnd.lowerBound ? lineEnd.upperBound..<close.lowerBound : lineEnd.upperBound..<lineEnd.upperBound
            return (open.lowerBound..<close.upperBound, body, compressed)
        }
        return nil
    }

    public static func drawing(in text: String) -> Drawing? {
        guard let found = block(in: text) else { return nil }
        return Drawing(data: String(text[found.body]), compressed: found.compressed)
    }

    /// The file with a new scene (compressed, in lines of 256 as the plugin writes it) and its words listed again.
    public static func updated(_ text: String, data: String, texts: [(id: String, text: String)]) -> String {
        var result = text.isEmpty || block(in: text) == nil ? blank : text
        let chunks = stride(from: 0, to: data.count, by: 256).map { start -> String in
            let from = data.index(data.startIndex, offsetBy: start)
            let to = data.index(from, offsetBy: min(256, data.count - start))
            return String(data[from..<to])
        }
        if let found = block(in: result) {
            result.replaceSubrange(found.fence, with: "```compressed-json\n" + chunks.joined(separator: "\n\n") + "\n```")
        }
        // "## Text Elements" up to the "%%" before "## Drawing".
        if let start = result.range(of: "## Text Elements\n"),
           let end = result.range(of: "%%\n## Drawing", range: start.upperBound..<result.endIndex) {
            let words = texts.filter { !$0.text.isEmpty }.map { "\($0.text) ^\($0.id)\n\n" }.joined()
            result.replaceSubrange(start.upperBound..<end.lowerBound, with: words)
        }
        return result
    }

    /// A new, empty drawing.
    public static let blank = """
    ---

    excalidraw-plugin: parsed
    tags: [excalidraw]

    ---
    ==⚠  Switch to EXCALIDRAW VIEW in the MORE OPTIONS menu of this document. ⚠== You can decompress Drawing data with the command palette: 'Decompress current Excalidraw file'. For more info check in plugin settings under 'Saving'


    # Excalidraw Data

    ## Text Elements
    %%
    ## Drawing
    ```compressed-json
    ```
    %%
    """
}
