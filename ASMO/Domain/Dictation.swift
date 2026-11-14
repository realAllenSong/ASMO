import Foundation

/// One thing heard or typed in a single breath, after splitting: a dated item or a repeating routine.
enum DictatedItem: Sendable {
    case task(CaptureDraft)
    case routine(RoutineDraft)
}

struct RoutineDraft: Sendable, Equatable {
    var title: String
    /// Calendar weekdays (1 = Sunday … 7 = Saturday). All seven means every day.
    var weekdays: Set<Int>
    var startMinute: Int?
    var endMinute: Int?
}

/// Turns free speech or a run-on line into separate items, all on-device and without a model:
/// "今天下午三点开会，明天交材料，下周二练胸和肩" → three items on three days.
/// A clause without its own date inherits the date of the clause before it; the first falls back to `defaultDay`.
enum Dictation {
    static func items(_ text: String, clock: CaptureClock, defaultDay: PlanDate) -> [DictatedItem] {
        var current = defaultDay.dayOnly
        var items: [DictatedItem] = []
        for clause in clauses(text) {
            if let routine = RoutineParser.parse(clause, clock: clock) {
                items.append(.routine(routine))
                continue
            }
            var draft = CaptureParser.manual(clause, clock: clock, selectedDay: current)
            draft.title = cleanTitle(draft.title)
            guard !draft.title.isEmpty, !isFiller(draft.title) else { continue }
            if let day = draft.schedule, day.day != nil { current = day.dayOnly }
            items.append(.task(draft))
        }
        return items
    }

    /// Marks a line typed on the page: it becomes one item with the writer's words exactly as typed (only a date
    /// or time in it is read). Never cleaned, split, matched to other items or taken as a command.
    static let verbatimMarker = "\u{1D}"

    /// Marks a piece the organizer already wrote as exactly one item ("<date> <HH:MM-HH:MM> <title>"):
    /// it is read whole — never split at "、" or "和", never taken as a command.
    static let wholeMarker = "\u{1E}"

    /// One organizer-written item: date and time words are read, the rest is the title as written.
    static func item(_ phrase: String, clock: CaptureClock, defaultDay: PlanDate) -> DictatedItem? {
        let text = phrase.replacingOccurrences(of: wholeMarker, with: "").trimmed
        if let routine = RoutineParser.parse(text, clock: clock) { return .routine(routine) }
        var draft = CaptureParser.manual(text, clock: clock, selectedDay: defaultDay.dayOnly)
        draft.title = cleanTitle(draft.title)
        guard !draft.title.isEmpty, !isFiller(draft.title) else { return nil }
        return .task(draft)
    }

    /// Splits on sentence punctuation, connectors, and on a second date word inside one clause.
    static func clauses(_ text: String) -> [String] {
        let separators = #"[\n。；;！!？?，,、]+|\s*(?:然后|还有|另外|接着|之后再|再就是|以及)\s*"#
        let rough = text.replacingOccurrences(of: separators, with: "\u{1F}", options: .regularExpression)
            .split(separator: "\u{1F}").map { String($0).trimmed }.filter { !$0.isEmpty }
        let dateWord = #"(?:大后天|后天|明天|今天|今晚|明早|(?:下下|下|这|本)?(?:周|星期|礼拜)[一二三四五六日天]|\d{1,2}月\d{1,2}[日号]|[一二三四五六七八九十]+月[一二三四五六七八九十]+[日号])(?!的)"#
        guard let regex = try? NSRegularExpression(pattern: dateWord) else { return rough }
        return rough.flatMap { clause -> [String] in
            let text = clause as NSString
            let starts = regex.matches(in: clause, range: NSRange(location: 0, length: text.length))
                .map(\.range.location).filter { $0 > 0 }
            guard !starts.isEmpty else { return [clause] }
            var pieces: [String] = []
            var from = 0
            for start in starts {
                let piece = text.substring(with: NSRange(location: from, length: start - from)).trimmed
                // Keep "我明天…" together: only split once the earlier piece says something on its own.
                if piece.count >= 3 && !isFiller(cleanTitle(piece)) {
                    pieces.append(piece)
                    from = start
                }
            }
            pieces.append(text.substring(from: from).trimmed)
            return pieces.filter { !$0.isEmpty }
        }
    }

    /// Two titles name the same thing ("ICLR 论文 rebuttal" / "rebuttal", "理发" / "理发 "): one contains most of the
    /// other, or they share most of their character pairs. Different wording ("剪头发" / "理发") is the model's job.
    static func sameThing(_ a: String, _ b: String) -> Bool {
        func normal(_ text: String) -> [Character] {
            var value = text.lowercased()
            for filler in ["一下", "一个", "进行", "一波", "这个", "那个", "去", "做", "的", "了"] {
                value = value.replacingOccurrences(of: filler, with: "")
            }
            return Array(value.filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol })
        }
        let x = normal(a), y = normal(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        let (short, long) = x.count <= y.count ? (x, y) : (y, x)
        if short.count >= 2, String(long).contains(String(short)), Double(short.count) / Double(long.count) >= 0.5 { return true }
        guard short.count >= 3 else { return false }
        func pairs(_ c: [Character]) -> Set<String> { Set(zip(c, c.dropFirst()).map { String([$0, $1]) }) }
        let p = pairs(x), q = pairs(y)
        return Double(p.intersection(q).count) / Double(p.union(q).count) >= 0.6
    }

    static func cleanTitle(_ title: String) -> String {
        var value = title.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        // Only filler and pronouns; words like 准备/需要 carry meaning ("准备 rebuttal") and stay.
        let lead = #"^(?:之前|以前|那个|就是|嗯+|呃+|然后|我们|我|还要|还得|要(?=.{2})|得(?=.{2})|记得|记一下|帮我记)\s*"#
        for _ in 0..<3 {
            let next = value.replacingOccurrences(of: lead, with: "", options: .regularExpression)
            if next == value { break }
            value = next
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func isFiller(_ text: String) -> Bool {
        text.count < 2 && text.allSatisfy { !$0.isLetter || "嗯啊呃哦哈".contains($0) }
            || ["嗯", "啊", "呃", "好", "好的", "就这些", "没了", "就这样"].contains(text)
    }
}

enum RoutineParser {
    /// Recognizes "每天八点做大眼操", "每周一四练胸和肩", "工作日 7:30 跑步", "周末睡懒觉" (with a 每/周末/工作日 lead).
    /// "喝水 #每天" → "每天 喝水": a repeat written as a tag at the end reads like one at the start.
    static func tagFirst(_ text: String) -> String {
        guard let parts = text.trimmed.match(#"^(.*?)\s*[#＃]\s*(每天|每日|天天|工作日|周末|每周(?:[一二三四五六日天][、和,，\s]*)+)\s*$"#),
              !parts[1].trimmed.isEmpty else { return text }
        // As a tag, "周末" / "工作日" mean every weekend / workday.
        let rule = parts[2].trimmed == "周末" ? "每个周末" : parts[2].trimmed == "工作日" ? "每个工作日" : parts[2].trimmed
        return rule + " " + parts[1].trimmed
    }

    static func parse(_ text: String, clock: CaptureClock) -> RoutineDraft? {
        var source = tagFirst(text).trimmed.replacingOccurrences(of: #"^(?:我们|我)\s*"#, with: "", options: .regularExpression)
        let everyDay = #"^(?:每天|每日|天天|每一天|每晚|每早|每天早上|every day|daily)\s*"#
        let weekdays: Set<Int>
        if let lead = source.match(everyDay)?.first {
            weekdays = Set(1...7)
            // "每晚十点" / "每早七点" keep their part of day for the time parser.
            let keep = lead.hasPrefix("每晚") ? "晚上" : lead.hasPrefix("每早") || lead.hasPrefix("每天早上") ? "早上" : ""
            source = keep + String(source.dropFirst(lead.count))
        } else if let lead = source.match(#"^(?:每个?工作日|工作日(?:每天)?|weekdays)\s*"#)?.first {
            weekdays = [2, 3, 4, 5, 6]
            source = String(source.dropFirst(lead.count))
        } else if let lead = source.match(#"^(?:每个?周末|周末每天)\s*"#)?.first {
            weekdays = [1, 7]
            source = String(source.dropFirst(lead.count))
        } else if let parts = source.match(#"^每(?:个)?(?:周|星期|礼拜)((?:[一二三四五六日天][、和,，\s]*)+)"#) {
            let map: [Character: Int] = ["日": 1, "天": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7]
            weekdays = Set(parts[1].compactMap { map[$0] })
            source = String(source.dropFirst(parts[0].count))
        } else {
            return nil
        }
        guard !weekdays.isEmpty else { return nil }
        let draft = CaptureParser.manual(source, clock: clock, selectedDay: clock.today)
        let title = Dictation.cleanTitle(draft.title)
        guard !title.isEmpty else { return nil }
        let start = draft.schedule?.hour.map { $0 * 60 + (draft.schedule?.minute ?? 0) }
        return RoutineDraft(title: title, weekdays: weekdays, startMinute: start, endMinute: start == nil ? nil : draft.endMinute)
    }

    static func label(_ weekdays: Set<Int>) -> String {
        if weekdays.count == 7 { return String(localized: "每天") }
        if weekdays == [2, 3, 4, 5, 6] { return String(localized: "工作日") }
        if weekdays == [1, 7] { return String(localized: "周末") }
        let order = [2, 3, 4, 5, 6, 7, 1].filter(weekdays.contains)
        // In an English interface (the phrase above has a translation): "Mon, Thu".
        if String(localized: "每天") != "每天" {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: "en_US")
            return order.map { calendar.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
        }
        let names = [2: "一", 3: "二", 4: "三", 5: "四", 6: "五", 7: "六", 1: "日"]
        return "每周" + order.compactMap { names[$0] }.joined()
    }
}

/// One item from a free-form draft, with its subtasks.
struct OutlineItem: Sendable {
    var item: DictatedItem
    var children: [OutlineItem] = []
    /// Index of the non-empty draft line this came from.
    var line = 0
}

extension Dictation {
    /// Reads a free-form draft the way a person writes in a doc: one thing per line (or several, split by
    /// punctuation), indentation or "-" bullets nest under the line above, a date on a parent carries to its children.
    static func outline(_ text: String, clock: CaptureClock, defaultDay: PlanDate) -> [OutlineItem] {
        struct Line { var level: Int; var text: String }
        let lines: [Line] = text.components(separatedBy: .newlines).compactMap { raw in
            var indent = 0
            var rest = Substring(raw)
            while let first = rest.first, first == " " || first == "\t" || first == "\u{3000}" {
                indent += first == "\t" ? 4 : first == "\u{3000}" ? 2 : 1
                rest = rest.dropFirst()
            }
            var body = String(rest).trimmed
            body = body.replacingOccurrences(of: #"^(?:[-–—*•·]|\d+[.、)]|[(（]?\d+[)）]|\[[ xX]?\]|☐|☑)\s*"#, with: "",
                                             options: .regularExpression)
            guard !body.trimmed.isEmpty else { return nil }
            return Line(level: indent / 2, text: body)
        }
        var roots: [OutlineItem] = []
        // Path from the root to the most recent item at each level: (level, index path).
        var stack: [(level: Int, path: [Int], day: PlanDate)] = []
        for (lineIndex, line) in lines.enumerated() {
            while let top = stack.last, top.level >= line.level { stack.removeLast() }
            let parent = stack.last
            // Each new top-level line belongs to the page's day unless it names another one.
            let base = parent?.day ?? defaultDay.dayOnly
            let items = Self.items(line.text, clock: clock, defaultDay: base)
            for item in items {
                let node = OutlineItem(item: item, line: lineIndex)
                var path: [Int]
                if let parent {
                    path = parent.path
                    let index = append(node, at: parent.path, in: &roots)
                    path.append(index)
                } else {
                    roots.append(node)
                    path = [roots.count - 1]
                }
                var day = base
                if case .task(let draft) = item, let schedule = draft.schedule, schedule.day != nil { day = schedule.dayOnly }
                if item == items.last {
                    stack.append((line.level, path, day))
                }
            }
        }
        return roots
    }

    private static func append(_ node: OutlineItem, at path: [Int], in roots: inout [OutlineItem]) -> Int {
        guard let first = path.first else { roots.append(node); return roots.count - 1 }
        return insert(node, path: path.dropFirst(), into: &roots[first])
    }

    private static func insert(_ node: OutlineItem, path: ArraySlice<Int>, into parent: inout OutlineItem) -> Int {
        guard let first = path.first else {
            parent.children.append(node)
            return parent.children.count - 1
        }
        return insert(node, path: path.dropFirst(), into: &parent.children[first])
    }
}

extension DictatedItem: Equatable {
    static func == (lhs: DictatedItem, rhs: DictatedItem) -> Bool {
        switch (lhs, rhs) {
        case (.task(let a), .task(let b)): a.id == b.id
        case (.routine(let a), .routine(let b)): a == b
        default: false
        }
    }
}

extension Dictation {
    /// The writing names this hour somehow: "15:00", "3点", "三点", "下午3:30", "3pm", "十二点半"…
    static func clockGrounded(_ hhmm: String, in source: String) -> Bool {
        guard let hour = Int(hhmm.prefix(2)) else { return false }
        let numerals = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "十一", "十二"]
        var forms: Set<String> = [String(hour), String(format: "%02d", hour)]
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        forms.insert(String(twelve))
        var chinese = [numerals[twelve]]
        if twelve == 2 { chinese.append("两") }
        if hour == 0 { chinese.append("零") }
        let text = source.lowercased()
        for form in forms {
            if text.range(of: "(?<![0-9])\(form)\\s*(:|：|点|時|时|pm|am|p\\.m|a\\.m|o'?clock)", options: .regularExpression) != nil { return true }
        }
        for form in chinese where text.range(of: "(?<![十])\(form)(点|點)", options: .regularExpression) != nil { return true }
        // "中午" is noon, "半夜/午夜" midnight.
        if hour == 12, text.contains("中午") { return true }
        return false
    }

}
