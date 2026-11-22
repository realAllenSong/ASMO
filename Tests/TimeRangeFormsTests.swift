import Foundation
import Testing
@testable import ASMOCore

/// The eval for times written on a line: every way a time or a range gets written (Chinese, English, digits,
/// numerals, at the start, inside or at the end of the line), read on today at 10:00 unless said otherwise.
/// Each case is "HH:MM-HH:MM title" ("-" where there is none).
struct TimeRangeFormsTests {
    func clock(hour: Int) -> CaptureClock {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return CaptureClock(now: calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: hour))!, calendar: calendar)
    }

    func read(_ text: String, at hour: Int = 10, tomorrow: Bool = false) -> String {
        let now = clock(hour: hour)
        let day = tomorrow ? now.offset(days: 1)! : now.today
        let draft = CaptureParser.manual(text, clock: now, selectedDay: day)
        func t(_ m: Int?) -> String { m.map { String(format: "%02d:%02d", ($0 / 60) % 24, $0 % 60) } ?? "-" }
        let dayNote = draft.schedule?.dayOnly == day ? "" : " @" + (draft.schedule?.dayOnly.key ?? "none")
        return "\(t(draft.schedule?.minuteOfDay))-\(t(draft.endMinute)) \(draft.title)\(dayNote)"
    }

    func check(_ cases: [(String, String)], at hour: Int = 10, tomorrow: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) {
        for (text, want) in cases {
            #expect(read(text, at: hour, tomorrow: tomorrow) == want, "「\(text)」", sourceLocation: sourceLocation)
        }
    }

    @Test func rangesAtTheStart() {
        let want = "14:00-15:00 跟Li聊天"
        check([
            ("2点到3点 跟Li聊天", want), ("2点-3点 跟Li聊天", want), ("2-3点 跟Li聊天", want), ("2到3点 跟Li聊天", want),
            ("2~3点 跟Li聊天", want), ("2～3点 跟Li聊天", want), ("2—3点 跟Li聊天", want), ("2–3点 跟Li聊天", want),
            ("2点至3点 跟Li聊天", want), ("2点到3点跟Li聊天", want), ("二到三点 跟Li聊天", want), ("两点到三点 跟Li聊天", want),
            ("两点-三点 跟Li聊天", want), ("2:00-3:00 跟Li聊天", want), ("2:00到3:00 跟Li聊天", want), ("14:00-15:00 跟Li聊天", want),
            ("14-15点 跟Li聊天", want), ("14点-15点 跟Li聊天", want), ("14：00-15：00 跟Li聊天", want), ("下午2点到3点 跟Li聊天", want),
            ("下午2-3点 跟Li聊天", want), ("下午两点到三点 跟Li聊天", want), ("2pm-3pm 跟Li聊天", want), ("2pm - 3pm 跟Li聊天", want),
            ("2-3pm 跟Li聊天", want), ("2 pm-3 pm 跟Li聊天", want), ("2点到3点：跟Li聊天", want), ("2点到3点，跟Li聊天", want),
            ("2点钟到3点钟 跟Li聊天", want),
            // A space before 点, and 点 after a clock time: no 点 is left in the words.
            ("2-3 点 跟Li聊天", want), ("2 点到 3 点 跟Li聊天", want), ("14:00-15:00点跟Li聊天", want), ("14:00点-15:00点 跟Li聊天", want),
        ])
    }

    @Test func halvesAndQuarters() {
        check([
            ("2点半到3点 跟Li聊天", "14:30-15:00 跟Li聊天"), ("2点到3点半 跟Li聊天", "14:00-15:30 跟Li聊天"),
            ("两点半-三点 跟Li聊天", "14:30-15:00 跟Li聊天"), ("2:30-3 跟Li聊天", "14:30-15:00 跟Li聊天"),
            ("2:30-3:15 跟Li聊天", "14:30-15:15 跟Li聊天"), ("2点15到3点 跟Li聊天", "14:15-15:00 跟Li聊天"),
            ("2点一刻 跟Li聊天", "14:15-- 跟Li聊天"), ("2-3点半 跟Li聊天", "14:00-15:30 跟Li聊天"),
            ("2:30pm-3pm 跟Li聊天", "14:30-15:00 跟Li聊天"),
        ])
    }

    @Test func singleTimes() {
        check([
            ("3点 开会", "15:00-- 开会"), ("三点 开会", "15:00-- 开会"), ("3点钟 开会", "15:00-- 开会"), ("15:00 开会", "15:00-- 开会"),
            ("下午3点 开会", "15:00-- 开会"), ("3pm 开会", "15:00-- 开会"), ("3 pm 开会", "15:00-- 开会"), ("15点 开会", "15:00-- 开会"),
            ("晚上8点 吃饭", "20:00-- 吃饭"), ("8点 吃饭", "20:00-- 吃饭"), ("11点 开会", "11:00-- 开会"), ("十一点 开会", "11:00-- 开会"),
            ("中午12点 吃饭", "12:00-- 吃饭"), ("12点 吃饭", "12:00-- 吃饭"), ("早上7点 跑步", "07:00-- 跑步"),
            ("凌晨1点 睡觉", "01:00-- 睡觉"), ("上午11点 开会", "11:00-- 开会"), ("10:30 开会", "10:30-- 开会"),
        ])
    }

    @Test func timesInsideOrAtTheEnd() {
        check([
            ("跟Li聊天 2-3点", "14:00-15:00 跟Li聊天"), ("跟Li聊天 2点到3点", "14:00-15:00 跟Li聊天"),
            ("跟Li聊天 下午2点", "14:00-- 跟Li聊天"), ("跟Li 2点到3点 聊天", "14:00-15:00 跟Li 聊天"),
            ("我下午两点要开会", "14:00-- 开会"), ("开会 14:00-15:00", "14:00-15:00 开会"),
            ("跟Li聊天 2pm-3pm", "14:00-15:00 跟Li聊天"),
        ])
    }

    @Test func daysWithTimes() {
        check([
            ("明天2点到3点 跟Li聊天", "14:00-15:00 跟Li聊天 @2026-11-23"), ("明天下午3点 开会", "15:00-- 开会 @2026-11-23"),
            ("周五3点 开会", "15:00-- 开会 @2026-11-27"), ("今晚8点 吃饭", "20:00-- 吃饭"),
        ])
    }

    @Test func otherDaysReadTheSameWay() {
        check([
            ("2点到3点 跟Li聊天", "14:00-15:00 跟Li聊天"), ("2-3点 跟Li聊天", "14:00-15:00 跟Li聊天"),
            ("9点 晨会", "09:00-- 晨会"), ("早上6点 跑步", "06:00-- 跑步"), ("8点 吃饭", "08:00-- 吃饭"),
        ], tomorrow: true)
    }

    @Test func theEveningReadsTheEvening() {
        check([("9点半到10点 干这个事情", "21:30-22:00 干这个事情"), ("7点到8点 吃饭", "19:00-20:00 吃饭"),
               ("9-10点 看书", "21:00-22:00 看书")], at: 19)
    }

    @Test func numbersThatAreNotTimes() {
        check([
            ("买3个苹果", "--- 买3个苹果"), ("读2-3章", "--- 读2-3章"), ("跑5公里", "--- 跑5公里"),
            ("给 Accolade 写邮件", "--- 给 Accolade 写邮件"), ("check 机票什么时候回去 1/15到 或者1/19到", "--- check 机票什么时候回去 1/15到 或者1/19到"),
            ("开始卖显示器（30号）", "--- 开始卖显示器（30号）"),
        ])
    }
}
