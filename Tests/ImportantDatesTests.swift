import Foundation
import Testing
@testable import ASMOCore

struct ImportantDatesTests {
    private var clock: CaptureClock {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return CaptureClock(calendar: calendar)
    }

    @Test func recognizesArchivesAndPreservesDualDate() throws {
        let raw = "生日归档\n2.14: 亲友1980.02.14\n10.15: 示例1981.10.15 8月29阴历\n纪念忌日 2024.1.8\n不明确"
        let batch = ImportantDateImport.parse(raw, calendar: clock.calendar)
        #expect(batch.entries.count == 3)
        #expect(batch.unparsed == ["不明确"])
        #expect(batch.entries.first?.title == "亲友生日")
        let dual = try #require(batch.entries.first { $0.rule.system == .lunar })
        #expect(dual.rule.month == 8 && dual.rule.day == 29)
        #expect(dual.gregorianAlternative?.month == 10 && dual.gregorianAlternative?.day == 15)
        #expect(dual.original.contains("1981.10.15"))
        #expect(batch.entries.last?.kind == .anniversary)
    }

    @Test func matchesAnnualDatesInTheSelectedCalendar() throws {
        let annual = ImportantDateRule(month: 3, day: 4)
        #expect(annual.matches(PlanDate(year: 2028, month: 3, day: 4), calendar: clock.calendar))
        #expect(!annual.matches(PlanDate(year: 2028, month: 3, day: 3), calendar: clock.calendar))
        let oneOff = ImportantDateRule(month: 3, day: 4, year: 2027)
        #expect(!oneOff.matches(PlanDate(year: 2028, month: 3, day: 4), calendar: clock.calendar))
        let lunarNewYear = ImportantDateRule(month: 1, day: 1, system: .lunar)
        #expect(lunarNewYear.matches(PlanDate(year: 2024, month: 2, day: 10), calendar: clock.calendar))
        #expect(lunarNewYear.matches(PlanDate(year: 2025, month: 1, day: 29), calendar: clock.calendar))
        let lunarLastDay = ImportantDateRule(month: 12, day: 30, system: .lunar)
        #expect(lunarLastDay.matches(PlanDate(year: 2025, month: 1, day: 28), calendar: clock.calendar))
    }

    @Test func distinguishesExactRangesFromPointTimes() {
        let sample = CaptureParser.manual("15:00–16:30 准备 pitch", clock: clock)
        #expect(sample.title == "准备 pitch")
        #expect(sample.schedule?.hour == 15)
        #expect(sample.endMinute == 990)
        #expect(!sample.requiresReview)
        #expect(CaptureParser.manual("17:30 开始 review", clock: clock).endMinute == nil)
        #expect(CaptureParser.manual("15:00–14:45 改 slides", clock: clock).requiresReview)
    }

    @Test func onlyUnspecifiedBirthdaysDefaultToChina() {
        let rule = ImportantDateRule(month: 11, day: 22)
        #expect(rule.withDefaultTimeZone(for: .birthday).timeZoneID == "Asia/Shanghai")
        #expect(rule.withDefaultTimeZone(for: .anniversary).timeZoneID == nil)
        for zone in [ImportantDateTimeZone.deviceID, ImportantDateTimeZone.pacific.rawValue] {
            var specified = rule
            specified.timeZoneID = zone
            #expect(specified.withDefaultTimeZone(for: .birthday) == specified)
        }
    }

    @Test func suggestsLocalTimeUsingTheOffsetOnTheBirthday() throws {
        let now = try #require(PlanDate(year: 2026, month: 1, day: 1).date(in: clock.calendar))
        for (month, expectedHour, expectedOffset) in [(11, 20, "UTC−05:00"), (7, 21, "UTC−04:00")] {
            let birthday = PlanDate(year: 2026, month: month, day: 22)
            let rule = ImportantDateRule(month: month, day: 22).withDefaultTimeZone(for: .birthday)
            let suggestion = try #require(rule.suggestedGreeting(on: birthday, after: now, localCalendar: clock.calendar))
            #expect(suggestion.recipient.dayOnly == birthday)
            #expect(suggestion.recipient.hour == 9)
            #expect(suggestion.local.day == 21 && suggestion.local.hour == expectedHour)
            #expect(suggestion.crossesDateBoundary)
            #expect(ImportantDateTimeZone.offsetLabel(clock.calendar.timeZone, at: suggestion.instant) == expectedOffset)
        }
    }

    @Test func adaptsWhenTheBirthdayMorningHasAlreadyPassed() throws {
        let birthday = PlanDate(year: 2026, month: 11, day: 22)
        let rule = ImportantDateRule(month: 11, day: 22).withDefaultTimeZone(for: .birthday)
        var shanghai = clock.calendar
        shanghai.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        var now = try #require(PlanDate(year: 2026, month: 11, day: 22, hour: 8).date(in: shanghai))
        let sameZone = try #require(rule.suggestedGreeting(on: birthday, after: now, localCalendar: shanghai))
        #expect(sameZone.local == sameZone.recipient && sameZone.local.hour == 9)

        now = try #require(PlanDate(year: 2026, month: 11, day: 22, hour: 0).date(in: clock.calendar))
        let later = try #require(rule.suggestedGreeting(on: birthday, after: now, localCalendar: clock.calendar))
        #expect(later.recipient.hour == 21 && later.local.hour == 8)

        now = try #require(PlanDate(year: 2026, month: 11, day: 23, hour: 0).date(in: shanghai))
        #expect(rule.suggestedGreeting(on: birthday, after: now, localCalendar: clock.calendar) == nil)
    }
}
