import Foundation

/// A yes/no question an agent leaves for the person (`asmo ask`): "keep this rule?", "use this name?". It waits in a
/// small panel beside the planner until the person answers with ✓ or ✗; the agent reads the answer back
/// (`asmo answers`) and then lets the question go (`asmo ask rm`). Nothing here is a to-do: questions never land on a
/// day, never roll forward and never count as unfinished work.
struct AgentQuestion: Codable, Equatable, Identifiable, Sendable {
    enum Answer: String, Codable, Sendable { case yes, no }

    /// The asker's own key ("rosetta:fact:1013"): asking again with the same id updates the question in place.
    var id: String
    /// Who asks, shown on the card ("Rosetta").
    var from: String
    /// The thing to decide, one plain sentence.
    var title: String
    /// Why it is asked (where it came from, what changes if kept).
    var why: String?
    /// What the asker would do, and why.
    var suggest: Answer?
    var reason: String?
    /// Small labels on the card ("规则", "所有项目").
    var tags: [String] = []
    /// The words on the two buttons; "是" / "否" when the asker gives none.
    var yesLabel: String?
    var noLabel: String?
    var asked: Date
    var answer: Answer?
    var answered: Date?

    var isOpen: Bool { answer == nil }
}

/// The questions, kept in one JSON file next to the store. The app is the only writer (agents go through it), so a
/// plain file is enough, needs no change to the store's schema and never syncs to other devices.
struct AgentQuestionBook: Codable, Equatable, Sendable {
    var questions: [AgentQuestion] = []

    static let limit = 200

    var open: [AgentQuestion] { questions.filter(\.isOpen) }

    /// Adds a question, or updates the one with the same id. Asking again keeps an answer the person already gave
    /// unless the question itself changed (then it is asked afresh).
    @discardableResult
    mutating func ask(_ question: AgentQuestion) -> AgentQuestion {
        var question = question
        question.title = question.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = questions.firstIndex(where: { $0.id == question.id }) {
            let old = questions[index]
            if old.title == question.title && old.why == question.why {
                question.answer = old.answer
                question.answered = old.answered
                question.asked = old.asked
            }
            questions[index] = question
        } else {
            questions.append(question)
            if questions.count > Self.limit {
                // The oldest answered ones go first; open questions are only dropped when nothing else is left.
                if let answered = questions.firstIndex(where: { !$0.isOpen }) { questions.remove(at: answered) }
                else { questions.removeFirst() }
            }
        }
        return question
    }

    /// The person's ✓ / ✗, or nil to take it back (the card comes back as a question).
    @discardableResult
    mutating func answer(_ id: String, _ answer: AgentQuestion.Answer?, at now: Date = .now) -> Bool {
        guard let index = questions.firstIndex(where: { $0.id == id }) else { return false }
        questions[index].answer = answer
        questions[index].answered = answer == nil ? nil : now
        return true
    }

    /// Takes questions away (answered and read back, or settled elsewhere). Returns how many went.
    @discardableResult
    mutating func remove(_ ids: Set<String>) -> Int {
        let before = questions.count
        questions.removeAll { ids.contains($0.id) }
        return before - questions.count
    }

    /// Answered questions, oldest answer first, optionally only one asker's.
    func answered(from asker: String? = nil) -> [AgentQuestion] {
        questions.filter { !$0.isOpen && (asker == nil || $0.from.caseInsensitiveCompare(asker!) == .orderedSame) }
            .sorted { ($0.answered ?? .distantPast) < ($1.answered ?? .distantPast) }
    }

    /// Answers older than `keep` that nobody read back: the asker is gone; let them go so the file stays small.
    mutating func forgetStale(now: Date = .now, keep: TimeInterval = 30 * 86_400) {
        questions.removeAll { !$0.isOpen && now.timeIntervalSince($0.answered ?? now) > keep }
    }

    static func load(_ url: URL) -> AgentQuestionBook {
        guard let data = try? Data(contentsOf: url) else { return AgentQuestionBook() }
        return (try? decoder.decode(AgentQuestionBook.self, from: data)) ?? AgentQuestionBook()
    }

    func save(_ url: URL) throws {
        try Self.encoder.encode(self).write(to: url, options: .atomic)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
