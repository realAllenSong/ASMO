import Foundation

/// A spoken or typed instruction about something already on the list:
/// "把理发挪到明天下午三点", "删掉看房", "健身做完了", "把开会改成组会".
enum PlannerCommand: Equatable, Sendable {
    case move(target: String, to: PlanDate, endMinute: Int?)
    case delete(target: String)
    case complete(target: String)
    case rename(target: String, title: String)

    var target: String {
        switch self {
        case .move(let target, _, _), .delete(let target), .complete(let target), .rename(let target, _): target
        }
    }

    /// Recognizes a command; returns nil for ordinary new items. Runs before splitting into clauses.
    static func parse(_ text: String, clock: CaptureClock, defaultDay: PlanDate) -> PlannerCommand? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "。.!！")))
            .replacingOccurrences(of: #"^(?:请|帮我|麻烦)\s*"#, with: "", options: .regularExpression)
        if let parts = source.match(#"^把\s*(.+?)\s*(?:改名为|改名成|重命名为|改叫)\s*(.+)$"#) {
            return .rename(target: parts[1], title: parts[2])
        }
        if let parts = source.match(#"^把\s*(.+?)\s*(?:挪到|移到|放到|改到|推迟到|推到|提前到|调到|换到|安排到|改成|改为)\s*(.+)$"#) {
            let phrase = parts[2].replacingOccurrences(of: #"(?:去|吧|了|做)$"#, with: "", options: .regularExpression)
            if let (date, end) = CaptureParser.explicitSchedule(phrase, clock: clock, selectedDay: defaultDay) {
                return .move(target: parts[1], to: date, endMinute: end)
            }
            // "把开会改成组会": not a date, so it is a new name.
            if source.contains("改成") || source.contains("改为") {
                return .rename(target: parts[1], title: parts[2])
            }
            return nil
        }
        if let parts = source.match(#"^(?:删掉|删除|删了|去掉|取消|不做了?)\s*(.+)$"#) {
            return .delete(target: parts[1])
        }
        if let parts = source.match(#"^(.+?)\s*(?:不做了|取消了|删掉吧|删了吧)$"#) {
            return .delete(target: parts[1])
        }
        if let parts = source.match(#"^(?:完成了?|做完了?|搞定了?|勾掉)\s*(.+)$"#) {
            return .complete(target: parts[1])
        }
        if let parts = source.match(#"^(.+?)\s*(?:做完了|完成了|搞定了|弄完了|已完成)$"#) {
            return .complete(target: parts[1])
        }
        return nil
    }

    /// Picks the item a command refers to by its words. Prefers exact and containing matches, then
    /// the closest upcoming day. Returns nil when nothing is a reasonable match.
    static func bestMatch<T>(_ target: String, among items: [T], title: (T) -> String, day: (T) -> PlanDate?,
                             today: PlanDate) -> T? {
        let wanted = normalize(target)
        guard !wanted.isEmpty else { return nil }
        let scored = items.compactMap { item -> (T, Int, Int)? in
            let name = normalize(title(item))
            guard !name.isEmpty else { return nil }
            let score: Int
            if name == wanted { score = 1000 }
            else if name.contains(wanted) { score = 600 + wanted.count * 10 - name.count }
            else if wanted.contains(name) { score = 500 + name.count * 10 }
            else {
                let shared = Set(wanted).intersection(Set(name)).count
                guard shared * 3 >= max(2, wanted.count * 2) else { return nil }
                score = shared * 10
            }
            let distance: Int
            if let date = day(item)?.dayOnly {
                distance = date < today ? 400 + abs(date.ordinal - today.ordinal) : date.ordinal - today.ordinal
            } else {
                distance = 300
            }
            return (item, score, distance)
        }
        return scored.max { ($0.1, -$0.2) < ($1.1, -$1.2) }?.0
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: #"[\s「」“”"'，,。.：:的]"#, with: "", options: .regularExpression)
    }
}

private extension PlanDate {
    /// A rough day number, good enough to compare closeness of dates.
    var ordinal: Int { year * 372 + month * 31 + (day ?? 0) }
}
