import XCTest

/// Walks through the phone app the way a thumb does (swipes, taps, typing) on the demo store and saves a screenshot
/// after each step, for reviewing the touch experience. Run with ASMO_SHOTS=<folder> to choose where they go.
final class PhoneWalkthroughUITests: XCTestCase {
    private var app: XCUIApplication!
    private var folder = ""
    private var step = 0

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchEnvironment["ASMO_TEST_STORE"] = "demo"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)"]
        folder = ProcessInfo.processInfo.environment["ASMO_SHOTS"] ?? NSTemporaryDirectory()
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    private func shot(_ name: String) {
        step += 1
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(String(format: "%02d-%@.png", step, name)))
    }

    @MainActor
    func testWalkThrough() {
        app.launch()
        sleep(2)
        shot("home")

        // Thumb habits on the month: scroll up and down, then sideways.
        app.swipeUp()
        sleep(1)
        shot("swipe-up")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "12月")).firstMatch.exists, "swiping up shows the next month")
        app.swipeDown()
        sleep(1)
        shot("swipe-down")
        app.swipeLeft()
        sleep(1)
        shot("swipe-left")
        app.swipeRight()
        sleep(1)
        shot("swipe-right")

        // Open a busy day.
        let day = app.descendants(matching: .any)["calendar-day-2026-11-11"]
        if day.waitForExistence(timeout: 3) { day.tap() }
        sleep(2)
        shot("day-open")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "opening a day to read it shouldn't bring up the keyboard")
        app.swipeUp()
        sleep(1)
        shot("day-scrolled")
        app.swipeDown()
        sleep(1)
        shot("day-scrolled-back")
        let done = app.buttons["完成"]
        if done.exists { done.tap() }
        sleep(2)
        shot("day-closed")

        // The capture bar.
        let bar = app.buttons["captureBarOpen"]
        if bar.waitForExistence(timeout: 3) { bar.tap() }
        sleep(1)
        shot("bar-open")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "the bar should bring up the keyboard")
        app.typeText("明天下午三点和小林喝咖啡")
        sleep(1)
        shot("bar-typed")
    }
}
