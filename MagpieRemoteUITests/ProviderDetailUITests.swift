import XCTest

/// 供应商详情：已保存的 Base URL、Key 默认是圆点，点眼睛取回明文、再点隐藏；可以再添加一把 Key。
/// fixture 数据见 `FixtureManageService`（示例中转有两把假 Key：fx-key-1「主力」、fx-key-2「备用」）。
@MainActor
final class ProviderDetailUITests: XCTestCase {
    private var launchTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["MAGPIE_REMOTE_WARMUP_TIMEOUT"].flatMap { TimeInterval($0) } ?? 45
    }

    private func element(id identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 6) {
        var tries = 0
        while (!element.exists || !element.isHittable) && tries < attempts {
            app.swipeUp()
            tries += 1
        }
    }

    /// 打开供应商列表：「主页」分页器里的「供应商」。
    private func openProviders(_ app: XCUIApplication) {
        app.openHome("供应商")
    }

    private func openRelay() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.waitForDock(timeout: launchTimeout), "没有出现底栏「更多」")
        openProviders(app)
        let row = element(id: "provider.row.relay-example", in: app)
        XCTAssertTrue(row.appears(timeout: 10))
        row.tap()
        return app
    }

    func testSavedBaseURLAndKeyRevealToggle() {
        let app = openRelay()
        let chat = app.textFields["provider.chat"]
        XCTAssertTrue(chat.appears(timeout: 10))
        XCTAssertEqual(chat.value as? String, "https://relay.example/v1", "应当显示已保存的 Base URL")

        let value = element(id: "provider.key.value.fx-key-1", in: app)
        scrollTo(value, in: app)
        XCTAssertTrue(value.appears(timeout: 10))
        XCTAssertFalse(value.label.contains("EXAMPLE"), "默认不应显示明文：\(value.label)")

        let eye = element(id: "provider.key.reveal.fx-key-1", in: app)
        XCTAssertTrue(eye.exists)
        eye.tap()
        XCTAssertTrue(value.hasLabel(containing: "sk-relay-EXAMPLE-MAIN1", within: 10), "点眼睛后没有显示明文")
        // 另一把仍然是隐藏的
        XCTAssertFalse(element(id: "provider.key.value.fx-key-2", in: app).label.contains("EXAMPLE"))

        element(id: "provider.key.reveal.fx-key-1", in: app).tap()
        XCTAssertTrue(waitUntil(10) { value.exists && !value.label.contains("EXAMPLE") }, "再点眼睛后没有隐藏明文")
    }

    func testAddAnotherKey() {
        let app = openRelay()
        let add = element(id: "provider.key.add", in: app)
        _ = add.appears(timeout: 10)
        scrollTo(add, in: app)
        XCTAssertTrue(add.exists)
        add.tap()
        let name = app.textFields["provider.key.new.name"]
        XCTAssertTrue(name.appears(timeout: 10))
        name.tap()
        name.typeText("团队")
        let key = app.secureTextFields["provider.key.new.value"]
        XCTAssertTrue(key.exists)
        key.tap()
        key.typeText("sk-relay-EXAMPLE-TEAM3")
        element(id: "provider.key.new.save", in: app).tap()
        // 新的一把出现在列表里，同样默认隐藏
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "provider.key.row.fx-key-new")).firstMatch
        XCTAssertTrue(row.appears(timeout: 10), "添加后应当出现新的 Key")
        let value = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "provider.key.value.fx-key-new")).firstMatch
        XCTAssertFalse(value.label.contains("EXAMPLE"))
    }
}
