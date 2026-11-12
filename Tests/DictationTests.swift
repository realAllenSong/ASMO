import Foundation
import Testing
@testable import ASMOCore

struct DictationTests {
    private var clock: CaptureClock {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        // Saturday, 7 November 2026, 9:00.
        return CaptureClock(now: calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 9))!, calendar: calendar)
    }

    private func tasks(_ text: String) -> [CaptureDraft] {
        Dictation.items(text, clock: clock, defaultDay: clock.today).compactMap {
            if case .task(let draft) = $0 { return draft } else { return nil }
        }
    }

    @Test func splitsOneBreathAcrossDays() {
        let result = tasks("今天下午三点开会，明天交材料，下周二练胸和肩")
        #expect(result.map(\.title) == ["开会", "交材料", "练胸和肩"])
        #expect(result.map { $0.schedule?.label } == ["2026年11月7日 15:00", "2026年11月8日", "2026年11月10日"])
    }

    @Test func clausesWithoutADateFollowThePreviousOne() {
        let result = tasks("明天上午十点看房，下午两点理发，然后买菜")
        #expect(result.map { $0.schedule?.label } == ["2026年11月8日 10:00", "2026年11月8日 14:00", "2026年11月8日"])
        #expect(result.map(\.title) == ["看房", "理发", "买菜"])
    }

    @Test func readsAppleDictationClockTimes() {
        let result = tasks("明天下午3:00跟导师开会，然后周二之前把论文改完，晚上10:30做大眼操")
        #expect(result.map(\.title) == ["跟导师开会", "把论文改完", "做大眼操"])
        #expect(result.map { $0.schedule?.label } == ["2026年11月8日 15:00", "2026年11月10日", "2026年11月10日 22:30"])
    }

    @Test func toleratesSpokenFillerInTimes() {
        let result = tasks("今天晚上是九点到11点跟小林meeting")
        #expect(result.first?.schedule?.label == "2026年11月7日 21:00")
        #expect(result.first?.endMinute == 23 * 60)
    }

    @Test func noDateMeansToday() {
        let result = tasks("嗯，我要去超市买牛奶")
        #expect(result.count == 1)
        #expect(result.first?.title == "去超市买牛奶")
        #expect(result.first?.schedule?.label == "2026年11月7日")
    }

    @Test func splitsASecondDateInsideOneClause() {
        let result = tasks("明天交报告后天跟 Alex 吃饭")
        #expect(result.map(\.title) == ["交报告", "跟 Alex 吃饭"])
        #expect(result.map { $0.schedule?.day } == [8, 9])
    }

    @Test func keepsALeadingDateWithItsClause() {
        #expect(Dictation.clauses("我明天要开会") == ["我明天要开会"])
        #expect(Dictation.clauses("把明天的材料准备好") == ["把明天的材料准备好"])
    }

    @Test func routinesAreRecognized() {
        let items = Dictation.items("每天早上八点做大眼操，每周一四练胸和肩，明天去银行", clock: clock, defaultDay: clock.today)
        guard items.count == 3, case .routine(let eyes) = items[0], case .routine(let gym) = items[1],
              case .task(let bank) = items[2] else {
            Issue.record("unexpected \(items)")
            return
        }
        #expect(eyes == RoutineDraft(title: "做大眼操", weekdays: Set(1...7), startMinute: 480, endMinute: nil))
        #expect(gym.weekdays == [2, 5])
        #expect(gym.title == "练胸和肩")
        #expect(bank.schedule?.day == 8)
        #expect(RoutineParser.label([2, 5]) == "每周一四")
        #expect(RoutineParser.parse("每晚十点筷子操", clock: clock)?.startMinute == 22 * 60)
    }
}

struct OutlineTests {
    private var clock: CaptureClock {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return CaptureClock(now: calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 9))!, calendar: calendar)
    }

    private func title(_ node: OutlineItem) -> String {
        switch node.item {
        case .task(let draft): draft.title
        case .routine(let routine): "每日:" + routine.title
        }
    }

    @Test func readsADraftLikeADocument() {
        let draft = """
        明天下午三点跟导师开会
        周二之前改完 rebuttal
          - 回复 reviewer 2
          - 补一个 ablation
            跑 3 个 seed
        买牛奶
        每天晚上十点做大眼操
        """
        let roots = Dictation.outline(draft, clock: clock, defaultDay: clock.today)
        #expect(roots.map(title) == ["跟导师开会", "改完 rebuttal", "买牛奶", "每日:做大眼操"])
        #expect(roots[1].children.map(title) == ["回复 reviewer 2", "补一个 ablation"])
        #expect(roots[1].children[1].children.map(title) == ["跑 3 个 seed"])
        if case .task(let child) = roots[1].children[0].item, case .task(let parent) = roots[1].item {
            #expect(child.schedule?.dayOnly == parent.schedule?.dayOnly)
        } else {
            Issue.record("expected tasks")
        }
        if case .task(let milk) = roots[2].item {
            #expect(milk.schedule?.day == 7)
        }
    }
}
