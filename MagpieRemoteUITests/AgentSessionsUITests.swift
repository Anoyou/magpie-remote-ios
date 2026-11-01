import XCTest

/// 底栏「会话」（Agent 会话记录）：fixture 模式下的示例会话（`FixtureAgentSessionsService`）。
@MainActor
final class AgentSessionsUITests: XCTestCase {
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
        var tries = 0
        while (!element.exists || !element.isHittable) && tries < attempts {
            app.swipeUp()
            tries += 1
        }
    }

    /// 打开底栏「会话」。
    private func openSessions() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.waitForDock(timeout: launchTimeout), "没有出现底栏「更多」")
        // 默认底栏第 2 个就是「会话」。
        app.openDockTab("会话", navigationTitle: "会话记录")
        return app
    }

    func testListShowsFixtureSessionsAndOpensTranscript() {
        let app = openSessions()
        let row = element(id: "session.row.fixture-claude-1", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "没有列出示例会话")
        XCTAssertTrue(element(containing: "修复登录页的样式问题", in: app).exists)
        XCTAssertTrue(element(containing: "写一个周报模板", in: app).exists)
        row.tap()
        XCTAssertTrue(element(containing: "示例回答", in: app).waitForExistence(timeout: 10), "详情页没有显示对话内容")
        XCTAssertTrue(element(containing: "claude-sonnet-4-5", in: app).exists, "概况里应当显示模型")
    }

    func testSwitchAgentShowsItsSessions() {
        let app = openSessions()
        XCTAssertTrue(element(id: "session.row.fixture-claude-1", in: app).waitForExistence(timeout: 10))
        let picker = element(id: "sessions.agent", in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        let codex = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Codex")).firstMatch
        XCTAssertTrue(codex.waitForExistence(timeout: 5), "Agent 菜单里没有 Codex")
        codex.tap()
        XCTAssertTrue(element(id: "session.row.fixture-codex-1", in: app).waitForExistence(timeout: 10), "切换后没有列出 Codex 的会话")
        XCTAssertFalse(element(id: "session.row.fixture-claude-1", in: app).exists)
    }

    func testDeleteSessionAsksForConfirmation() {
        let app = openSessions()
        let row = element(id: "session.row.fixture-claude-2", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let menu = element(id: "session.menu", in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let delete = element(id: "session.delete", in: app)
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirm = app.buttons["移到回收站"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "删除前应当先弹出确认")
        confirm.tap()
        // 删除后回到列表，这个会话不再出现，其它的还在
        XCTAssertTrue(app.navigationBars["会话记录"].waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element(id: "session.row.fixture-claude-2", in: app))
        waitForExpectations(timeout: 10)
        XCTAssertTrue(element(id: "session.row.fixture-claude-1", in: app).exists)
    }
}
