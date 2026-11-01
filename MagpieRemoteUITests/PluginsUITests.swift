import XCTest

/// 「更多 › 插件」：fixture 模式下的示例插件（`FixturePluginService`）。页面照 magpie 网页分「内置 / 发现 / 已安装」三页。
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

    /// 打开「更多 › 插件」。
    private func launchPlugins() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.waitForDock(timeout: launchTimeout), "没有出现底栏「更多」")
        app.openFromMore("manage.plugins", title: "插件")
        return app
    }

    /// 顶部分页（「已安装」带数量，按开头匹配）。
    private func selectTab(_ title: String, in app: XCUIApplication) {
        let segment = app.segmentedControls.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(segment.waitForExistence(timeout: 10), "没有分页「\(title)」")
        segment.tap()
    }

    func testListShowsInstalledAndBuiltinPlugins() {
        let app = launchPlugins()
        selectTab("已安装", in: app)
        XCTAssertTrue(element(id: "plugins.row.@magpie-community/example-auth", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "示例云", in: app).exists, "市场里的名字优先")
        XCTAssertTrue(element(containing: "示例仪表盘", in: app).exists)
        XCTAssertTrue(element(containing: "v1.3.0 可用", in: app).exists, "有新版本的插件标出可更新的版本")
        XCTAssertTrue(element(id: "plugins.updateAll", in: app).exists, "有新版本时顶部提供「全部更新」")

        selectTab("内置", in: app)
        let builtin = element(id: "plugins.builtin.sessions", in: app)
        XCTAssertTrue(builtin.waitForExistence(timeout: 10), "应列出内置插件")
        XCTAssertTrue(element(containing: "会话", in: app).exists, "内置插件应显示中文名称")
        let setting = element(id: "builtin.setting.sample", in: app)
        scrollTo(setting, in: app)
        XCTAssertTrue(setting.exists, "开着的内置插件直接显示设置")
    }

    func testDiscoverShowsCommunitySectionsGitHubAndSearch() {
        let app = launchPlugins()
        selectTab("发现", in: app)
        XCTAssertTrue(element(id: "plugins.intro", in: app).waitForExistence(timeout: 10), "发现页顶部是介绍")
        XCTAssertTrue(element(id: "plugins.card.@magpie-community/example-auth", in: app).waitForExistence(timeout: 10), "社区插件按种类分区")
        let guardCard = element(id: "plugins.card.@magpie-community/example-guard", in: app)
        scrollTo(guardCard, in: app)
        XCTAssertTrue(guardCard.exists, "网关中间件单独一区")
        let github = element(id: "plugins.card.github:example-owner/relay-auth", in: app)
        scrollTo(github, in: app)
        XCTAssertTrue(github.exists, "应列出 GitHub 上的非官方插件")

        // 打开卡片：详情里有 README
        github.tap()
        XCTAssertTrue(element(containing: "这是示例插件的说明", in: app).waitForExistence(timeout: 10), "详情应显示 README")
        app.buttons["关闭"].firstMatch.tap()

        // 搜索：推荐里匹配的，加上 npm 的结果
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("example")
        let hit = element(id: "plugins.card.opencode-example-auth", in: app)
        _ = hit.waitForExistence(timeout: 5)
        scrollTo(hit, in: app, attempts: 12)
        XCTAssertTrue(hit.exists, "应显示 npm 上的搜索结果")
    }

    func testAddPluginFromSpecAsksForConfirmation() {
        let app = launchPlugins()
        selectTab("已安装", in: app)
        element(id: "plugins.add", in: app).tap()
        let field = app.textFields["plugin.add.spec"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("example-new-plugin")
        element(id: "plugin.add.submit", in: app).tap()
        let confirm = app.buttons["安装"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "安装前应当先弹出确认")
        confirm.tap()
        // 安装后表单关闭，转到「已安装」，新插件出现在列表里
        XCTAssertTrue(app.navigationBars["插件"].waitForExistence(timeout: 10))
        XCTAssertTrue(element(id: "plugins.row.example-new-plugin", in: app).waitForExistence(timeout: 10), "新插件应出现在列表里")
    }

    func testRemovePluginAsksForConfirmationAndTogglesWork() {
        let app = launchPlugins()
        selectTab("已安装", in: app)
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
        let confirm = app.buttons["移除"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "移除前应当先弹出确认")
        confirm.tap()
        XCTAssertTrue(app.navigationBars["插件"].waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element(id: "plugins.row.github:example-owner/magpie-dash", in: app))
        waitForExpectations(timeout: 10)
        XCTAssertTrue(element(id: "plugins.row.@magpie-community/example-auth", in: app).exists)
    }
}
