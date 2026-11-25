import XCTest

final class FlowUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 900
    }

    func testFirstLaunchOneTapAndRelaunch() {
        let app = launch()
        tap("home.check", app)
        let checked = app.buttons["home.check"]
        let expected = NSPredicate(format: "exists == true AND label CONTAINS %@", "Checked in")
        expectation(for: expected, evaluatedWith: checked)
        waitForExpectations(timeout: 8)
        let label = checked.label
        checked.tap()
        XCTAssertEqual(checked.label, label)
        app.terminate()
        let restored = launch(reset: false)
        XCTAssertTrue(restored.buttons["home.check"].waitForExistence(timeout: 10))
        XCTAssertEqual(restored.buttons["home.check"].label, label)
    }

    func testDailyChangeAndPause() {
        let app = launch()
        tap("home.time", app)
        tap("plan.grace.60", app)
        tap("plan.save", app)
        tap("home.time", app)
        tap("plan.pause", app)
        tap("pause.save", app)
        XCTAssertTrue(element("plan.save", app).waitForExistence(timeout: 10))
    }

    func testInviteBuildsSystemSharePayload() {
        let app = launch()
        tap("home.contacts", app)
        tap("contacts.invite", app)
        for (key, value) in [("invite.nickname", "Lin"), ("invite.alias", "Jamie"),
                             ("invite.address", "jamie@example.test")] {
            let field = app.textFields[key]
            XCTAssertTrue(field.waitForExistence(timeout: 8))
            field.tap()
            field.typeText(value)
        }
        let done = app.keyboards.buttons["Done"]
        if done.exists { done.tap() }
        tap("invite.send", app)
        XCTAssertTrue(element("share.requested", app).waitForExistence(timeout: 12))
    }

    func testSendAndConfirmTestAndSetNumber() {
        var app = launch(["-demo"])
        tap("home.contacts", app)
        tap("contacts.test", app)
        tap("contacts.sendTest", app)
        XCTAssertTrue(element("app.message", app).waitForExistence(timeout: 8))
        app.terminate()
        app = launch(["-demo"])
        tab("Receive", app)
        tap("receive.open", app)
        tap("receive.testAck", app)
        XCTAssertTrue(element("app.message", app).waitForExistence(timeout: 8))
        tap("receive.contactAck", app)
        tap("receive.number", app)
        let field = app.textFields["receive.phoneInput"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText("2025550197")
        tap("receive.numberSave", app)
        XCTAssertTrue(reveal("receive.call", app).exists)
        XCTAssertTrue(reveal("receive.message", app).exists)
    }

    func testAcceptPrivateInviteAndShareReceipt() {
        let app = launch(["-accept-invite"])
        tap("receive.accept", app)
        tap("receive.return", app)
        XCTAssertTrue(element("share.requested", app).waitForExistence(timeout: 10))
    }

    func testCodePreviewApplyAndShareCard() {
        let app = launch(env: ["SOLO_TEST_CODE": "SCI1:1800:60:\n"])
        tab("Settings", app)
        tap("settings.paste", app)
        tap("code.apply", app)
        tap("settings.share", app)
        tap("share.send", app)
        XCTAssertTrue(element("share.requested", app).waitForExistence(timeout: 10))
    }

    func testExpiredRetainsHistoryAndDailyCheckIn() {
        let app = launch(["-expired"])
        tap("home.check", app)
        tab("Settings", app)
        tap("settings.history", app)
        XCTAssertTrue(element("history.entry", app).waitForExistence(timeout: 10))
        tap("history.export", app)
        XCTAssertTrue(reveal("purchase.buy", app).exists)
        XCTAssertTrue(reveal("purchase.restore", app).exists)
    }

    func testClearNeedsConfirmation() {
        let app = launch(["-demo", "-checked"])
        tab("Settings", app)
        tap("settings.clear", app)
        let confirm = app.alerts.buttons["Clear data"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 8))
        confirm.tap()
        XCTAssertTrue(element("app.message", app).waitForExistence(timeout: 8))
        tab("Check in", app)
        XCTAssertEqual(reveal("home.check", app).label, "I’m okay")
    }

    func testStoreShotsEnglish() { storeShots("en") }
    func testStoreShotsSimplifiedChinese() { storeShots("zh-Hans") }
    func testStoreShotsTraditionalChinese() { storeShots("zh-Hant") }

    func testPaywallShot() {
        let app = launch(["-paywall"], language: "zh-Hans")
        XCTAssertTrue(app.staticTexts["高级版买断"].waitForExistence(timeout: 12))
        XCTAssertTrue(element("purchase.buy", app).waitForExistence(timeout: 10))
        shot("paid-01-paywall")
    }

    private func storeShots(_ lang: String) {
        var app = launch(["-demo", "-checked", "-trip-demo"], language: lang)
        XCTAssertTrue(element("home.sync", app).waitForExistence(timeout: 10))
        shot("store-\(lang)-01-home")
        tap("home.time", app)
        XCTAssertTrue(element("plan.grace.30", app).waitForExistence(timeout: 10))
        shot("store-\(lang)-02-time")
        tap("plan.travel", app)
        XCTAssertTrue(element("trip.returns", app).waitForExistence(timeout: 10))
        shot("store-\(lang)-05-travel")
        app.terminate()
        app = launch(["-demo", "-reminder"], language: lang)
        XCTAssertTrue(element("home.reminder", app).waitForExistence(timeout: 10))
        shot("store-\(lang)-03-reminder")
        tap("home.contacts", app)
        XCTAssertTrue(element("contacts.status", app).waitForExistence(timeout: 10))
        shot("store-\(lang)-04-contacts")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch(_ flags: [String] = [], language: String = "en", reset: Bool = true,
                        env: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        let locale = language == "zh-Hans" ? "zh_CN" : (language == "zh-Hant" ? "zh_TW" : "en_US")
        app.launchArguments = ["-ui-testing"] + (reset ? ["-reset"] : []) + flags
            + ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launchEnvironment = env
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12))
        return app
    }

    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func reveal(_ id: String, _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let item = element(id, app)
        _ = item.waitForExistence(timeout: 4)
        for _ in 0..<6 {
            let bar = app.tabBars.firstMatch
            let bottom = bar.exists ? bar.frame.minY : app.frame.maxY
            if item.exists && item.isHittable && item.frame.maxY <= bottom - 2 { return item }
            let scroll = app.scrollViews.firstMatch
            if item.exists && item.frame.maxY < app.frame.minY + 64 {
                if scroll.exists { scroll.swipeDown() } else { app.swipeDown() }
            } else if scroll.exists { scroll.swipeUp() } else { app.swipeUp() }
        }
        XCTFail("Unable to reveal \(id)", file: file, line: line)
        return item
    }

    private func tap(_ id: String, _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        reveal(id, app, file: file, line: line).tap()
    }

    private func tab(_ title: String, _ app: XCUIApplication) {
        let item = app.tabBars.buttons[title]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.tap()
    }
}
