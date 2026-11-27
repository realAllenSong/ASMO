#if os(macOS)
import AppKit
import Foundation
import Observation

/// The questions agents leave for the person (`asmo ask`), as the app holds them: the panel shows the open ones, the
/// Dock icon counts them, and the agent door reads and changes them. Kept in a JSON file beside the store (a test
/// store has its own), written by the app alone.
@MainActor @Observable
final class QuestionDesk {
    static let shared = QuestionDesk()

    private(set) var book: AgentQuestionBook
    /// Answered in this run, shown as a quiet line with 撤销 until the asker reads the answer back.
    private(set) var answeredHere: [String] = []
    private let url: URL

    private init() {
        var name = "questions.json"
        #if DEBUG
        if ProcessInfo.processInfo.environment["ASMO_TEST_STORE"] != nil { name = "questions-test.json" }
        #endif
        url = AppPaths.support.appendingPathComponent(name)
        book = AgentQuestionBook.load(url)
        book.forgetStale()
        updateBadge()
    }

    var open: [AgentQuestion] { book.open }
    var recentlyAnswered: [AgentQuestion] {
        answeredHere.compactMap { id in book.questions.first { $0.id == id && !$0.isOpen } }
    }

    /// Adds or updates questions; says which ones are new (so the panel can come forward for them).
    @discardableResult
    func ask(_ questions: [AgentQuestion]) throws -> [AgentQuestion] {
        let known = Set(book.questions.map(\.id))
        let asked = questions.map { book.ask($0) }
        try commit()
        let fresh = asked.filter { !known.contains($0.id) && $0.isOpen }
        if !fresh.isEmpty { QuestionsPanel.shared.questionsArrived() }
        return asked
    }

    func answer(_ id: String, _ answer: AgentQuestion.Answer?) {
        guard book.answer(id, answer) else { return }
        answeredHere.removeAll { $0 == id }
        if answer != nil { answeredHere.append(id) }
        try? commit()
    }

    /// Answers every open question the way its asker suggested (questions without a suggestion stay open).
    func answerAsSuggested() {
        for question in book.open { if let suggest = question.suggest { answer(question.id, suggest) } }
    }

    @discardableResult
    func remove(_ ids: Set<String>) throws -> Int {
        let gone = book.remove(ids)
        answeredHere.removeAll { ids.contains($0) }
        if gone > 0 { try commit() }
        return gone
    }

    private func commit() throws {
        try book.save(url)
        updateBadge()
    }

    /// The Dock icon says how many questions wait: noticed without anything popping up over other apps.
    private func updateBadge() {
        let count = book.open.count
        NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    static func json(_ question: AgentQuestion) -> [String: Any] {
        var out: [String: Any] = ["id": question.id, "from": question.from, "title": question.title,
                                  "asked": question.asked.ISO8601Format(), "tags": question.tags]
        if let why = question.why { out["why"] = why }
        if let suggest = question.suggest { out["suggest"] = suggest.rawValue }
        if let reason = question.reason { out["reason"] = reason }
        if let yes = question.yesLabel { out["yes"] = yes }
        if let no = question.noLabel { out["no"] = no }
        if let answer = question.answer { out["answer"] = answer.rawValue }
        if let answered = question.answered { out["answered"] = answered.ISO8601Format() }
        return out
    }
}

extension AgentCommands {
    /// ask: add or update questions; questions: the open ones (all: answered too); answer: set or clear an answer
    /// (as if clicked; for tests and other front ends); answers: answered ones, oldest first; ask-remove: let them go.
    func questionCommand(_ command: String, _ body: [String: Any]) throws -> [String: Any] {
        let desk = QuestionDesk.shared
        let asker = (body["from"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch command {
        case "ask":
            let raw = (body["questions"] as? [[String: Any]]) ?? [body]
            let questions = try raw.map { item -> AgentQuestion in
                guard let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
                    throw Failure(message: "A question needs a \"title\": the thing to decide, in one sentence.")
                }
                var suggest: AgentQuestion.Answer?
                if let value = item["suggest"] as? String, !value.isEmpty {
                    guard let parsed = AgentQuestion.Answer(rawValue: value.lowercased()) else {
                        throw Failure(message: "\"suggest\" is yes or no.")
                    }
                    suggest = parsed
                }
                let tags = (item["tags"] as? [String]) ?? (item["tags"] as? String)?.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
                func text(_ key: String) -> String? { (item[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
                return AgentQuestion(id: text("id") ?? UUID().uuidString.lowercased(),
                                     from: text("from") ?? asker ?? String(localized: "agent"), title: title,
                                     why: text("why"), suggest: suggest, reason: text("reason"), tags: tags,
                                     yesLabel: text("yes"), noLabel: text("no"), asked: .now)
            }
            return ["asked": try desk.ask(questions).map(QuestionDesk.json)]
        case "questions":
            let all = body["all"] as? Bool ?? false
            let list = (all ? desk.book.questions : desk.open)
                .filter { asker == nil || $0.from.caseInsensitiveCompare(asker!) == .orderedSame }
            return ["questions": list.map(QuestionDesk.json)]
        case "answer":
            guard let id = body["id"] as? String, desk.book.questions.contains(where: { $0.id == id }) else {
                throw Failure(message: "No question with that id.")
            }
            let value = (body["answer"] as? String)?.lowercased()
            guard value == nil || value == "clear" || AgentQuestion.Answer(rawValue: value!) != nil else {
                throw Failure(message: "\"answer\" is yes, no or clear.")
            }
            desk.answer(id, value.flatMap(AgentQuestion.Answer.init(rawValue:)))
            return ["question": desk.book.questions.first { $0.id == id }.map(QuestionDesk.json) ?? [:]]
        case "answers":
            return ["answers": desk.book.answered(from: asker).map(QuestionDesk.json)]
        default:  // ask-remove
            let ids = Set((body["ids"] as? [String]) ?? [body["id"] as? String].compactMap { $0 })
            guard !ids.isEmpty else { throw Failure(message: "Name the questions to remove (\"ids\").") }
            return ["removed": try desk.remove(ids)]
        }
    }
}
#endif
