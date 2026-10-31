import XCTest

/// 「管理」页：fixture 模式下的示例供应商、网关密钥（`FixtureManageService`）。
@MainActor
final class ManageUITests: XCTestCase {
    private var launchTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["MAGPIE_REMOTE_WARMUP_TIMEOUT"].flatMap { TimeInterval($0) } ?? 45
    }

    private func launchManage() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let tab = app.tabBars.buttons["管理"]
        XCTAssertTrue(tab.waitForExistence(timeout: launchTimeout), "没有出现「管理」标签")
        tab.tap()
        XCTAssertTrue(app.navigationBars["管理"].waitForExistence(timeout: 10))
        return app
    }

    private func element(id identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// 在列表 / 表单里向下滑，直到元素出现在屏幕上。
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 6) {
        var tries = 0
        while (!element.exists || !element.isHittable) && tries < attempts {
            app.swipeUp()
            tries += 1
        }
    }

    private func openSection(_ identifier: String, title: String, in app: XCUIApplication) {
        let link = element(id: identifier, in: app)
        XCTAssertTrue(link.waitForExistence(timeout: 15), "没有出现入口 \(identifier)")
        scrollTo(link, in: app)
        link.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), "没有打开「\(title)」")
    }

    func testProvidersListShowsFixtureProviders() {
        let app = launchManage()
        openSection("manage.providers", title: "供应商", in: app)
        XCTAssertTrue(element(containing: "示例中转", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "示例 DeepSeek", in: app).exists)
        XCTAssertTrue(element(containing: "示例 Codex 订阅", in: app).exists)
    }

    func testDeleteProviderAsksForConfirmation() {
        let app = launchManage()
        openSection("manage.providers", title: "供应商", in: app)
        let row = element(id: "provider.row.relay-example", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let delete = element(id: "provider.delete", in: app)
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        scrollTo(delete, in: app)
        delete.tap()
        let confirm = app.buttons["删除供应商"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "删除前应当先弹出确认")
        confirm.tap()
        // 删除后回到列表，示例中转不再出现
        XCTAssertTrue(app.navigationBars["供应商"].waitForExistence(timeout: 10))
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: element(id: "provider.row.relay-example", in: app))
        waitForExpectations(timeout: 10)
        XCTAssertTrue(element(containing: "示例 DeepSeek", in: app).exists)
    }

    func testCreateGatewayKeyShowsSecretOnce() {
        let app = launchManage()
        openSection("manage.keys", title: "网关密钥", in: app)
        XCTAssertTrue(element(containing: "iPhone", in: app).waitForExistence(timeout: 10))
        let add = element(id: "key.add", in: app)
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let name = app.textFields["key.new.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        element(id: "key.new.create", in: app).tap()
        let secret = element(id: "key.secret.value", in: app)
        XCTAssertTrue(secret.waitForExistence(timeout: 10), "创建后应当显示完整密钥")
        XCTAssertTrue(secret.label.contains("sk-magpie-key-EXAMPLE-NEW"), "显示的不是新密钥：\(secret.label)")
        XCTAssertTrue(element(id: "key.secret.copy", in: app).exists)
        XCTAssertTrue(element(containing: "只显示这一次", in: app).exists)
        element(id: "key.secret.done", in: app).tap()
        // 新密钥出现在列表里（示例数据原有 3 把）
        let rows = app.descendants(matching: .any).matching(identifier: "key.row")
        expectation(for: NSPredicate(format: "count == 4"), evaluatedWith: rows)
        waitForExpectations(timeout: 10)
    }
}
