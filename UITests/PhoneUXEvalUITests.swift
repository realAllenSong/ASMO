import XCTest

/// The phone experience eval: what "good on an iPhone" means for 逐日, written as checks a simulator can run.
/// Each criterion has a name (E1…); `script/ux-eval.sh` runs them and prints the scorecard. A change to the phone
/// app is not shown to anyone until this passes.
///
/// The bar it sets (why someone would pick this over Apple Calendar or a to-do list):
/// one month readable at a glance, any day one tap away, a thing noted in one sentence, nothing in the way
/// (keyboard, modes, buttons), and every gesture a thumb tries does what an iPhone user expects.
final class PhoneUXEvalUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchEnvironment["ASMO_TEST_STORE"] = "demo"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(title.waitForExistence(timeout: 6))
    }

    private var title: XCUIElement { app.buttons["monthMenu"] }
    private func day(_ key: String) -> XCUIElement { app.descendants(matching: .any)["calendar-day-" + key] }
    private var screen: CGRect { app.windows.firstMatch.frame }
    private func tapOutside() { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22)).tap() }

    private var todayKey: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func monthKey(offset: Int) -> String {
        let date = Calendar.current.date(byAdding: .month, value: offset, to: Date())!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    // MARK: The month at a glance

    @MainActor
    func testE1_LaunchShowsThisWholeMonth() {
        let first = day(monthKey(offset: 0) + "-01")
        XCTAssertTrue(first.exists, "E1 the 1st of this month is on screen at launch")
        XCTAssertLessThan(first.frame.minY - title.frame.maxY, 40, "E1 the month starts right under the title (no leftover of last month)")
        XCTAssertTrue(day(todayKey).isHittable, "E1 today is visible without scrolling")
        let last = day(monthKey(offset: 0) + "-28")
        XCTAssertTrue(last.exists && last.frame.maxY <= screen.maxY, "E1 the whole month fits on one screen")
    }

    @MainActor
    func testE2_CellsAreRoomyAndReadable() {
        let cell = day(todayKey)
        XCTAssertGreaterThanOrEqual(cell.frame.width, 70, "E2 a day is wide enough to read a few words")
        XCTAssertGreaterThanOrEqual(cell.frame.height, 88, "E2 a day is tall enough for several lines")
        let month = (1...28).map { day(monthKey(offset: 0) + String(format: "-%02d", $0)) }.filter(\.exists)
        let used = (month.map(\.frame.maxY).max() ?? 0) - (month.map(\.frame.minY).min() ?? 0)
        XCTAssertGreaterThan(used / (screen.height - title.frame.maxY), 0.72, "E2 the month uses the screen instead of leaving it empty")
    }

    @MainActor
    func testE3_SwipingMovesExactlyOneMonth() {
        app.swipeUp()
        let next = day(monthKey(offset: 1) + "-01")
        XCTAssertTrue(next.waitForExistence(timeout: 2), "E3 swiping up shows next month")
        XCTAssertLessThan(abs(next.frame.minY - title.frame.maxY), 40, "E3 the next month lands aligned at the top")
        XCTAssertFalse(day(todayKey).isHittable, "E3 nothing of this month is left behind")
        app.swipeDown()
        XCTAssertTrue(day(todayKey).waitForExistence(timeout: 2) && day(todayKey).isHittable, "E3 swiping down comes back")
        app.swipeUp(velocity: .fast); app.swipeUp(velocity: .fast); app.swipeUp(velocity: .fast)
        XCTAssertTrue(app.buttons["todayButton"].waitForExistence(timeout: 2), "E3 away from today there is a way back")
        app.buttons["todayButton"].tap()
        XCTAssertTrue(day(todayKey).waitForExistence(timeout: 3) && day(todayKey).isHittable, "E3 今天 returns to today in one tap")
    }

    @MainActor
    func testE4_MonthPickerJumps() {
        title.tap()
        let march = app.buttons["pick-month-3"]
        XCTAssertTrue(march.waitForExistence(timeout: 2), "E4 tapping the title drops down the months")
        XCTAssertGreaterThanOrEqual(march.frame.height, 40, "E4 months are thumb-sized")
        march.tap()
        XCTAssertTrue(title.label.contains("3"), "E4 picking a month goes there")
        app.buttons["todayButton"].tap()
    }

    // MARK: A day

    @MainActor
    func testE5_PressAndHoldPeeks() {
        day(todayKey).press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["打开这一天"].waitForExistence(timeout: 2), "E5 press and hold previews the day with actions")
        XCTAssertTrue(app.buttons["记到这一天"].exists, "E5 the preview offers writing on that day")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).tap()
        XCTAssertTrue(title.waitForExistence(timeout: 3), "E5 tapping away closes the preview")
    }

    @MainActor
    func testE6_DayOpensToReadAndLeavesByEdgeSwipe() {
        day(todayKey).tap()
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 2), "E6 a day opens with a back button")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "E6 a day opens to be read: no keyboard")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        XCTAssertTrue(title.waitForExistence(timeout: 3), "E6 swiping from the left edge goes back")
    }

    @MainActor
    func testE7_WritingOnADayAndLeavingKeepsIt() {
        let line = "评测写的一行\(Int.random(in: 100...999))"
        day(todayKey).tap()
        let page = app.descendants(matching: .any)["pageText"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 2))
        page.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2), "E7 tapping the page starts writing")
        app.typeText(line)
        XCTAssertTrue(app.buttons["完成"].exists, "E7 while typing there is 完成 to put the keyboard away")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        // It is kept at once, and becomes an item a moment later (the rules read it after the page closes).
        let kept = day(todayKey)
        let deadline = Date().addingTimeInterval(12)
        while !kept.label.contains(line), Date() < deadline { sleep(1) }
        XCTAssertTrue(kept.label.contains(line), "E7 what was written is kept after leaving mid-typing")
        day(todayKey).tap()
        app.navigationBars.buttons.firstMatch.tap()
    }

    // MARK: Noting something

    @MainActor
    func testE8_BarAndKeyboard() {
        app.buttons["captureBarOpen"].tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3), "E8 one tap and you can type")
        let field = app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        XCTAssertTrue(field.exists && field.frame.maxY <= keyboard.frame.minY + 1, "E8 the input is above the keyboard, never under it")
        XCTAssertTrue(day(monthKey(offset: 0) + "-01").exists, "E8 the calendar stays put behind the keyboard")
        app.typeText("草稿")
        tapOutside()
        XCTAssertFalse(keyboard.waitForExistence(timeout: 1), "E8 a tap anywhere outside puts the keyboard away")
        XCTAssertTrue(title.exists, "E8 that tap only closes the keyboard (it doesn't open a day)")
        XCTAssertEqual(app.buttons["captureBarOpen"].label.isEmpty, false)
        app.buttons["captureBarOpen"].tap()
        let again = app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        XCTAssertTrue((again.value as? String ?? "").contains("草稿"), "E8 the draft is still there")
        app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
        tapOutside()
    }

    @MainActor
    func testE9_OneSentenceBecomesAnItemAndCanBeUndone() {
        let name = "评测咖啡\(Int.random(in: 100...999))"
        app.buttons["captureBarOpen"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.typeText("明天下午三点\(name)\n")
        let notice = app.descendants(matching: .any)["plannerNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 4), "E9 sending says what happened")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "E9 after sending, the keyboard gets out of the way")
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let cell = day(formatter.string(from: tomorrow))
        if cell.exists { XCTAssertTrue(cell.label.contains(name), "E9 the item is on tomorrow, read from the sentence") }
        let undo = app.buttons["noticeUndo"]
        XCTAssertTrue(undo.exists, "E9 it can be undone right there")
        undo.tap()
        if cell.exists { XCTAssertFalse(cell.label.contains(name), "E9 undo takes it back") }
    }

    @MainActor
    func testE10_FiddlingNeverBreaksIt() {
        app.buttons["captureBarOpen"].tap()
        app.buttons["设置"].tap()
        app.swipeDown(velocity: .fast)
        day(todayKey).doubleTap()
        if app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 2) { app.navigationBars.buttons.firstMatch.tap() }
        app.swipeUp(velocity: .fast); app.swipeLeft(); app.swipeDown(velocity: .fast); app.swipeRight()
        title.tap(); tapOutside()
        XCTAssertTrue(title.waitForExistence(timeout: 4), "E10 after random fiddling the calendar still answers")
        if app.buttons["todayButton"].exists { app.buttons["todayButton"].tap() }
        XCTAssertTrue(day(todayKey).waitForExistence(timeout: 3), "E10 and today is reachable")
    }
}
