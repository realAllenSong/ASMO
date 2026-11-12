import Testing
@testable import ASMOCore

struct IdeaMapTests {
    @Test func headingsBranchAndIndentNests() {
        let text = """
        # 博客
        写一篇关于端侧模型的文章，讲清楚为什么免费又快，以及在手机上怎么跑
          ☐ 测 Gemma 4 E2B 的速度
          ☐ 画架构图
        # 产品
        - ASMO 上架
          - 定价
        随便一个想法
        """
        let root = IdeaMap.build(title: "长期计划", lines: IdeaMap.lines(from: text))
        #expect(root.children.map(\.title) == ["博客", "产品"])
        let blog = root.children[0]
        #expect(blog.children.count == 1)
        #expect(blog.children[0].title == "写一篇关于端侧模型的文章")
        #expect(blog.children[0].detail != nil)
        #expect(blog.children[0].children.map(\.title) == ["测 Gemma 4 E2B 的速度", "画架构图"])
        #expect(blog.children[0].children.allSatisfy { $0.isTodo })
        #expect(root.children[1].children.map(\.title) == ["ASMO 上架", "随便一个想法"])
        #expect(root.children[1].children[0].children.map(\.title) == ["定价"])
        #expect(IdeaMap.todos(in: root).count == 2)
    }

    @Test func mermaidExportIsAMindmap() {
        let root = IdeaMap.build(title: "计划", lines: IdeaMap.lines(from: "# 学习\n  ☐ 读论文 (A)"))
        let code = IdeaMap.mermaid(root)
        #expect(code.hasPrefix("mindmap\n  root((计划))"))
        #expect(code.contains("(学习)"))
        #expect(code.contains("[☐ 读论文 （A）]"))
    }

    @Test func groupingKeepsEveryLine() {
        let lines = IdeaMap.lines(from: "给 ASMO 加语音\n周末去爬山\n  带水\nASMO 上架\n写博客")
        let root = IdeaMap.grouped(title: "想法", lines: lines, themes: [("ASMO", [0, 2]), ("爬山", [1, 9])])
        #expect(root.children.map(\.title) == ["ASMO", "爬山", "其他"])
        #expect(root.children[1].children.first?.children.map(\.title) == ["带水"])
        #expect(root.children[2].children.map(\.title) == ["写博客"])
        #expect(root.count == 1 + 3 + 5)
    }
}
