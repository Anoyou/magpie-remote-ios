import XCTest

/// 「主页 › Agent」对齐官方网页的部分（fixture：Codex、Claude Code 的命令行程序有新版本，Codex 已接入，有一个方案「工作」）。
@MainActor
final class AgentsParityUITests: XCTestCase {
    private var launchTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["MAGPIE_REMOTE_WARMUP_TIMEOUT"].flatMap { TimeInterval($0) } ?? 45
    }

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.waitForDock(timeout: launchTimeout), "没有出现底栏「更多」")
        app.openHome("Agent")
        return app
    }

    private func element(id identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// 有新版本的 Agent 显示「更新到 …」，点了之后更新完成，按钮消失。
    func testUpdateAgentCLI() {
        let app = launch()
        let update = element(id: "agent.update.codex", in: app)
        XCTAssertTrue(update.waitForExistence(timeout: 15), "Codex 有新版本，应当有「更新到」按钮")
        XCTAssertTrue(update.label.contains("更新到 0.164.2"), "按钮文字不对：\(update.label)")
        update.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: update)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(element(id: "agents.status", in: app).waitForExistence(timeout: 5), "更新完应当提示「Codex 已更新…」")
    }

    /// 两个以上有新版本时上面有「全部更新」。
    func testUpdateAllBar() {
        let app = launch()
        let all = element(id: "agents.updateAll", in: app)
        XCTAssertTrue(all.waitForExistence(timeout: 15), "两个 Agent 有新版本，应当有「全部更新」")
        all.tap()
        let say = element(id: "agents.updates.say", in: app)
        XCTAssertTrue(say.waitForExistence(timeout: 5))
        let done = NSPredicate(format: "label CONTAINS %@", "已更新 2 个 Agent")
        expectation(for: done, evaluatedWith: say)
        waitForExpectations(timeout: 15)
    }

    /// 「接入 magpie」开关：关掉要先确认，确认后变成未接入。
    func testDisconnectAsksFirst() {
        let app = launch()
        let toggle = element(id: "agent.connect.codex", in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), "Codex 应当有「接入 magpie」开关")
        // 点开关本身（行的右侧），不是左边的文字
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let confirm = element(id: "agent.disconnect.confirm", in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "关掉开关应当先问「断开 Codex 和 magpie？」")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["未接入"].waitForExistence(timeout: 10), "断开后 Codex 应当显示未接入")
    }

    /// 方案：有示例方案「工作」，可以打开看它存了什么。
    func testProfilesSection() {
        let app = launch()
        let profile = element(id: "agents.profile.工作", in: app)
        for _ in 0..<6 where !profile.exists { app.swipeUp() }
        XCTAssertTrue(profile.waitForExistence(timeout: 10), "Agent 页最下面应当有「方案」")
        profile.tap()
        XCTAssertTrue(element(id: "agents.profile.apply", in: app).waitForExistence(timeout: 5), "方案详情应当有「应用」")
        XCTAssertTrue(element(id: "agents.profile.delete", in: app).exists)
    }
}
