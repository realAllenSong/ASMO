import Foundation
import Testing
@testable import ASMOCore

struct AgentQuestionsTests {
    private func question(_ id: String, _ title: String = "Keep this rule?", why: String? = nil, from: String = "Rosetta") -> AgentQuestion {
        AgentQuestion(id: id, from: from, title: title, why: why, asked: Date(timeIntervalSince1970: 0))
    }

    @Test func askingAgainUpdatesInPlaceAndKeepsAnAnswerToTheSameQuestion() {
        var book = AgentQuestionBook()
        book.ask(question("a"))
        book.answer("a", .yes, at: Date(timeIntervalSince1970: 10))
        var again = question("a")
        again.reason = "a new reason"
        book.ask(again)
        #expect(book.questions.count == 1)
        #expect(book.questions[0].answer == .yes)
        #expect(book.questions[0].reason == "a new reason")
        // A changed question is asked afresh.
        book.ask(question("a", "Keep this other rule?"))
        #expect(book.questions[0].answer == nil)
        #expect(book.open.count == 1)
    }

    @Test func answersAreReadBackOldestFirstPerAskerAndUndoReopens() {
        var book = AgentQuestionBook()
        book.ask(question("a"))
        book.ask(question("b"))
        book.ask(question("c", from: "Other"))
        book.answer("b", .no, at: Date(timeIntervalSince1970: 5))
        book.answer("a", .yes, at: Date(timeIntervalSince1970: 9))
        book.answer("c", .yes, at: Date(timeIntervalSince1970: 1))
        #expect(book.answered(from: "rosetta").map(\.id) == ["b", "a"])
        #expect(book.answered().map(\.id) == ["c", "b", "a"])
        book.answer("a", nil)
        #expect(book.open.map(\.id) == ["a"])
        #expect(book.remove(["b", "c", "missing"]) == 2)
        let found = book.answer("missing", .yes)
        #expect(!found)
    }

    @Test func staleAnswersGoAndTheBookStaysBounded() {
        var book = AgentQuestionBook()
        book.ask(question("old"))
        book.answer("old", .yes, at: Date(timeIntervalSince1970: 0))
        book.ask(question("open"))
        book.forgetStale(now: Date(timeIntervalSince1970: 31 * 86_400))
        #expect(book.questions.map(\.id) == ["open"])
        book.answer("open", .no)
        for index in 0..<AgentQuestionBook.limit { book.ask(question("q\(index)")) }
        #expect(book.questions.count == AgentQuestionBook.limit)
        #expect(!book.questions.contains { $0.id == "open" }, "the answered one goes before any open question")
    }

    @Test func roundTripsThroughTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("questions-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var book = AgentQuestionBook()
        var q = question("a", why: "从对话里提取")
        q.suggest = .yes
        q.tags = ["规则", "所有项目"]
        book.ask(q)
        try book.save(url)
        #expect(AgentQuestionBook.load(url) == book)
        #expect(AgentQuestionBook.load(url.appendingPathExtension("missing")).questions.isEmpty)
    }
}
