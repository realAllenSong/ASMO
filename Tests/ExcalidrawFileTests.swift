import Foundation
import Testing
@testable import ASMOCore

struct ExcalidrawFileTests {
    let sample = "---\n\nexcalidraw-plugin: parsed\n\n---\n# Excalidraw Data\n\n## Text Elements\nold ^a1\n\n%%\n## Drawing\n```compressed-json\nAAAA\n\nBBBB\n```\n%%"

    @Test func readsTheScene() {
        let drawing = ExcalidrawFile.drawing(in: sample)
        #expect(drawing?.compressed == true)
        #expect(drawing?.data == "AAAA\n\nBBBB")
        #expect(ExcalidrawFile.drawing(in: "## Drawing\n```json\n{\"a\":1}\n```\n")?.compressed == false)
        #expect(ExcalidrawFile.drawing(in: "# plain note") == nil)
    }

    @Test func writesItBack() {
        let data = String(repeating: "x", count: 300)
        let written = ExcalidrawFile.updated(sample, data: data, texts: [(id: "b2", text: "新的字")])
        #expect(written.contains("```compressed-json\n" + String(repeating: "x", count: 256) + "\n\nxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n```"))
        #expect(written.contains("## Text Elements\n新的字 ^b2\n\n%%\n## Drawing"))
        #expect(!written.contains("old ^a1"))
        #expect(written.hasPrefix("---\n\nexcalidraw-plugin: parsed"))
        #expect(ExcalidrawFile.drawing(in: written)?.data == String(repeating: "x", count: 256) + "\n\n" + String(repeating: "x", count: 44))
    }

    @Test func blankIsADrawing() {
        #expect(ExcalidrawFile.drawing(in: ExcalidrawFile.blank)?.data == "")
        #expect(ExcalidrawFile.updated(ExcalidrawFile.blank, data: "QQ", texts: []).contains("```compressed-json\nQQ\n```"))
    }
}
