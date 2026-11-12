import Foundation

/// What the organizer knows besides the writing: today, the page's day, and the items already there (numbered
/// E1, E2… so the model can say "this is E3 again").
struct OrganizeContext: Sendable {
    /// The context half of the model's message.
    var prompt: String
    /// "E1" → "task:UUID" / "routine:UUID".
    var refs: [String: String]
}

/// One organizer item.
struct OrganizerItem: Sendable {
    var title: String
    var date: String
    var start: String
    var end: String
    var done: Bool
    var under: Int
    var same: String
}

/// Organizes free writing: Apple Intelligence where the system has it, otherwise the rules. Nothing is downloaded.
@MainActor
final class PageOrganizer {
    static let shared = PageOrganizer()

    /// A model can read whole passages (Apple Intelligence); without it, lines are judged by rules.
    var canOrganize: Bool { AppleJudge.isAvailable }

    /// Apple Intelligence's reading of a whole passage, with context. Nil without it (or when its answer is unusable).
    func extract(_ text: String, context: OrganizeContext) async -> (items: [OrganizerItem], keep: String)? {
        await AppleJudge.extract(text, context: context.prompt)
    }

    /// Organizes finished lines of a page. With a model, the lines are read together as one passage (a spoken
    /// paragraph keeps its context: times said before the activity, repeats, asides) and checked against the
    /// items already there; without one, line by line by rules.
    func judge(_ lines: [String], context: OrganizeContext?, clock: CaptureClock = CaptureClock()) async -> [LineJudgement] {
        guard let context, !lines.isEmpty else { return await judge(lines) }
        let text = lines.joined(separator: "\n")
        let started = Date.now
        guard let found = await extract(text, context: context) else { return await judge(lines) }
        #if DEBUG
        Self.debugLog(String(format: "extract %.1fs\n", Date.now.timeIntervalSince(started)) + context.prompt + "\n» " + text + "\n"
            + found.items.map { "  [\($0.date)] \($0.start)-\($0.end) \($0.title)\($0.done ? " ✓" : "")\($0.under >= 0 ? " ↳\($0.under)" : "")\($0.same.isEmpty ? "" : " =" + $0.same)" }
                .joined(separator: "\n") + "\n  keep: " + found.keep)
        #endif
        return Self.judgements(items: found.items, keep: found.keep, lines: lines, context: context, clock: clock)
    }

    /// The model's items as page judgements: everything belongs to the first line (the lines were one passage);
    /// the other lines are taken off the page. With no items at all, the lines stay as written.
    static func judgements(items: [OrganizerItem], keep: String, lines: [String], context: OrganizeContext,
                           clock: CaptureClock) -> [LineJudgement] {
        let source = lines.joined(separator: "\n")
        var pieces: [String] = [], done: [Bool] = [], subs: [Bool] = [], sources: [String] = [], targets: [String?] = []
        var kept: [Int: Int] = [:]
        var lineOfLastTop: Int?
        func depth(_ line: String) -> Int { line.prefix { $0 == "\t" }.count }
        for (index, raw) in items.enumerated() {
            let item = normalized(raw, at: index)
            var title = keepNumbers(stripClockWords(item.title.trimmed), in: source)
            // With a time, a leading part of day is already said by it ("晚上冥想" at 22:00 → "冥想").
            if clockText(item.start) != nil {
                let bare = title.replacingOccurrences(of: #"^(?:早上|上午|中午|下午|傍晚|晚上|今晚|早晨)\s*"#, with: "", options: .regularExpression)
                if bare.count >= 2 { title = bare }
            }
            guard !title.isEmpty else { continue }
            // A feeling listed both as an item and as the thought to keep is a thought.
            if !keep.isEmpty, keep.contains(title) || Dictation.sameThing(title, keep) { continue }
            // "Same as E3" only counts when the writing really talks about it: a small model sometimes echoes
            // items from its context that weren't mentioned at all. Those are dropped.
            let ref = item.same.isEmpty ? nil : context.refs[item.same.trimmed]
            if ref != nil, !grounded(title, in: source, threshold: 0.5) { continue }
            // A new item has to come from the writing; anything invented is dropped. Rewording is fine
            // ("理发" → "剪头发" shares a third of its characters), a made-up item shares almost none.
            guard ref != nil || grounded(title, in: source, threshold: 0.34) else { continue }
            var words: [String] = []
            // The line itself says how it repeats ("工作日 晚上十点冥想", "喝水 #每天"): that wins over the model's date.
            if let from = lineIndex(of: title, in: lines),
               let rule = RoutineParser.parse(lines[from].trimmingCharacters(in: .whitespaces), clock: clock) {
                words.append(rule.weekdays.count == 7 ? "每天" : rule.weekdays == [2, 3, 4, 5, 6] ? "每个工作日"
                             : rule.weekdays == [1, 7] ? "每个周末" : RoutineParser.label(rule.weekdays))
            } else if let date = absoluteDate(item.date, clock: clock) { words.append(date) }
            // A time has to be in the writing too: the model sometimes copies one from a context item.
            if let start = clockText(item.start), Dictation.clockGrounded(start, in: source) {
                words.append(clockText(item.end).flatMap { Dictation.clockGrounded($0, in: source) ? start + "-" + $0 : nil } ?? start)
            }
            words.append(title)
            kept[index] = pieces.count
            pieces.append(Dictation.wholeMarker + words.joined(separator: " "))
            // "Done" needs the words for it in the sentence about this item ("剪了", "已经弄好了");
            // "一点半理发，这个已经没问题了" is settled, not done.
            done.append(item.done && doneEvidence(for: title, in: source))
            // Written indented (a sub-bullet) under a line that gave an item: it's that item's subtask.
            let from = lineIndex(of: title, in: lines)
            var indented = false
            if let from, let top = lineOfLastTop, pieces.count > 1 { indented = depth(lines[from]) > depth(lines[top]) }
            let sub = indented || (item.under >= 0 && item.under < index && kept[item.under] != nil)
            subs.append(sub)
            if !sub { lineOfLastTop = from }
            sources.append(pieces.last!)
            targets.append(ref)
        }
        guard !pieces.isEmpty else { return lines.map { _ in LineJudgement(isNote: true, pieces: [], sub: false) } }
        // Links are kept: one the model left out goes back on the item written in the same sentence.
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let clauses = sentences(source)
            for match in detector.matches(in: source, range: NSRange(location: 0, length: (source as NSString).length)) {
                guard let range = Range(match.range, in: source) else { continue }
                let url = String(source[range])
                guard !pieces.contains(where: { $0.contains(url) }) else { continue }
                let clause = clauses.first { $0.contains(url) } ?? source
                let around = Set(clause.replacingOccurrences(of: url, with: "").lowercased())
                let best = pieces.indices.max { a, b in
                    Set(pieces[a].lowercased()).intersection(around).count < Set(pieces[b].lowercased()).intersection(around).count
                } ?? 0
                pieces[best] += " " + url
            }
        }
        // What isn't a thing to do stays on the page as written thought (never silently lost).
        // …but not the passage echoed back, or a thought that is really one of the items.
        let thought = keep.trimmed
        let echoed = thought.count > source.count / 2
            || pieces.contains { piece in
                let title = piece.replacingOccurrences(of: Dictation.wholeMarker, with: "").split(separator: " ").last.map(String.init) ?? ""
                return title.count >= 2 && thought.contains(title)
            }
        // A "thought" that is only when ("每天下午两点到两点半") is no thought.
        let onlyWhen = thought.replacingOccurrences(of: clockWords, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).count < 2
        let note = thought.isEmpty || Self.isFiller(thought) || echoed || onlyWhen ? nil : thought
        let first = LineJudgement(isNote: false, pieces: pieces, sub: false, done: done, pieceSub: subs, sources: sources,
                                  noteText: note, targets: targets)
        return [first] + lines.dropFirst().map { _ in LineJudgement(isNote: false, pieces: [], sub: false, drop: true) }
    }

    /// The written line an item came from (most characters in common).
    static func lineIndex(of title: String, in lines: [String]) -> Int? {
        let letters = Set(title.lowercased())
        let scored = lines.indices.map { ($0, Set(lines[$0].lowercased()).intersection(letters).count) }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }

    /// Small-model slips: an item "under" itself (counted from 1), a lone time written as the end.
    static func normalized(_ item: OrganizerItem, at index: Int) -> OrganizerItem {
        var item = item
        if item.under == index { item.under = index - 1 }
        if !(0..<index).contains(item.under) { item.under = -1 }
        if clockText(item.start) == nil, clockText(item.end) != nil { item.start = item.end; item.end = "" }
        return item
    }

    /// The model reads dates against the real today (it is told the date), so they are resolved here, before the
    /// page (whose own "明天" means the day after the page) sees them: "明天" → "11月9日". Repeats stay as words.
    static func absoluteDate(_ words: String, clock: CaptureClock) -> String? {
        let value = words.trimmed
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("每") { return value }
        let parsed = CaptureParser.manual(value + " x", clock: clock, selectedDay: clock.today)
        guard let day = parsed.schedule, day.day != nil else { return nil }
        return "\(day.month)月\(day.day ?? 1)日"
    }

    /// "早上八点喝水" → "喝水": the time is in its own field.
    static let clockWords = #"^(?:(?:今天|明天|每天)?(?:早上|上午|中午|下午|傍晚|晚上|今晚)?(?:[零一二两三四五六七八九十\d]{1,3}[点:：](?:半|[零一二三四五六七八九十\d]{1,2}分?)?)(?:到|-|–|至)?)+\s*"#

    /// The model shortened a title the writing had a number on ("自重深蹲100" → "自重深蹲"): put the number back.
    static func keepNumbers(_ title: String, in source: String) -> String {
        let pattern = NSRegularExpression.escapedPattern(for: title) + #"\s*(\d+(?:\.\d+)?\s*(?:次|个|组|下|分钟|公里|km|页|遍|杯|ml|k)?)"#
        guard let range = source.range(of: pattern, options: .regularExpression) else { return title }
        let tail = source[range].dropFirst(title.count).trimmingCharacters(in: .whitespaces)
        return tail.isEmpty ? title : title + tail
    }

    static func stripClockWords(_ title: String) -> String {
        let pattern = clockWords
        let stripped = title.replacingOccurrences(of: pattern, with: "", options: .regularExpression).trimmed
        return stripped.isEmpty ? title : stripped
    }

    /// The clause that talks about this item says it already happened.
    static func doneEvidence(for title: String, in source: String) -> Bool {
        let letters = Set(title.lowercased().filter { $0.isLetter })
        let clauses = sentences(source)
        let scored = clauses.map { clause in (clause, Set(clause.lowercased()).intersection(letters).count) }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return false }
        // The clause with the item, and the one right after it ("理发，已经剪了").
        let index = clauses.firstIndex(of: best.0) ?? 0
        let around = clauses[index...].prefix(2).joined(separator: "，")
        guard around.range(of: #"(没问题|安排好|约好|定了|定好)"#, options: .regularExpression) == nil
                || saysDone(best.0) else { return false }
        return saysDone(around) || around.range(of: #"(好了|完了|做完|弄完|搞定|剪了|结束了|done|finished)"#,
                                                  options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "9:00", "09:00", "14:30" → "HH:MM"; anything else → nil.
    static func clockText(_ text: String) -> String? {
        let parts = text.trimmed.replacingOccurrences(of: "：", with: ":").split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }

    /// One judgement per finished line of free writing (task vs note, pieces, done, belongs to the line above).
    /// Long lines (a spoken paragraph) are cut into clauses first so the model sees one thought at a time.
    /// Uses the model when ready; every unit it skips (or all of them, without the model) is judged by rules.
    func judge(_ lines: [String]) async -> [LineJudgement] {
        var units: [String] = []
        var owner: [Int] = []
        for (index, line) in lines.enumerated() {
            let parts = line.count > 24 ? Self.sentences(line) : [line]
            // Pure filler ("对了", "嗯", "然后") is not a thing to do or a thought worth keeping.
            for part in parts.isEmpty ? [line] : parts where !Self.isFiller(part) { units.append(part); owner.append(index) }
        }
        let unitJudgements = await judgeUnits(units)
        #if DEBUG
        Self.debugLog("judge units=\(units.count)\n"
            + zip(units, unitJudgements).map { "  \($0) → \($1.isNote ? "NOTE" : $1.pieces.joined(separator: " | "))" }.joined(separator: "\n"))
        #endif
        return lines.indices.map { index in
            let mine = units.indices.filter { owner[$0] == index }
            var pieces: [String] = []
            var done: [Bool] = []
            var subs: [Bool] = []
            var sources: [String] = []
            var notes: [String] = []
            for unit in mine {
                let judgement = unitJudgements[unit]
                if judgement.isNote || Self.isAside(units[unit]) { notes.append(units[unit]); continue }
                for (offset, piece) in judgement.pieces.enumerated() {
                    // "开会 记得带上数据": the reminder part is a subtask of the item, whatever the model said.
                    let parts = Self.splitReminder(piece)
                    for (partIndex, part) in parts.enumerated() {
                        pieces.append(part)
                        done.append(judgement.done.first ?? false)
                        sources.append(units[unit])
                        // Only a unit after another item can hang under it.
                        subs.append(partIndex > 0 || (offset == 0 && judgement.sub && !subs.isEmpty))
                    }
                }
            }
            if pieces.isEmpty { return LineJudgement(isNote: true, pieces: [], sub: false) }
            return LineJudgement(isNote: false, pieces: pieces, sub: mine.first.map { unitJudgements[$0].sub } ?? false,
                                 done: done, pieceSub: subs, sources: sources,
                                 noteText: notes.isEmpty ? nil : notes.joined(separator: "；"))
        }
    }

    #if DEBUG
    static func debugLog(_ text: String) {
        let url = AppPaths.caches.appendingPathComponent("asmo-judge.log")
        let line = "[\(Date.now.formatted(date: .omitted, time: .standard))] " + text + "\n"
        if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
        else { try? Data(line.utf8).write(to: url) }
    }
    #endif

    /// Comments about what was just said ("这是有氧", "以后顺延", "也没时间") are not things to do.
    static func isAside(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return value.range(of: #"^(这是|那是|因为|所以|也没时间|没时间|太在意|本来|但是?(还)?没(有)?(做|弄|去)|(以后|之后|改天)?(再)?顺延(到(以后|明天|后天|下周))?$|以后再说)"#,
                           options: .regularExpression) != nil
    }

    static func splitReminder(_ text: String) -> [String] {
        guard let range = text.range(of: #"[\s，,]+(?=(记得|顺便|别忘了?|别忘记))"#, options: .regularExpression),
              range.lowerBound > text.startIndex else { return [text] }
        let head = String(text[..<range.lowerBound]).trimmed
        let tail = String(text[range.upperBound...]).replacingOccurrences(of: #"^(记得|别忘了?|别忘记)"#, with: "", options: .regularExpression).trimmed
        return head.isEmpty || tail.isEmpty ? [text] : [head, tail]
    }

    static func isFiller(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return value.isEmpty || value.range(of: #"^(对了|对|嗯+|呃+|啊|哦|然后|还有|另外|就是|那个|好的?|ok|OK)$"#,
                                            options: .regularExpression) != nil
    }

    /// "打了篮球", "做了大眼操", "练了背", "已经交了": the activity already happened. ("要是定了" is a condition, not done.)
    static func saysDone(_ text: String) -> Bool {
        guard text.range(of: #"(要是|如果|假如|没)"#, options: .regularExpression) == nil else { return false }
        return text.range(of: #"(打了|做了|练了|去了|跑了|游了|写了|看了|交了|舒展了|拉伸了|完成了|搞定了|弄完了|已经)"#,
                          options: .regularExpression) != nil
    }

    /// Sentences and comma clauses, keeping lists ("篮球、乒乓") and date words with their phrase.
    static func sentences(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "。；;！!？?，,\n"))
            .map(\.trimmed).filter { !$0.isEmpty }
    }

    private func judgeUnits(_ lines: [String]) async -> [LineJudgement] {
        guard !lines.isEmpty else { return [] }
        let rules = lines.map { LineJudgement(isNote: NoteRule.looksLikeNote($0, heading: false), pieces: [$0], sub: false,
                                              done: [Self.saysDone($0)]) }
        // Apple Intelligence first: built in, no download.
        if let apple = await AppleJudge.judge(lines), !apple.isEmpty {
            var byLine: [Int: UnitVerdict] = [:]
            for verdict in apple where lines.indices.contains(verdict.index) { byLine[verdict.index] = verdict }
            return lines.indices.map { index in
                guard let verdict = byLine[index] else { return rules[index] }
                if verdict.isNote { return LineJudgement(isNote: true, pieces: [], sub: false) }
                let pieces = verdict.pieces.map(\.trimmed).filter { !$0.isEmpty }
                return LineJudgement(isNote: false, pieces: pieces.isEmpty ? [lines[index]] : pieces, sub: verdict.sub,
                                     done: [verdict.done || Self.saysDone(lines[index])])
            }
        }
        return rules
    }

    /// Most of the piece's characters appear in the source (rewording like "可能选BOA" → "选择BOA" still passes).
    static func grounded(_ piece: String, in source: String, threshold: Double = 0.6) -> Bool {
        let letters = piece.filter { !$0.isWhitespace && !$0.isPunctuation }
        guard !letters.isEmpty else { return false }
        let pool = Set(source.lowercased())
        let hits = letters.lowercased().filter { pool.contains($0) }.count
        return Double(hits) / Double(letters.count) >= threshold
    }
}

/// The organizer's instructions (tuned with the eval cases the app was built on).
enum OrganizerPrompt {
    static let text = """
        你是待办整理助手。用户随手写或口述了一段话（常是语音转写：有错字、口头禅、重复、说半句）。像细心的秘书一样读懂整段话，整理出清楚的待办。只输出一个 JSON 对象，不要解释，不要代码块。

        格式：{"items":[{"t":"标题","d":"","s":"","e":"","done":false,"under":-1,"same":""}],"keep":""}

        字段：
        - t：简短的标题（2–15 字）。去掉口头语（"我会""进行一个""的一个""呃""那个""嘛"）；不含日期和时间词（"早上八点""晚上"都不写进 t）。英文照原样。语音转写的错字按上下文猜正确的词。
        - d：用户明确说了别的日子才写，照抄原话里的日期词（说"周三"就写"周三"，不要换算成几月几日；"明天""下周三""11月20日"同理）；以后固定做的写"每天"或"每周一"。说的就是这一页那天、或没说日子，写 ""。
        - s、e：开始、结束，24 小时制 "HH:MM"；只说"晚上""中午"没有钟点的写 ""。上午、没说上下午的"九点到十一点"是 09:00–11:00（钟点照说的写，不要自己加减）；下午说"两点"是 14:00，上下文在说下午时后面的"三点""四点"也是下午。
        - done：用户说这件事已经做了（"打了篮球""游了泳""弄好了""剪了"）为 true。已经做了的活动也要列成一条。"安排好了""没问题了""定了"只是说定了，不是做完了，done 为 false。
        - under：这一条是前面某条的附属（"记得带上数据"是"开会"的附属），写那一条的序号（从 0 开始）；否则 -1。
        - same："已有事项"里已经有这件事（换了说法、有错字也算，比如"深蹲大引操"就是"自重深蹲 + 大眼操"），写它的编号如 "E2"。这时只有用户改了日期/时间才写 d/s/e（"会改到四点"→ s "16:00"；"没写完，明天继续"→ d "明天"），说做完了 done 为 true。
        - keep：感受、原因、评论（"挺累的""其实不冲突""效率不高"）不是待办；值得留下的用一句话写进 keep。keep 不要复述待办，口头语直接丢掉；拿不准就写 ""。
        - items 只放这段话里说到的事；"已有事项"只用来对照，没提到的不要输出。

        要点：先读完整段。时间常和事情分在两个短句里，要合起来。同一件事说了几遍只出一条。一句话里藏着的打算也是待办（"明天要早点睡""思考一下…计划""跟某人聊一聊…"），都要列出来，不要漏。"一点半"是 :30，"两点半"是 14:30。不要编造。

        例子
        已有事项：
        E1 11月8日 周日（今天） 15:00 和导师开会
        E2 每天 07:30 晨跑
        用户写的：
        嗯今天早上跑了步，然后那个和导师的会改到四点了，记得带上实验数据，晚上打了会儿篮球挺累的，明天要早点睡
        输出：{"items":[{"t":"晨跑","d":"","s":"","e":"","done":true,"under":-1,"same":"E2"},{"t":"和导师开会","d":"","s":"16:00","e":"","done":false,"under":-1,"same":"E1"},{"t":"带上实验数据","d":"","s":"","e":"","done":false,"under":1,"same":""},{"t":"打篮球","d":"","s":"","e":"","done":true,"under":-1,"same":""},{"t":"早点睡","d":"明天","s":"","e":"","done":false,"under":-1,"same":""}],"keep":"打篮球挺累的"}

        已有事项：无
        用户写的：
        然后下午一点半去取个快递嘛，这个已经约好了，然后两点到两点半的时候呢我会开个短会，两点半到三点之间回邮件，然后三点到四点去跑步，晚上思考一下下周的计划，跟小王聊一聊合作
        输出：{"items":[{"t":"取快递","d":"","s":"13:30","e":"","done":false,"under":-1,"same":""},{"t":"开短会","d":"","s":"14:00","e":"14:30","done":false,"under":-1,"same":""},{"t":"回邮件","d":"","s":"14:30","e":"15:00","done":false,"under":-1,"same":""},{"t":"跑步","d":"","s":"15:00","e":"16:00","done":false,"under":-1,"same":""},{"t":"思考下周的计划","d":"","s":"","e":"","done":false,"under":-1,"same":""},{"t":"跟小王聊合作","d":"","s":"","e":"","done":false,"under":-1,"same":""}],"keep":""}
        """
}
