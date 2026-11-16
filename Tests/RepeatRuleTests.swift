import Foundation
import Testing
@testable import ASMOCore

/// Repeat rules written in a line ("每月15号 交房租", "… #每周三") or added by the toolbar's 重复 menu.
struct RepeatRuleTests {
    /// Sunday 2026-11-15, 7 pm.
    let clock: CaptureClock = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return CaptureClock(now: calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 19))!, calendar: calendar)
    }()

    @Test func monthly() {
        let rule = RoutineParser.parse("每月15号 交房租", clock: clock)
        #expect(rule?.monthDay == 15)
        #expect(rule?.title == "交房租")
        #expect(RoutineParser.parse("每个月1日 续费域名", clock: clock)?.monthDay == 1)
        #expect(RoutineParser.parse("每月 交房租", clock: clock)?.monthDay == 15)
        #expect(RoutineParser.parse("交房租 #每月", clock: clock)?.monthDay == 15)
        #expect(RoutineParser.parse("交房租 #每月3号", clock: clock)?.monthDay == 3)
        #expect(RoutineParser.label([], monthDay: 15) == "每月15日")
    }

    @Test func weeklyTag() {
        #expect(RoutineParser.parse("组会 #每周三", clock: clock)?.weekdays == [4])
        // "#每周" alone: the weekday of the page (a Sunday here).
        #expect(RoutineParser.parse("组会 #每周", clock: clock)?.weekdays == [1])
        #expect(RoutineParser.parse("组会 #每周", clock: clock)?.monthDay == nil)
    }

    @Test func dailyAndWorkdaysStillWork() {
        #expect(RoutineParser.parse("喝水 #每天", clock: clock)?.weekdays.count == 7)
        #expect(RoutineParser.parse("跑步 #工作日", clock: clock)?.weekdays == [2, 3, 4, 5, 6])
        #expect(RoutineParser.parse("每月的事情要想想", clock: clock)?.title == "事情要想想")
    }
}
