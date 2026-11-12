import XCTest

final class PlannerUITests: XCTestCase {
    @MainActor
    func testCalendarEventUsesFifteenMinuteAlert() throws {
        let app = XCUIApplication()
        app.launch()
        try XCTSkipIf(app.buttons["连接 Apple 日历"].exists, "Grant Calendar access on the isolated simulator first.")
        let input = app.textViews["captureInput"].firstMatch
        let composer = input.exists ? input : app.textFields["captureInput"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let title = "ASMO event \(UUID().uuidString.prefix(5))"
        composer.tap()
        composer.typeText("tomorrow 15:00-16:00 add \(title) to calendar")
        app.buttons["captureSave"].tap()
        XCTAssertTrue(app.staticTexts["确认这一条"].waitForExistence(timeout: 5))
        let save = app.buttons["保存"]
        XCTAssertTrue(save.exists)
        save.tap()
        XCTAssertTrue(app.buttons["后一天"].waitForExistence(timeout: 5))
        app.buttons["后一天"].tap()
        let event = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 5))
        XCTAssertTrue(event.label.contains("14:45"))
    }

    @MainActor
    func testTimedCaptureShowsStartAndEnd() {
        let app = XCUIApplication()
        app.launch()
        let input = app.textViews["captureInput"].firstMatch
        let composer = input.exists ? input : app.textFields["captureInput"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("15:00-16:30 ASMO time block")
        app.buttons["captureSave"].tap()

        XCTAssertTrue(app.staticTexts["时间线"].exists)
        let task = app.buttons["ASMO time block"]
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["15:00"].exists)
        XCTAssertTrue(app.staticTexts["到 16:30"].exists)
        app.buttons["撤销"].tap()
        XCTAssertFalse(task.exists)
    }

    @MainActor
    func testImportantDateImportAppearsInDateHeader() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["更多"].tap()
        app.buttons["重要日期"].tap()
        app.buttons["粘贴生日或纪念日归档"].tap()
        let editor = app.textViews["importantDatePaste"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        let date = Calendar.current.dateComponents([.month, .day], from: .now)
        let title = "ASMO sample \(UUID().uuidString.prefix(5))"
        editor.typeText("\(date.month!).\(date.day!): \(title)")
        app.buttons["预览"].tap()
        XCTAssertTrue(app.staticTexts["\(title)生日"].exists)
        app.buttons["导入"].tap()
        app.buttons["完成"].tap()

        XCTAssertTrue(app.staticTexts["\(title)生日"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "ASMO important date preview"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testMonthCaptureCompletesAndUndoes() {
        let app = XCUIApplication()
        app.launch()
        let title = "ASMO monthly smoke"
        let input = app.textViews["captureInput"].firstMatch
        let composer = input.exists ? input : app.textFields["captureInput"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("2032.3: \(title)")
        app.buttons["captureSave"].tap()

        XCTAssertTrue(app.staticTexts["3月计划"].waitForExistence(timeout: 5))
        let checkbox = app.buttons["完成 \(title)"]
        XCTAssertTrue(checkbox.exists)
        checkbox.tap()
        XCTAssertTrue(app.buttons["恢复 \(title)"].exists)
        app.buttons["撤销"].tap()
        XCTAssertFalse(app.buttons["恢复 \(title)"].exists)
    }

    @MainActor
    func testReminderCaptureNeedsExplicitConfirmation() {
        let app = XCUIApplication()
        app.launch()
        let input = app.textViews["captureInput"].firstMatch
        let composer = input.exists ? input : app.textFields["captureInput"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("remind me tomorrow at 3pm to review ASMO")
        app.buttons["captureSave"].tap()

        XCTAssertTrue(app.staticTexts["确认这一条"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["保存"].exists)
        app.buttons["跳过"].tap()
        XCTAssertFalse(app.staticTexts["确认这一条"].exists)
    }
}
