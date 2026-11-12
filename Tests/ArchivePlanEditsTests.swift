import Foundation
import Testing
@testable import ASMOCore

struct ArchivePlanEditsTests {
    @Test func editsCanSplitWithoutChangingDayOrInventingADayForAMonth() {
        let clock = CaptureClock()
        let source = ArchiveParser.parse("2027.1.8: 下午1点半理发，回邮件\n2027.3: 续费域名",
                                         defaultYear: 2026, clock: clock).entries
        let text = """
        2027-01-08: 13:30 理发
        2027-01-08: 回邮件
        2027-03: 续费域名
        2027-03: 续费域名
        2027-04: 不在原文的日期
        """
        let result = ArchivePlanEdits.validate(text, entries: source, clock: clock)
        #expect(result.invalidLines == [5])
        #expect(result.drafts.count == 3)
        #expect(result.drafts[0].schedule.hour == 13)
        #expect(result.drafts[0].schedule.minute == 30)
        #expect(result.drafts[0].sourceIDs == result.drafts[1].sourceIDs)
        #expect(result.drafts[0].sourceText == "下午1点半理发，回邮件")
        #expect(result.drafts[2].schedule.day == nil)
    }

    @Test func oldDatesAreFindableInTheWayTheyWereWritten() {
        let record = ArchiveEntry(id: "example", schedule: PlanDate(year: 2021, month: 8, day: 24), body: "发邮件")
        #expect(ArchivePlanEdits.matches("2021.8.24", entry: record))
        #expect(ArchivePlanEdits.matches("8.24", entry: record))
        #expect(ArchivePlanEdits.matches("2021-08-24", entry: record))
        #expect(!ArchivePlanEdits.matches("2022.8.24", entry: record))
    }
}
