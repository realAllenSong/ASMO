import Foundation
import Testing
@testable import ASMOCore

struct DomainTests {
    @Test func followsMidnightOnlyFromThePreviousToday() {
        let previous = PlanDate(year: 2026, month: 11, day: 5)
        let current = PlanDate(year: 2026, month: 11, day: 6)
        let browsing = PlanDate(year: 2026, month: 11, day: 22)
        #expect(previous.followingToday(from: previous, to: current) == current)
        #expect(browsing.followingToday(from: previous, to: current) == browsing)
    }

    private var clock: CaptureClock {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return CaptureClock(now: cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 23))!, calendar: cal)
    }

    @Test func preservesMonthWithoutInventingDay() {
        let item = CaptureParser.manual("2027.3：续费域名", clock: clock)
        #expect(item.title == "续费域名")
        #expect(item.schedule == PlanDate(year: 2027, month: 3))
    }

    @Test func usesLocalDayAndRejectsInvalidDate() {
        #expect(CaptureParser.manual("明天下午一点半 理发", clock: clock).schedule ==
                PlanDate(year: 2026, month: 11, day: 6, hour: 13, minute: 30))
        #expect(CaptureParser.manual("2027.2.29：约饭", clock: clock).requiresReview)
        #expect(CaptureParser.manual("提醒我明天交报告", clock: clock).requiresReview)
        #expect(CaptureParser.manual("改天跟 Alex 约饭", clock: clock).requiresReview)
    }

    @Test func preservesArchiveAndMakesStableImportKeys() {
        let raw = "历史月份归档\n\n21年8月\n8.24：旧计划\n  保留续行\n8.40：格式异常\n\n11.5：今天的事\n2027.3：续费域名"
        let a = ArchiveParser.parse(raw, defaultYear: 2026, clock: clock)
        #expect(a.raw == raw)
        #expect(a.entries.contains { $0.schedule == PlanDate(year: 2021, month: 8, day: 24) && $0.body.contains("保留续行") })
        #expect(a.entries.contains { $0.schedule == nil && $0.body.contains("8.40") })
        #expect(a.entries.contains { $0.schedule == PlanDate(year: 2026, month: 11, day: 5) })
        #expect(a.entries.contains { $0.schedule == PlanDate(year: 2027, month: 3) })
        #expect(a.entries.map(\.id) == ArchiveParser.parse(raw, defaultYear: 2026, clock: clock).entries.map(\.id))
    }

    @Test func ungroundedModelDatesAndSideEffectsRequireReview() {
        let original = "明天交报告，提醒我周五下午两点给 Alex 打电话"
        let drafts = CaptureParser.validated([
            ExtractedTask(title: "交报告", source: "明天交报告", datePhrase: "下个月", action: .task),
            ExtractedTask(title: "给 Alex 打电话", source: "提醒我周五下午两点给 Alex 打电话", datePhrase: "周五下午两点", action: .task)
        ], original: original, clock: clock)
        #expect(drafts.count == 2)
        #expect(drafts.filter { !$0.requiresReview }.isEmpty)
        #expect(drafts.last?.action == .reminder)
    }
}
