import XCTest

/// 「主页」：顶部分页器切换 Agent / 供应商 / 额度；Agent 里没设置的和隐藏的默认折叠（fixture：Codex 已接入，
/// Claude Code 没设置，Gemini CLI 在网页版里隐藏了）。
@MainActor
final class HomeUITests: XCTestCase {
    private var launchTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["MAGPIE_REMOTE_WARMUP_TIMEOUT"].flatMap { TimeInterval($0) } ?? 45
    }

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.waitForDock(timeout: launchTimeout), "没有出现底栏「更多」")
        return app
    }

    private func element(id identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func testSegmentsSwitchBetweenAgentsProvidersAndQuota() {
        let app = launch()
        app.openHome("Agent")
        XCTAssertTrue(app.agentHeader("codex").appears(timeout: 15), "Agent 分页没有显示已接入的 Codex")
        app.openHome("供应商")
        XCTAssertTrue(element(id: "provider.row.relay-example", in: app).appears(timeout: 10), "供应商分页没有显示示例供应商")
        app.openHome("额度")
        XCTAssertTrue(element(containing: "工作 Claude", in: app).appears(timeout: 15), "额度分页没有显示示例账号")
        // 切到别的标签再回来：还停在额度。
        app.tabBars.buttons["会话"].tap()
        app.tabBars.buttons["主页"].tap()
        XCTAssertTrue(app.navigationBars["额度"].appears(timeout: 10), "回到主页后应当还停在额度")
        XCTAssertTrue(app.homeSegments.buttons["额度"].isSelected, "分页器应当还选着额度")
    }

    func testAgentsNotSetUpAndHiddenStartFolded() {
        let app = launch()
        app.openHome("Agent")
        XCTAssertTrue(app.agentHeader("codex").appears(timeout: 15))
        let toggle = element(id: "agents.folded.toggle", in: app)
        XCTAssertTrue(toggle.appears(timeout: 10), "没有折叠组的展开按钮")
        XCTAssertTrue(toggle.label.contains("另外 2 个 Agent"), "折叠按钮应当显示数量：\(toggle.label)")
        XCTAssertEqual(toggle.value as? String, "已收起")
        XCTAssertFalse(app.agentHeader("claude").exists, "没设置的 Claude Code 默认应当折叠")
        XCTAssertFalse(app.agentHeader("gemini").exists, "隐藏的 Gemini CLI 默认应当折叠")

        toggle.tap()
        // Agent 页现在每个 Agent 行更多（版本、更新、更多操作），折叠组在屏幕底部：展开的行要往下滑才进无障碍树。
        let caption = element(containing: "未设置", in: app)
        app.swipeUp(until: caption, max: 3)
        XCTAssertTrue(caption.appears(timeout: 5), "展开后没有「未设置」小标题")
        let claude = app.agentHeader("claude")
        app.swipeUp(until: claude, max: 3)
        XCTAssertTrue(claude.appears(timeout: 5), "展开后没有显示 Claude Code")
        let gemini = app.agentHeader("gemini")
        for _ in 0..<4 {
            if gemini.exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(gemini.appears(timeout: 5), "展开后没有显示隐藏的 Gemini CLI")
        XCTAssertTrue(element(containing: "已隐藏", in: app).exists, "展开后没有「已隐藏」小标题")
    }

    /// 每个 Agent 的设置默认收起，只有标题行；点标题行展开，再点收起。
    func testAgentSettingsStartCollapsed() {
        let app = launch()
        app.openHome("Agent")
        let header = app.agentHeader("codex")
        XCTAssertTrue(header.appears(timeout: 15), "Agent 分页没有 Codex 的标题行")
        XCTAssertEqual(header.value as? String, "已收起", "Codex 的设置默认应当收起")
        let model = element(id: "agent.model.codex", in: app)
        XCTAssertFalse(model.exists, "收起时不应显示 Codex 的模型设置")
        XCTAssertFalse(element(id: "agent.connect.codex", in: app).exists, "收起时不应显示「接入 magpie」开关")

        header.tap()
        XCTAssertTrue(waitUntil(5) { (header.value as? String) == "已展开" }, "点标题行后应当展开")
        XCTAssertTrue(model.appears(timeout: 5), "展开后应当显示 Codex 的模型设置")

        header.tap()
        XCTAssertTrue(waitUntil(5) { (header.value as? String) == "已收起" }, "再点一次应当收起")
        XCTAssertTrue(model.disappears(timeout: 5), "收起后模型设置应当不见")
    }
}
