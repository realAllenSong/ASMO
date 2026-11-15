import Foundation
import Testing
@testable import ASMOCore

/// A time that doesn't say morning or evening is read from when it's written.
struct TimeOfDayTests {
    func clock(hour: Int, minute: Int = 0) -> CaptureClock {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return CaptureClock(now: calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: hour, minute: minute))!,
                            calendar: calendar)
    }

    func read(_ text: String, at hour: Int, day: PlanDate? = nil) -> (start: Int?, end: Int?, title: String) {
        let now = clock(hour: hour)
        let draft = CaptureParser.manual(text, clock: now, selectedDay: day ?? now.today)
        return (draft.schedule?.minuteOfDay, draft.endMinute, draft.title)
    }

    @Test func passedMorningTimeTodayIsEvening() {
        #expect(read("九点半到10点 干这个事情", at: 19).start == 21 * 60 + 30)
        #expect(read("九点半到10点 干这个事情", at: 19).end == 22 * 60)
        #expect(read("今天九点半到10点要干这个事情", at: 19).start == 21 * 60 + 30)
        #expect(read("9:30-10 开会", at: 19).start == 21 * 60 + 30)
        #expect(read("9:30-10 开会", at: 19).end == 22 * 60)
        #expect(read("9:30-10 开会", at: 19).title == "开会")
        #expect(read("3点 开会", at: 14).start == 15 * 60)
    }

    @Test func morningStaysMorningWhenItsStillAhead() {
        #expect(read("九点半到10点 干这个事情", at: 8).start == 9 * 60 + 30)
        #expect(read("九点半到10点 干这个事情", at: 8).end == 10 * 60)
    }

    @Test func otherDaysAndMarkedTimesAreAsWritten() {
        let tomorrow = clock(hour: 19).offset(days: 1)
        #expect(read("九点半 开会", at: 19, day: tomorrow).start == 9 * 60 + 30)
        #expect(read("明天九点半 开会", at: 19).start == 9 * 60 + 30)
        #expect(read("上午九点半 开会", at: 19).start == 9 * 60 + 30)
        #expect(read("09:30 开会", at: 19).start == 9 * 60 + 30)
        #expect(read("12点 吃饭", at: 19).start == 12 * 60)
        #expect(read("下午3点到5点 开会", at: 9).end == 17 * 60)
    }

    @Test func anotherDaysPageIsNotToday() {
        // The document reads a line on tomorrow's page with the clock moved to tomorrow, same time of day.
        var page = clock(hour: 19)
        page.actualNow = page.now
        page.now = page.now.addingTimeInterval(86_400)
        let draft = CaptureParser.manual("九点半 开会", clock: page, selectedDay: page.today)
        #expect(draft.schedule?.minuteOfDay == 9 * 60 + 30)
        var here = clock(hour: 19)
        here.actualNow = here.now
        #expect(CaptureParser.manual("九点半 开会", clock: here, selectedDay: here.today).schedule?.minuteOfDay == 21 * 60 + 30)
    }
}
