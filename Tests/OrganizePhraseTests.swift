import Foundation
import Testing
@testable import ASMOCore

/// The organizer writes each item as "<date words> <HH:MM[-HH:MM]> <title>" and the rules resolve it.
struct OrganizePhraseTests {
    private var clock: CaptureClock {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        // Sunday, 8 November 2026, 13:17.
        return CaptureClock(now: calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 13, minute: 17))!, calendar: calendar)
    }

    private func read(_ text: String) -> [String] {
        Dictation.items(text, clock: clock, defaultDay: clock.today).map {
            switch $0 {
            case .task(let draft):
                return "\(draft.schedule?.label ?? "-")\(draft.endMinute.map { "–\($0 / 60):\(String(format: "%02d", $0 % 60))" } ?? "") | \(draft.title)"
            case .routine(let draft):
                return "routine \(draft.startMinute.map(String.init) ?? "-") | \(draft.title)"
            }
        }
    }

    @Test func phrases() {
        #expect(read("14:30-15:00 腹肌训练") == ["2026年11月8日 14:30–15:00 | 腹肌训练"])
        #expect(read("15:00-16:00 跑步") == ["2026年11月8日 15:00–16:00 | 跑步"])
        #expect(read("明天 15:00 和导师开会") == ["2026年11月9日 15:00 | 和导师开会"])
        #expect(read("16:00 洗澡") == ["2026年11月8日 16:00 | 洗澡"])
        #expect(read("周五 给妈妈打电话") == ["2026年11月13日 | 给妈妈打电话"])
        #expect(read("下周三 交房租") == ["2026年11月11日 | 交房租"])
        #expect(read("每天 08:00 喝一杯水") == ["routine 480 | 喝一杯水"])
        #expect(read("ICLR 论文 rebuttal") == ["2026年11月8日 | ICLR 论文 rebuttal"])
        #expect(read("和 Mai 聊创业与自媒体规划") == ["2026年11月8日 | 和 Mai 聊创业与自媒体规划"])
        #expect(read("11月20日 14:30 看牙医") == ["2026年11月20日 14:30 | 看牙医"])
        #expect(read("09:00-11:00 写论文") == ["2026年11月8日 9:00–11:00 | 写论文"] || read("09:00-11:00 写论文") == ["2026年11月8日 09:00–11:00 | 写论文"])
        #expect(read("买牛奶、鸡蛋和面包").count == 2)
        if case .task(let draft) = Dictation.item(Dictation.wholeMarker + "16:00 洗澡、点饭", clock: clock, defaultDay: clock.today) {
            #expect(draft.title == "洗澡、点饭")
            #expect(draft.schedule?.label == "2026年11月8日 16:00")
        } else { Issue.record("not a task") }
        if case .task(let draft) = Dictation.item("明天 买牛奶、鸡蛋和面包", clock: clock, defaultDay: clock.today) {
            #expect(draft.title == "买牛奶、鸡蛋和面包")
            #expect(draft.schedule?.label == "2026年11月9日")
        } else { Issue.record("not a task") }
    }

    @Test func sameThing() {
        #expect(Dictation.sameThing("理发", "理发"))
        #expect(Dictation.sameThing("ICLR 论文 rebuttal", "rebuttal"))
        #expect(Dictation.sameThing("Wise 转账", "Wise一个转账"))
        #expect(Dictation.sameThing("自重深蹲100 + 大眼操", "自重深蹲 100+大眼操"))
        #expect(!Dictation.sameThing("跑步", "腹肌训练"))
        #expect(!Dictation.sameThing("开会", "和导师开会讨论论文的实验结果"))
        #expect(!Dictation.sameThing("洗澡", "点饭"))
    }

    @Test func timesComeFromTheWriting() {
        #expect(Dictation.clockGrounded("15:00", in: "明天下午三点和小林吃饭"))
        #expect(!Dictation.clockGrounded("16:00", in: "明天下午三点和小林吃饭，然后周五记得交房租"))
        #expect(Dictation.clockGrounded("14:00", in: "两点到两点半做深蹲"))
        #expect(Dictation.clockGrounded("14:30", in: "两点到两点半做深蹲"))
        #expect(Dictation.clockGrounded("13:30", in: "一点半理发"))
        #expect(Dictation.clockGrounded("22:00", in: "call mom before 10pm"))
        #expect(Dictation.clockGrounded("09:00", in: "9:00 写论文"))
        #expect(Dictation.clockGrounded("12:00", in: "十二点吃饭"))
        #expect(!Dictation.clockGrounded("14:00", in: "十二点吃饭"))
        #expect(Dictation.clockGrounded("12:00", in: "中午吃饭"))
    }

    @Test func repeatRules() {
        #expect(RoutineParser.parse("喝水 #每天", clock: clock)?.weekdays == Set(1...7))
        #expect(RoutineParser.parse("晚上十点冥想 #工作日", clock: clock)?.weekdays == [2, 3, 4, 5, 6])
        #expect(RoutineParser.parse("晚上十点冥想 #工作日", clock: clock)?.startMinute == 22 * 60)
        #expect(RoutineParser.parse("晚上十点冥想 #工作日", clock: clock)?.title == "冥想")
        #expect(Dictation.items("每个工作日 22:00 冥想", clock: clock, defaultDay: clock.today).count == 1)
        #expect(RoutineParser.parse("工作日 7:30 跑步", clock: clock)?.title == "跑步")
        #expect(RoutineParser.parse("爬山 #周末", clock: clock)?.weekdays == [1, 7])
        #expect(RoutineParser.parse("每周一三 确定晚上的餐厅", clock: clock)?.weekdays == [2, 4])
        #expect(RoutineParser.parse("周末去爬山", clock: clock) == nil)
        #expect(RoutineParser.parse("做 rebuttal", clock: clock) == nil)
    }
}
