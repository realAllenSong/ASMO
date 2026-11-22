import Foundation

enum CaptureAction: String, Codable, Sendable, CaseIterable {
    case task, reminder, event
}

struct CaptureDraft: Identifiable, Sendable {
    var id = UUID()
    var title: String
    var original: String
    var schedule: PlanDate?
    var endMinute: Int?
    var alertLead: Int?
    var action: CaptureAction = .task
    var requiresReview = false
}

struct ExtractedTask: Sendable {
    var title: String
    var source: String
    var datePhrase: String?
    var action: CaptureAction
}

enum CaptureParser {
    static func shouldOrganize(_ original: String, draft: CaptureDraft) -> Bool {
        (draft.requiresReview && draft.action == .task) || original.match(
            #"[；;。！？]\s*\S|，\s*(?:再|然后|接着|之后|还(?:要|得))|(?:然后|接着|之后再)|\band then\b|,\s*then\b"#
        ) != nil
    }

    static func explicitSchedule(_ phrase: String, clock: CaptureClock, selectedDay: PlanDate?) -> (PlanDate, Int?)? {
        guard let parsed = prefix(in: phrase.trimmed, clock: clock, selectedDay: selectedDay),
              let date = parsed.date, parsed.rest.trimmed.isEmpty else { return nil }
        return (date, parsed.endMinute)
    }

    static func manual(_ input: String, clock: CaptureClock, selectedDay: PlanDate? = nil) -> CaptureDraft {
        let source = input.trimmed
        let action = requestedAction(in: source)
        let command = action == .reminder ? source.match(#"^(?:请\s*)?(?:提醒我|remind me)\s*"#)?.first : nil
        let remaining = command.map { String(source.dropFirst($0.count)) } ?? source
        let parsed = located(in: remaining, clock: clock, selectedDay: selectedDay)
        let title = parsed?.rest.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "：:，,、"))) ?? source
        let uncertain = containsUnresolvedDate(title)
        return CaptureDraft(title: title.isEmpty ? source : title, original: source,
                            schedule: parsed == nil ? selectedDay : parsed?.date,
                            endMinute: parsed?.endMinute, alertLead: requestedAlert(in: source), action: action,
                            requiresReview: action != .task || uncertain || (parsed != nil && parsed?.date == nil))
    }

    /// Finds a date/time phrase at the start of the text or inside it ("我下午两点要开会", "开会 明天三点"),
    /// and returns the title with that phrase removed.
    private static func located(in source: String, clock: CaptureClock,
                                selectedDay: PlanDate?) -> (date: PlanDate?, rest: String, endMinute: Int?)? {
        if let parsed = prefix(in: source, clock: clock, selectedDay: selectedDay) {
            // "明天和 Alex 下午三点开会": the day leads, the time sits later in the sentence.
            if let day = parsed.date, day.day != nil, day.hour == nil,
               let inner = embedded(in: parsed.rest, clock: clock, selectedDay: day, timeOnly: true) {
                return inner
            }
            return parsed
        }
        return embedded(in: source, clock: clock, selectedDay: selectedDay, timeOnly: false)
    }

    private static func embedded(in source: String, clock: CaptureClock, selectedDay: PlanDate?,
                                 timeOnly: Bool) -> (date: PlanDate?, rest: String, endMinute: Int?)? {
        let times = #"上午|早上|中午|下午|傍晚|晚上|凌晨|(?<![\d:./])[两二三四五六七八九十\d]{1,3}\s*(?:到|至|-|–|—|~|～)\s*[两二三四五六七八九十\d]{1,3}\s*[点時时]|(?<![\d:./])\d{1,2}(?::\d{2})?\s*(?:-|–|—|~|～|to)\s*\d{1,2}(?::\d{2})?\s*(?:am|pm)\b|(?<![\d:])\d{1,2}[:：]\d{2}|(?<![\d.])\d{1,2}\s*(?:am|pm)\b|at\s+\d|(?<!一)[两二三四五六七八九十\d]+[点時时]|十一点|十二点"#
        let days = #"\d{4}[.／/\-年]\d|\d{1,2}[.／/月]\d|明年|今年|[一二两三四五六七八九十\d]+月[一二两三四五六七八九十\d]+[日号]|下下个月|下个月|这个月|大后天|后天|明天|今天|今晚|明早|tomorrow\b|today\b|(?:下|这|本)?(?:周|星期)[一二三四五六日天]|(?:next|this)\s+(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#
        // Two dates in one line ("1/15到 或者1/19到") are options being weighed, not the day of the thing: only a
        // time is taken from it.
        let choices = (try? NSRegularExpression(pattern: #"(?<!\d)\d{1,2}[/／月]\d{1,2}(?!\d)"#))?
            .numberOfMatches(in: source, range: NSRange(location: 0, length: (source as NSString).length)) ?? 0
        let pattern = timeOnly || choices >= 2 ? times : days + "|" + times
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let text = source as NSString
        for match in regex.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            let head = text.substring(to: match.range.location)
            let tail = text.substring(from: match.range.location)
            guard let parsed = prefix(in: tail, clock: clock, selectedDay: selectedDay), let date = parsed.date,
                  !timeOnly || date.hour != nil else { continue }
            var lead = head.trimmed
            for word in ["我们", "我"] where lead.hasPrefix(word) { lead = String(lead.dropFirst(word.count)); break }
            lead = lead.replacingOccurrences(of: #"\s*(?:在|于|on|at)$"#, with: "", options: .regularExpression)
            var tailText = parsed.rest.trimmed
            if lead.trimmed.isEmpty {
                tailText = tailText.replacingOccurrences(of: #"^(?:要|得|需要|会|的时候|时)\s*"#, with: "",
                                                         options: .regularExpression)
            }
            let joined = [lead.trimmed, tailText].filter { !$0.isEmpty }
                .joined(separator: lead.trimmed.last?.isASCII == true || tailText.first?.isASCII == true ? " " : "")
            return (date, joined, parsed.endMinute)
        }
        return nil
    }

    static func validated(_ items: [ExtractedTask], original: String, clock: CaptureClock,
                          selectedDay: PlanDate? = nil) -> [CaptureDraft] {
        var remaining = original
        var drafts: [CaptureDraft] = []
        for item in items {
            let source = item.source.trimmed
            guard !source.isEmpty, !item.title.trimmed.isEmpty, let range = remaining.range(of: source) else {
                return [reviewOriginal(original, clock: clock, selectedDay: selectedDay)]
            }
            if let timeOnly = prefix(in: source, clock: clock, selectedDay: selectedDay),
               timeOnly.rest.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty {
                return [reviewOriginal(original, clock: clock, selectedDay: selectedDay)]
            }
            remaining.replaceSubrange(range, with: "")
            let explicit = requestedAction(in: source)
            let action = explicit
            let phrase = item.datePhrase?.trimmed ?? ""
            var schedule = selectedDay
            var endMinute: Int?
            var grounded = item.action == .task || explicit != .task
            if !phrase.isEmpty {
                if source.contains(phrase), let result = prefix(in: phrase, clock: clock, selectedDay: selectedDay),
                   result.rest.trimmed.isEmpty, let date = result.date {
                    schedule = date
                    endMinute = result.endMinute
                } else {
                    grounded = false
                    schedule = nil
                }
            } else if prefix(in: source, clock: clock, selectedDay: selectedDay) != nil ||
                        containsUnresolvedDate(source) {
                grounded = false
            } else if let previous = drafts.last?.schedule,
                      previous.dayOnly != selectedDay?.dayOnly,
                      source.match(#"^(?:之后|结束后|随后|接着|然后|afterwards\b|then\b)"#) != nil {
                grounded = false
                schedule = nil
            }
            drafts.append(CaptureDraft(title: item.title.trimmed, original: source, schedule: schedule, endMinute: endMinute,
                                       alertLead: requestedAlert(in: source), action: action, requiresReview: !grounded || action != .task))
        }
        let extra = remaining.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if drafts.isEmpty || !extra.isEmpty {
            return [reviewOriginal(original, clock: clock, selectedDay: selectedDay)]
        }
        return drafts
    }

    static func validatedDesktop(_ items: [ExtractedTask], original: String, clock: CaptureClock,
                                 selectedDay: PlanDate?) -> [CaptureDraft] {
        // Let the model identify source spans. Build titles from those spans so an acronym
        // or name cannot disappear or be changed by the model.
        let verbatim = items.map { item in
            var value = item
            value.title = manual(strippingConnector(item.source), clock: clock, selectedDay: selectedDay).title
            return value
        }
        let drafts = validated(verbatim, original: original, clock: clock, selectedDay: selectedDay)
        if let recovered = explicitSequence(original, clock: clock, selectedDay: selectedDay),
           recovered.count > drafts.count {
            return recovered
        }
        return drafts
    }

    static func explicitSequence(_ original: String, clock: CaptureClock, selectedDay: PlanDate?) -> [CaptureDraft]? {
        let expression = #"[，,]\s*(?=(?:之后|然后|接着|随后|then\b))|[；;]\s*(?=\S)"#
        guard let separator = try? NSRegularExpression(pattern: expression, options: .caseInsensitive) else { return nil }
        let matches = separator.matches(in: original, range: NSRange(original.startIndex..., in: original))
        guard !matches.isEmpty, matches.count < 24 else { return nil }
        var start = original.startIndex
        var clauses: [String] = []
        for match in matches {
            guard let range = Range(match.range, in: original) else { return nil }
            clauses.append(String(original[start..<range.lowerBound]).trimmed)
            start = range.upperBound
        }
        clauses.append(String(original[start...]).trimmed)
        guard clauses.allSatisfy({ !$0.isEmpty && !strippingConnector($0).isEmpty }) else { return nil }
        var drafts: [CaptureDraft] = []
        for source in clauses {
            let content = strippingConnector(source)
            let explicitDate = prefix(in: content, clock: clock, selectedDay: selectedDay)
            if let explicitDate, explicitDate.rest.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty {
                return nil
            }
            var draft = manual(content, clock: clock, selectedDay: selectedDay)
            draft.original = source
            if content != source, explicitDate == nil,
               let previous = drafts.last?.schedule, previous.dayOnly != selectedDay?.dayOnly {
                draft.schedule = nil
                draft.requiresReview = true
            }
            drafts.append(draft)
        }
        return drafts
    }

    private static func strippingConnector(_ source: String) -> String {
        let text = source.trimmed
        guard let connector = text.match(#"^(?:之后|然后|接着|随后|and then\b|then\b)\s*"#)?.first else {
            return text
        }
        return String(text.dropFirst(connector.count)).trimmed
    }

    private static func reviewOriginal(_ original: String, clock: CaptureClock, selectedDay: PlanDate?) -> CaptureDraft {
        var result = manual(original, clock: clock, selectedDay: selectedDay)
        result.title = original
        result.requiresReview = true
        return result
    }

    private static func containsUnresolvedDate(_ text: String) -> Bool {
        text.match(#"明天|后天|昨天|今晚|明早|明年|下个月|改天|某天|(?:下|本|这|上)(?:周|星期)|(?:周|星期)[一二三四五六日天]|本月(?:底|初)|月底|年底|回头|之后再|(?:上午|早上|下午|晚上|中午)\s*[一二两三四五六七八九十\d]+点|\b(?:tomorrow|yesterday|sometime|later this|next week|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#) != nil
    }

    private static func requestedAction(in source: String) -> CaptureAction {
        if source.match(#"(?:写进|写入|加到|添加到|放进|放到).{0,10}日历|\b(?:add|put|create|schedule)\b.{0,45}\bcalendar\b"#) != nil {
            return .event
        }
        if source.match(#"提醒我|记得提醒|设(?:个|置)?提醒|\b(?:remind me|set a reminder)\b"#) != nil {
            return .reminder
        }
        return .task
    }

    private static func requestedAlert(in source: String) -> Int? {
        if source.match(#"不用提醒|无需提醒|关闭提醒|\bno alert\b"#) != nil { return -1 }
        guard let parts = source.match(#"提前\s*([一二两三四五六七八九十零〇\d]+)\s*(分钟|小时)"#),
              let value = number(parts[1]), (1...1440).contains(value) else { return nil }
        let minutes = parts[2] == "小时" ? value * 60 : value
        return (1...1440).contains(minutes) ? minutes : nil
    }

    private static func prefix(in source: String, clock: CaptureClock, selectedDay: PlanDate?) -> (date: PlanDate?, rest: String, endMinute: Int?)? {
        var date: PlanDate?
        var rest = source
        var endMinute: Int?
        let today = clock.today
        if let parts = source.match(#"^(\d{4})[.／/\-年](\d{1,2})(?:[.／/\-月](\d{1,2})[日号]?)?月?(?!\d)"#),
           let year = Int(parts[1]), let month = Int(parts[2]) {
            date = PlanDate(year: year, month: month, day: Int(parts[3]))
            rest = String(source.dropFirst(parts[0].count))
        } else if let parts = source.match(#"^(\d{1,2})[.／/月](\d{1,2})[日号]?(?!\d)"#),
                  let month = Int(parts[1]), let day = Int(parts[2]) {
            date = PlanDate(year: today.year, month: month, day: day)
            rest = String(source.dropFirst(parts[0].count))
        } else if let parts = source.match(#"^(明年|今年)(?:的)?([一二两三四五六七八九十\d]+)月(?:([一二两三四五六七八九十\d]+)[日号])?"#),
                  let month = number(parts[2]) {
            date = PlanDate(year: today.year + (parts[1] == "明年" ? 1 : 0), month: month, day: number(parts[3]))
            rest = String(source.dropFirst(parts[0].count))
        } else if let parts = source.match(#"^([一二两三四五六七八九十\d]+)月([一二两三四五六七八九十\d]+)[日号]"#),
                  let month = number(parts[1]), let day = number(parts[2]) {
            date = PlanDate(year: today.year, month: month, day: day)
            rest = String(source.dropFirst(parts[0].count))
        } else if let parts = source.match(#"^(下下个月|下个月|这个月|本月(?![底初])|next month\b|this month\b)"#) {
            let offset = parts[0] == "下下个月" ? 2 : (["下个月", "next month"].contains(parts[0].lowercased()) ? 1 : 0)
            date = clock.offset(months: offset)
            rest = String(source.dropFirst(parts[0].count))
        } else if let parts = source.match(#"^(大后天|后天|明天|今天|昨天|前天|今晚|明早|today\b|tomorrow\b|yesterday\b)"#) {
            let days = ["大后天": 3, "后天": 2, "明天": 1, "今天": 0, "昨天": -1, "前天": -2,
                        "今晚": 0, "明早": 1, "today": 0, "tomorrow": 1, "yesterday": -1]
            date = clock.offset(days: days[parts[0].lowercased()] ?? 0)
            rest = String(source.dropFirst(parts[0].count))
            if ["今晚", "明早"].contains(parts[0]), let time = timePrefix((parts[0] == "今晚" ? "晚上" : "早上") + rest.trimmed) {
                if !time.isValid { return (nil, rest, nil) }
                date?.hour = time.hour
                date?.minute = time.minute
                rest = String(rest.trimmed.dropFirst(time.length - 2))
            }
        } else if let parts = source.match(#"^(下|这|本)?(?:周|星期)([一二三四五六日天])"#) {
            let weekday = ["日": 1, "天": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7]
            let current = (clock.calendar.component(.weekday, from: clock.now) + 5) % 7
            let target = ((weekday[parts[2]] ?? 1) + 5) % 7
            let distance = parts[1] == "下" ? 7 + target - current :
                (parts[1].isEmpty ? (target - current + 7) % 7 : target - current)
            date = clock.offset(days: distance)
            rest = String(source.dropFirst(parts[0].count))
        } else if let parts = source.match(#"^(?:(next|this)\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#) {
            let names = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
            let current = (clock.calendar.component(.weekday, from: clock.now) + 5) % 7
            let target = names.firstIndex(of: parts[2].lowercased()) ?? 0
            let distance = parts[1].lowercased() == "next" ? 7 + target - current :
                (parts[1].isEmpty ? (target - current + 7) % 7 : target - current)
            date = clock.offset(days: distance)
            rest = String(source.dropFirst(parts[0].count))
        }

        let hasDayOrMonth = rest != source
        let timeText = Self.unitOnBoth(rest.trimmed)
        if let time = timePrefix(timeText) {
            if !hasDayOrMonth { date = selectedDay?.day == nil ? today : selectedDay }
            rest = String(timeText.dropFirst(time.length))
            if date?.day == nil || !time.isValid { return (nil, rest, nil) }
            date?.hour = time.hour
            date?.minute = time.minute
            // A time that doesn't say morning or evening: one to six is the afternoon ("两点开会" is 14:00, on any
            // day); today, one whose morning has already gone by is this evening's ("9点半" written at 7 pm is 21:30).
            if !time.marked, (1...6).contains(time.hour) {
                date?.hour = time.hour + 12
            } else if !time.marked, (7...11).contains(time.hour), date?.dayOnly == clock.actualToday,
               time.hour * 60 + time.minute < clock.actualMinuteOfDay {
                date?.hour = time.hour + 12
            }
        } else if !hasDayOrMonth {
            return nil
        }
        if let connector = rest.match(#"^\s*(?:(?:到|至)(?=\s*(?:[上下中晚早凌一二两三四五六七八九十\d]))|[-–—~～])\s*"#)?.first,
           let start = date?.hour {
            let tail = String(rest.dropFirst(connector.count))
            // "9:30-10": a bare hour ends the range too.
            let bare = tail.match(#"^(\d{1,2})(?![\d:：点時时.])"#).flatMap { parts in
                Int(parts[1]).map { (length: parts[0].count, hour: $0, minute: 0, isValid: (0...24).contains($0), marked: $0 >= 12) }
            }
            guard let end = timePrefix(tail) ?? bare, end.isValid else { return (nil, rest, nil) }
            var endHour = end.hour
            // The end is in the same half of the day as the start unless it says otherwise ("下午3点到5点",
            // "晚上9:30-10").
            if start >= 12, endHour < 12, !end.marked || tail.match(#"^[一二两三四五六七八九十零〇\d]+[点時时]"#) != nil {
                endHour += 12
            }
            let startMinute = start * 60 + (date?.minute ?? 0)
            let candidate = endHour * 60 + end.minute
            rest = String(tail.dropFirst(end.length))
            guard (0..<1440).contains(candidate), (0...59).contains(end.minute), candidate > startMinute else {
                return (nil, rest, nil)
            }
            endMinute = candidate
        }
        if date?.date(in: clock.calendar) == nil { date = nil }
        return (date, rest, date == nil ? nil : endMinute)
    }

    /// A time at the start of `text`. `marked`: it says which half of the day (上午/下午…, am/pm, or a 24-hour
    /// clock like 21:30 or 09:30); unmarked, 9:30 could be morning or evening.
    /// A range with the unit only after its end ("2-3点", "二到三点半", "2~3点"): the unit goes after the start
    /// too ("2点-3点"), so the start is read as a time and not left in the title.
    static func unitOnBoth(_ text: String) -> String {
        if let parts = text.match(#"^(\d{1,2}(?::\d{2})?)\s*(-|–|—|~|～|to)\s*(\d{1,2}(?::\d{2})?)\s*(am|pm)\b"#),
           !parts[1].isEmpty {
            return parts[1] + parts[4] + "-" + String(text.dropFirst(parts[0].count - parts[3].count - parts[4].count).drop { $0 == " " })
        }
        let digits = "[一二两三四五六七八九十零〇\\d]"
        guard let parts = text.match("^((?:上午|早上|中午|下午|傍晚|晚上|凌晨)?\\s*" + digits + "{1,3})\\s*(到|至|-|–|—|~|～)\\s*("
                                     + digits + "{1,3}\\s*[点時时])") else { return text }
        return parts[1] + "点" + parts[2] + String(text.dropFirst(parts[0].count - parts[3].count))
    }

    private static func timePrefix(_ text: String) -> (length: Int, hour: Int, minute: Int, isValid: Bool, marked: Bool)? {
        // Dictation writes "下午3:00" / "晚上10:30": a part of day followed by clock digits.
        if let parts = text.match(#"^(上午|早上|中午|下午|傍晚|晚上|凌晨)\s*(\d{1,2})[:：](\d{2})(?!\d)"#),
           var hour = Int(parts[2]), let minute = Int(parts[3]) {
            let valid = (1...12).contains(hour) && (0...59).contains(minute)
            if ["中午", "下午", "傍晚", "晚上"].contains(parts[1]), hour < 12, parts[1] != "中午" || hour < 3 { hour += 12 }
            if parts[1] == "凌晨", hour == 12 { hour = 0 }
            return (parts[0].count, hour, minute, valid, true)
        }
        if let parts = text.match(#"^(上午|早上|中午|下午|傍晚|晚上|凌晨)?\s*(?:是|在)?\s*([一二两三四五六七八九十零〇\d]+)[点時时]钟?(?:(半|一刻|三刻)|([一二两三四五六七八九十零〇\d]+)分?)?"#),
           var hour = number(parts[2]) {
            let valid = parts[1].isEmpty || (1...12).contains(hour)
            if ["中午", "下午", "傍晚", "晚上"].contains(parts[1]), hour < 12,
               parts[1] != "中午" || hour < 3 { hour += 12 }
            if parts[1] == "凌晨", hour == 12 { hour = 0 }
            let minute = ["半": 30, "一刻": 15, "三刻": 45][parts[3]] ?? number(parts[4]) ?? 0
            return (parts[0].count, hour, minute, valid, !parts[1].isEmpty || hour >= 12)
        }
        if let parts = text.match(#"^(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#),
           let hour = Int(parts[1]) {
            return (parts[0].count, hour % 12 + (parts[3].lowercased() == "pm" ? 12 : 0),
                    Int(parts[2]) ?? 0, (1...12).contains(hour), true)
        }
        if let parts = text.match(#"^(?:at\s+)?(\d{1,2})[:：](\d{2})(?!\d)"#),
           let hour = Int(parts[1]), let minute = Int(parts[2]) {
            return (parts[0].count, hour, minute, true, hour >= 12 || parts[1].hasPrefix("0"))
        }
        return nil
    }

    static func number(_ input: String) -> Int? {
        if let number = Int(input) { return number }
        let digits = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
                      "六": 6, "七": 7, "八": 8, "九": 9]
        let parts = input.components(separatedBy: "十")
        if parts.count == 2 {
            return 10 * (digits[parts[0]] ?? 1) + (digits[parts[1]] ?? 0)
        }
        return digits[input]
    }
}
