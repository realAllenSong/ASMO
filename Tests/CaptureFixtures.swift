import Foundation
import Testing
@testable import ASMOCore

struct CaptureFixtures {
    struct Example: Sendable {
        var text: String
        var date: String?
        var review: Bool

        init(_ text: String, _ date: String?, review: Bool = false) {
            self.text = text
            self.date = date
            self.review = review
        }
    }

    private static let examples = [
        Example("今天准备 pitch", "2026年11月5日"),
        Example("明天交 draft review", "2026年11月6日"),
        Example("后天给 Alex 打电话", "2026年11月7日"),
        Example("大后天整理 inbox", "2026年11月8日"),
        Example("昨天回的邮件", "2026年11月4日"),
        Example("前天填表", "2026年11月3日"),
        Example("今天天气不错", "2026年11月5日"),
        Example("今晚7点 跟 book club 小伙伴约饭", "2026年11月5日 19:00"),
        Example("明早八点 跟 Chris 开会", "2026年11月6日 08:00"),
        Example("明天下午一点半 理发", "2026年11月6日 13:30"),
        Example("今天中午十二点吃饭", "2026年11月5日 12:00"),
        Example("明天凌晨十二点整理资料", "2026年11月6日 00:00"),
        Example("下午两点半做 slide", "2026年11月5日 14:30"),
        Example("上午八点一刻 交表", "2026年11月5日 08:15"),
        Example("晚上十点三刻 到家", "2026年11月5日 22:45"),
        Example("17:05发材料", "2026年11月5日 17:05"),
        Example("tomorrow at 3pm submit PR", "2026年11月6日 15:00"),
        Example("today at 12am check results", "2026年11月5日 00:00"),
        Example("tomorrow at 12pm lunch", "2026年11月6日 12:00"),
        Example("Friday 7:30 pm dinner", "2026年11月6日 19:30"),
        Example("this Monday 做了调研", "2026年11月2日"),
        Example("next Monday 9:00 follow up", "2026年11月9日 09:00"),
        Example("周五下午两点给 Jordan 写信", "2026年11月6日 14:00"),
        Example("下周五写邮件", "2026年11月13日"),
        Example("这周三记录", "2026年11月4日"),
        Example("下个月续费域名", "2026年12月"),
        Example("下下个月续费域名", "2027年1月"),
        Example("本月准备材料", "2026年11月"),
        Example("next month renew domains", "2026年12月"),
        Example("明年三月继续投", "2027年3月"),
        Example("明年十月取消订阅", "2027年10月"),
        Example("明年三月十五号面试", "2027年3月15日"),
        Example("11月18日 review 结束", "2026年11月18日"),
        Example("2027.3：续费域名", "2027年3月"),
        Example("2027年3月：续费域名", "2027年3月"),
        Example("2027-03-15 跟 Alex 开会", "2027年3月15日"),
        Example("2028.2.29 跟 Alex 开会", "2028年2月29日"),
        Example("12.16：design review 出结果", "2026年12月16日"),
        Example("2027.2.29 写材料", nil, review: true),
        Example("明天25:30去机场", nil, review: true),
        Example("明天下午13点面试", nil, review: true),
        Example("改天跟 Alex 约饭", nil, review: true),
        Example("月底续费", nil, review: true),
        Example("明天下午两点提醒我去理发", "2026年11月6日 14:00", review: true),
        Example("提醒我周五下午两点去理发", "2026年11月6日 14:00", review: true),
        Example("周五下午两点把牙医写进日历", "2026年11月6日 14:00", review: true),
        Example("我下午两点要开会", "2026年11月5日 14:00"),
        Example("开会 下午三点半", "2026年11月5日 15:30"),
        Example("我明天下午两点要去理发", "2026年11月6日 14:00"),
        Example("明天和 Alex 下午三点开会", "2026年11月6日 15:00"),
        Example("跟 Chris 明天 10:30 开会", "2026年11月6日 10:30"),
        Example("submit PR at 3pm", "2026年11月5日 15:00"),
        Example("多吃一点蔬菜", nil),
        Example("买3个苹果", nil)
    ]

    @Test func embeddedTimeLeavesACleanTitle() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let clock = CaptureClock(now: calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 9))!,
                                 calendar: calendar)
        #expect(CaptureParser.manual("我下午两点要开会", clock: clock).title == "开会")
        #expect(CaptureParser.manual("我明天下午两点要去理发", clock: clock).title == "去理发")
        #expect(CaptureParser.manual("明天和 Alex 下午三点开会", clock: clock).title == "和 Alex 开会")
        #expect(CaptureParser.manual("跟 Chris 明天 10:30 开会", clock: clock).title == "跟 Chris 开会")
    }

    @Test(arguments: examples)
    func manualDates(_ example: Example) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 23))!
        let result = CaptureParser.manual(example.text, clock: CaptureClock(now: now, calendar: calendar))
        #expect(result.schedule?.label == example.date)
        #expect(result.requiresReview == example.review)
    }

    @Test func preservesThreeVerbatimTasksWithoutASideEffect() {
        let original = "明天联系 Alex，明年三月续费域名，周五下午两点把牙医写进日历"
        let drafts = CaptureParser.validated([
            .init(title: "联系 Alex", source: "明天联系 Alex", datePhrase: "明天", action: .task),
            .init(title: "续费域名", source: "明年三月续费域名", datePhrase: "明年三月", action: .task),
            .init(title: "牙医", source: "周五下午两点把牙医写进日历", datePhrase: "周五下午两点", action: .event)
        ], original: original, clock: CaptureClock())
        #expect(drafts.map(\.action) == [.task, .task, .event])
        #expect(drafts.map(\.requiresReview) == [false, false, true])
        #expect(drafts[1].schedule?.day == nil)
    }
}
