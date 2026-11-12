import XCTest

/// Fiddling the way a real thumb does: fast flicks, taps during animations, the keyboard in the way, empty and
/// very long input, leaving mid-typing. After each step the app must still answer, and a screenshot is saved
/// (ASMO_SHOTS=<folder>) for review.
final class PhoneChaosUITests: XCTestCase {
    private var app: XCUIApplication!
    private var folder = ""
    private var step = 0

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchEnvironment["ASMO_TEST_STORE"] = "demo"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-desktopAppearance", "system"]
        folder = ProcessInfo.processInfo.environment["ASMO_SHOTS"] ?? NSTemporaryDirectory()
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    private func shot(_ name: String) {
        step += 1
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(String(format: "%02d-%@.png", step, name)))
    }

    private var home: XCUIElement { app.buttons["monthMenu"] }

    private func alive(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(home.waitForExistence(timeout: 4), "the calendar should still be there after: \(what)", file: file, line: line)
    }

    @MainActor
    func testFiddling() {
        app.launch()
        alive("launch")
        shot("home")

        // Scrolling through months, slow and fast.
        app.swipeUp(velocity: .slow); shot("scroll-slow")
        app.swipeUp(velocity: .fast); app.swipeUp(velocity: .fast); shot("flick-twice")
        app.swipeDown(velocity: .fast); app.swipeDown(velocity: .fast); app.swipeDown(velocity: .fast); shot("flick-back")
        if app.buttons["todayButton"].waitForExistence(timeout: 1) { app.buttons["todayButton"].tap() }
        sleep(1); shot("today"); alive("today")

        // Month picker: open, change year, pick; open and dismiss by tapping elsewhere.
        home.tap(); sleep(1); shot("picker")
        app.buttons["pick-month-2"].tap(); sleep(1); shot("picked-feb")
        home.tap(); sleep(1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap(); sleep(1); shot("picker-dismissed")
        alive("picker dismissed")
        if app.buttons["todayButton"].waitForExistence(timeout: 1) { app.buttons["todayButton"].tap() }
        sleep(1)

        // The bar: open, the keyboard must not hide it; send nothing; tap the calendar to put the keyboard away.
        app.buttons["captureBarOpen"].tap(); sleep(1); shot("bar-open")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "the bar brings up the keyboard")
        let field = app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        XCTAssertTrue(field.exists && field.frame.maxY <= app.keyboards.firstMatch.frame.minY + 1,
                      "the input stays above the keyboard (field \(field.exists ? field.frame : .zero), keyboard \(app.keyboards.firstMatch.frame))")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap(); sleep(1); shot("bar-tapped-away")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "tapping the calendar puts the keyboard away")
        alive("bar tapped away")

        // Open the bar, type a very long line, scroll the calendar with the keyboard up, put it away with 收起.
        app.buttons["captureBarOpen"].tap(); sleep(1)
        app.typeText(String(repeating: "明天下午三点和小林在公司楼下的咖啡店讨论下个季度的产品发布计划", count: 2))
        sleep(1); shot("bar-long-text")
        app.swipeUp(velocity: .fast); sleep(1); shot("scrolled-with-keyboard")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        sleep(1); shot("bar-closed-with-draft")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "a tap outside puts the keyboard away")
        if app.buttons["todayButton"].waitForExistence(timeout: 1) { app.buttons["todayButton"].tap() }
        sleep(1)

        // Open a day, tap into the page, then leave mid-typing by the edge swipe.
        let day = app.descendants(matching: .any)["calendar-day-2026-11-11"]
        if day.waitForExistence(timeout: 3) { day.tap() }
        sleep(2); shot("day")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "a day opens without the keyboard")
        let page = app.descendants(matching: .any)["pageText"].firstMatch
        if page.waitForExistence(timeout: 2) { page.tap(); sleep(1); app.typeText("手机上补一句") }
        shot("day-typing")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        sleep(2); shot("left-mid-typing")
        alive("edge swipe while typing")

        // Double taps and quick double opens.
        if day.waitForExistence(timeout: 2) { day.doubleTap() }
        sleep(2); shot("double-tap-day")
        if app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.firstMatch.tap() }
        sleep(2); alive("back after double tap"); shot("back")

        // Settings while the bar is open.
        app.buttons["captureBarOpen"].tap(); sleep(1)
        app.buttons["设置"].tap(); sleep(1); shot("settings-with-bar")
        app.swipeDown(velocity: .fast); sleep(1); shot("settings-dismissed")
        alive("settings dismissed")
    }
}
