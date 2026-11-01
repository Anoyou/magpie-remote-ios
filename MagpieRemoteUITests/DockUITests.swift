import XCTest

/// 「更多 › 自定义底栏」：换页面、底栏与「更多」同步变化、恢复默认（示例模式不保存设置，每次启动都是默认底栏）。
@MainActor
final class DockUITests: XCTestCase {
    private var launchTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["MAGPIE_REMOTE_WARMUP_TIMEOUT"].flatMap { TimeInterval($0) } ?? 45
    }

    private func element(id identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 6) {
        for _ in 0..<attempts where !(element.exists && element.isHittable) { app.swipeUp() }
    }

    private func launchCustomize() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.waitForDock(timeout: launchTimeout), "没有出现底栏「更多」")
        app.openFromMore("more.customize", title: "自定义底栏")
        return app
    }

    /// 把「额度」放到第 1 个位置：底栏换成额度、Agent 回到「更多」；恢复默认后回到 Agent、会话、供应商、路由。
    func testCustomizeDockAndRestoreDefault() {
        let app = launchCustomize()
        let first = element(id: "dock.slot.0", in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 10), "没有显示底栏第 1 个位置")
        XCTAssertTrue(first.label.contains("Agent"), "默认第 1 个应当是 Agent：\(first.label)")
        XCTAssertTrue(element(id: "dock.slot.more", in: app).exists, "第 5 个位置应当固定为「更多」")
        XCTAssertFalse(element(id: "dock.reset", in: app).isEnabled, "默认底栏时「恢复默认」应当不可点")

        let quota = element(id: "dock.candidate.quota", in: app)
        XCTAssertTrue(quota.waitForExistence(timeout: 10), "「在『更多』里」没有列出额度")
        scrollTo(quota, in: app)
        quota.tap()
        let place = element(id: "dock.place.0", in: app)
        XCTAssertTrue(place.waitForExistence(timeout: 5), "没有出现「放进底栏」的位置选项")
        place.tap()

        XCTAssertTrue(app.tabBars.buttons["额度"].waitForExistence(timeout: 10), "底栏没有出现「额度」")
        XCTAssertFalse(app.tabBars.buttons["Agent"].exists, "被换下的 Agent 不应还在底栏")
        XCTAssertTrue(app.tabBars.buttons["更多"].exists, "「更多」应当一直在底栏")
        XCTAssertTrue(element(id: "dock.slot.0", in: app).label.contains("额度"))
        XCTAssertTrue(element(id: "dock.candidate.agents", in: app).waitForExistence(timeout: 5), "被换下的 Agent 应当回到「更多」")
        XCTAssertFalse(element(id: "dock.candidate.quota", in: app).exists, "放进底栏的额度不应还在「更多」里")

        let reset = element(id: "dock.reset", in: app)
        scrollTo(reset, in: app)
        XCTAssertTrue(reset.isEnabled, "自定义后「恢复默认」应当可点")
        reset.tap()
        XCTAssertTrue(app.tabBars.buttons["Agent"].waitForExistence(timeout: 10), "恢复默认后底栏没有回到 Agent")
        for title in ["会话", "供应商", "路由", "更多"] {
            XCTAssertTrue(app.tabBars.buttons[title].exists, "恢复默认后缺少「\(title)」")
        }
        XCTAssertFalse(app.tabBars.buttons["额度"].exists, "恢复默认后「额度」应当回到「更多」")
    }

    /// 放进底栏的页面直接从底栏打开，「更多」列表里不再出现它，换下来的页面出现在「更多」里。
    func testDockedPageOpensFromTabAndLeavesMore() {
        let app = launchCustomize()
        // 用第 4 个位置（路由）的菜单换成「用量」。
        let menu = element(id: "dock.slot.3.menu", in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "底栏第 4 个位置没有更换按钮")
        menu.tap()
        let usage = element(id: "dock.slot.3.use.usage", in: app)
        XCTAssertTrue(usage.waitForExistence(timeout: 5), "更换菜单里没有「用量」")
        usage.tap()
        XCTAssertTrue(app.tabBars.buttons["用量"].waitForExistence(timeout: 10), "底栏没有出现「用量」")
        XCTAssertFalse(app.tabBars.buttons["路由"].exists, "被换下的「路由」不应还在底栏")

        app.openDockTab("用量")
        XCTAssertTrue(element(id: "usage.totalCost", in: app).waitForExistence(timeout: 15), "从底栏打开的用量页没有内容")

        // 回到「更多」根列表：用量不在了，路由回来了。
        app.tabBars.buttons["更多"].tap()
        let back = app.navigationBars["自定义底栏"].buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 5) { back.tap() }
        XCTAssertTrue(app.navigationBars["更多"].waitForExistence(timeout: 10), "没有回到「更多」")
        let routes = element(id: "manage.groups", in: app)
        _ = routes.waitForExistence(timeout: 5)
        scrollTo(routes, in: app)
        XCTAssertTrue(routes.exists, "换下来的「路由」应当出现在「更多」里")
        XCTAssertFalse(element(id: "more.usage", in: app).exists, "放进底栏的「用量」不应还在「更多」里")
    }
}
