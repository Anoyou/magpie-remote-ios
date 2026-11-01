import XCTest

/// 「管理 › 插件」：fixture 模式下的示例插件（`FixturePluginService`）。
@MainActor
final class PluginsUITests: XCTestCase {
    private var launchTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["MAGPIE_REMOTE_WARMUP_TIMEOUT"].flatMap { TimeInterval($0) } ?? 45
    }

    private func element(id identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 8) {
        var tries = 0
        while (!element.exists || !element.isHittable) && tries < attempts {
            app.swipeUp()
            tries += 1
        }
    }

    /// 打开「管理 › 插件」。
    private func launchPlugins() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let tab = app.tabBars.buttons["管理"]
        XCTAssertTrue(tab.waitForExistence(timeout: launchTimeout), "没有出现「管理」标签")
        tab.tap()
        XCTAssertTrue(app.navigationBars["管理"].waitForExistence(timeout: 10))
        let link = element(id: "manage.plugins", in: app)
        XCTAssertTrue(link.waitForExistence(timeout: 15), "没有出现「插件」入口")
        scrollTo(link, in: app)
        link.tap()
        XCTAssertTrue(app.navigationBars["插件"].waitForExistence(timeout: 10), "没有打开「插件」")
        return app
    }

    func testListShowsInstalledAndBuiltinPlugins() {
        let app = launchPlugins()
        XCTAssertTrue(element(containing: "示例云登录", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "示例仪表盘", in: app).exists)
        XCTAssertTrue(element(containing: "已停用", in: app).exists, "停用的示例中间件应标出「已停用」")
        let builtin = element(id: "plugins.builtin.sessions", in: app)
        scrollTo(builtin, in: app)
        XCTAssertTrue(builtin.exists, "应列出内置插件")
        XCTAssertTrue(element(containing: "会话", in: app).exists, "内置插件应显示中文名称")
    }

    func testAddPluginFromSpecAsksForConfirmation() {
        let app = launchPlugins()
        XCTAssertTrue(element(containing: "示例云登录", in: app).waitForExistence(timeout: 10))
        element(id: "plugins.add", in: app).tap()
        let field = app.textFields["plugin.add.spec"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("example-new-plugin")
        element(id: "plugin.add.submit", in: app).tap()
        let confirm = app.buttons["安装"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "安装前应当先弹出确认")
        confirm.tap()
        // 安装后表单关闭，新插件出现在列表里
        XCTAssertTrue(app.navigationBars["插件"].waitForExistence(timeout: 10))
        XCTAssertTrue(element(id: "plugins.row.example-new-plugin", in: app).waitForExistence(timeout: 10), "新插件应出现在列表里")
    }

    func testRemovePluginAsksForConfirmationAndTogglesWork() {
        let app = launchPlugins()
        let row = element(id: "plugins.row.github:example-owner/magpie-dash", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let toggle = element(id: "plugin.toggle", in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "1")
        // 点开关本身（右侧），点中间的标签不会切换
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "value == '0'"), evaluatedWith: toggle)
        waitForExpectations(timeout: 10)

        let remove = element(id: "plugin.remove", in: app)
        scrollTo(remove, in: app)
        remove.tap()
        let confirm = app.buttons["移除插件"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "移除前应当先弹出确认")
        confirm.tap()
        XCTAssertTrue(app.navigationBars["插件"].waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element(id: "plugins.row.github:example-owner/magpie-dash", in: app))
        waitForExpectations(timeout: 10)
        XCTAssertTrue(element(containing: "示例云登录", in: app).exists)
    }
}
