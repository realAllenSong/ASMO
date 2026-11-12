import Foundation
import Testing
@testable import ASMOCore

struct PlannerCommandTests {
    private var clock: CaptureClock {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return CaptureClock(now: calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 9))!, calendar: calendar)
    }

    private func parse(_ text: String) -> PlannerCommand? {
        PlannerCommand.parse(text, clock: clock, defaultDay: clock.today)
    }

    @Test func recognizesEditsToExistingItems() {
        #expect(parse("把理发挪到明天下午三点") == .move(target: "理发", to: PlanDate(year: 2026, month: 11, day: 8, hour: 15, minute: 0), endMinute: nil))
        #expect(parse("把开会改到周二") == .move(target: "开会", to: PlanDate(year: 2026, month: 11, day: 10), endMinute: nil))
        #expect(parse("删掉看房") == .delete(target: "看房"))
        #expect(parse("健身做完了") == .complete(target: "健身"))
        #expect(parse("把开会改成组会") == .rename(target: "开会", title: "组会"))
    }

    @Test func leavesNewItemsAlone() {
        #expect(parse("明天下午三点开会") == nil)
        #expect(parse("把材料交给老师") == nil)
        #expect(parse("每天八点大眼操") == nil)
    }

    @Test func matchesByWordsAndPrefersTheNearestUpcomingDay() {
        let today = PlanDate(year: 2026, month: 11, day: 7)
        let items: [(String, PlanDate)] = [("理发", PlanDate(year: 2026, month: 11, day: 1)),
                                           ("去理发店理发", PlanDate(year: 2026, month: 11, day: 9)),
                                           ("有人来看房 + 群发转租消息", PlanDate(year: 2026, month: 11, day: 8))]
        #expect(PlannerCommand.bestMatch("看房", among: items, title: \.0, day: \.1, today: today)?.0 == "有人来看房 + 群发转租消息")
        #expect(PlannerCommand.bestMatch("理发", among: items, title: \.0, day: \.1, today: today)?.0 == "理发")
        #expect(PlannerCommand.bestMatch("写论文", among: items, title: \.0, day: \.1, today: today) == nil)
    }
}
