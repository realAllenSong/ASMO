import Foundation
import Testing
@testable import ASMOCore

struct CalendarMonthTests {
    @Test func alignsWeeksAcrossYearsAndSupportsLeapDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let january = CalendarMonth(containing: PlanDate(year: 2023, month: 1, day: 7), calendar: calendar)
        #expect(january.weekdays.first == "一")
        #expect(january.days.count == 42)
        #expect(january.days.first?.key == "2022-12-26")
        #expect(january.days.last?.key == "2023-02-05")
        let february = CalendarMonth(containing: PlanDate(year: 2028, month: 2, day: 1), calendar: calendar)
        #expect(february.days.contains(PlanDate(year: 2028, month: 2, day: 29)))
    }

    @Test func routesSimpleCaptureDirectlyAndComplexTextToTheModel() {
        let clock = CaptureClock()
        let simple = "15:00 写提案"
        let complex = "明天下午两点跟 Sam 对方案，之后回 Leo 邮件"
        let reminder = "提醒我明天下午两点写提案"
        #expect(!CaptureParser.shouldOrganize(simple, draft: CaptureParser.manual(simple, clock: clock)))
        #expect(CaptureParser.shouldOrganize(complex, draft: CaptureParser.manual(complex, clock: clock)))
        #expect(!CaptureParser.shouldOrganize(reminder, draft: CaptureParser.manual(reminder, clock: clock)))
    }

    @Test func doesNotGuessDateForFollowUpOrInventSystemReminder() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = PlanDate(year: 2026, month: 11, day: 6)
        let clock = CaptureClock(now: today.date(in: calendar)!, calendar: calendar)
        let original = "明天下午两点跟 Sam 对方案，之后回 Leo 邮件"
        let drafts = CaptureParser.validated([
            ExtractedTask(title: "跟 Sam 对方案", source: "明天下午两点跟 Sam 对方案",
                          datePhrase: "明天下午两点", action: .reminder),
            ExtractedTask(title: "回 Leo 邮件", source: "之后回 Leo 邮件", datePhrase: nil, action: .task)
        ], original: original, clock: clock, selectedDay: today)
        #expect(drafts.map(\.action) == [.task, .task])
        #expect(drafts.first?.schedule?.hour == 14)
        #expect(drafts.first?.requiresReview == true)
        #expect(drafts.last?.schedule == nil)
        #expect(drafts.last?.requiresReview == true)
    }

    @Test func desktopRecoversExplicitSequenceAndKeepsNamesVerbatim() {
        let clock = CaptureClock()
        let selected = PlanDate(year: clock.today.year, month: 11, day: 6)
        let text = "11月30日跟 Example 约饭，之后写邮件给 AcmeCorp"
        let spans = [
            ExtractedTask(title: "约饭", source: "11月30日跟 Example 约饭", datePhrase: "11月30日", action: .task),
            ExtractedTask(title: "写邮件给 Acme:Corp", source: "之后写邮件给 AcmeCorp", datePhrase: nil, action: .task)
        ]
        for items in [spans, Array(spans.prefix(1))] {
            let drafts = CaptureParser.validatedDesktop(items, original: text, clock: clock, selectedDay: selected)
            #expect(drafts.map(\.title) == ["跟 Example 约饭", "写邮件给 AcmeCorp"])
            #expect(drafts.first?.schedule?.day == 30)
            #expect(drafts.last?.schedule == nil)
            #expect(drafts.last?.requiresReview == true)
        }
    }
}
