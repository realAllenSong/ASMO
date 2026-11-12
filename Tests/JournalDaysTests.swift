import Foundation
import Testing
@testable import ASMOCore

struct JournalDaysTests {
    @Test func recentDaysAreConsecutiveThenAllOlderRecordedDatesAppearOnce() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = PlanDate(year: 2026, month: 11, day: 6)
        let overlapping = PlanDate(year: 2026, month: 11, day: 5)
        let older = PlanDate(year: 2026, month: 10, day: 10)
        let oldest = PlanDate(year: 2021, month: 8, day: 24)
        let future = PlanDate(year: 2026, month: 11, day: 9)
        let monthOnly = PlanDate(year: 2024, month: 5)
        let days = JournalDays.ordered(endingAt: today,
            recorded: [overlapping, older, oldest, future, monthOnly], calendar: calendar)
        #expect(days.map(\.key) == [
            "2026-11-06", "2026-11-05", "2026-11-04", "2026-11-03", "2026-11-02",
            "2026-11-01", "2026-10-31", "2026-10-10", "2021-08-24"
        ])
    }

    @Test func completionComesFromStrikethroughNotAnOlderDate() {
        let done = JournalArchiveText("~~发邮件，订餐~~")
        #expect(done.completed)
        #expect(done.text == "发邮件，订餐")
        #expect(done.encoded == "~~发邮件，订餐~~")
        #expect(!JournalArchiveText("2021 年发邮件").completed)
    }
}

extension JournalDaysTests {
    @Test func agendaWindowSpansBothDirectionsThroughMonthBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let anchor = PlanDate(year: 2026, month: 11, day: 1)
        #expect(JournalDays.window(around: anchor, before: 2, after: 2, calendar: calendar).map(\.key) == [
            "2026-10-30", "2026-10-31", "2026-11-01", "2026-11-02", "2026-11-03"
        ])
    }

    @Test func aChineseBirthdayKeepsItsDateWhileGreetingConvertsAcrossMidnight() {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone(identifier: "America/New_York")!
        let birthday = ImportantDateRule(month: 11, day: 22, timeZoneID: "Asia/Shanghai")
        let day = PlanDate(year: 2026, month: 11, day: 22)
        let instant = birthday.time(on: day, hour: 9, minute: 0, localCalendar: local)!
        let converted = PlanDate.from(instant, calendar: local, includeTime: true)
        #expect(converted.key == "2026-11-21")
        #expect(converted.hour == 20)
        #expect(birthday.matches(day, calendar: local))
        #expect(!birthday.matches(converted, calendar: local))
        let summerBirthday = ImportantDateRule(month: 7, day: 12, timeZoneID: "Asia/Shanghai")
        let summerDay = PlanDate(year: 2026, month: 7, day: 12)
        let summerTime = summerBirthday.time(on: summerDay, hour: 9, minute: 0, localCalendar: local)!
        let summerConverted = PlanDate.from(summerTime, calendar: local, includeTime: true)
        #expect(summerConverted.key == "2026-07-11")
        #expect(summerConverted.hour == 21)
    }
}
