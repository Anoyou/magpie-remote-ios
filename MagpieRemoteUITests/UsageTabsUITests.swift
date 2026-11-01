import XCTest

/// 「用量」的四个标签：概览、请求、会话、上下文（fixture：UsageFixtureData + UsageTabsFixtureData）。
@MainActor
final class UsageTabsUITests: XCTestCase {
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
        app.swipeUp(until: element, max: attempts)
    }

    private func openUsage() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.waitForDock(timeout: launchTimeout), "没有出现底栏「更多」")
        app.openDockTab("用量")
        XCTAssertTrue(element(id: "usage.totalCost", in: app).appears(timeout: 15), "概览没有出现总花费")
        return app
    }

    private func tab(_ title: String, in app: XCUIApplication) {
        let control = element(id: "usage.tab", in: app)
        XCTAssertTrue(control.appears(timeout: 10), "没有「概览 | 请求 | 会话 | 上下文」分段")
        let segment = control.buttons[title].firstMatch
        XCTAssertTrue(segment.appears(timeout: 5), "分段里没有「\(title)」")
        segment.tap()
    }

    func testTabsShowRequestsSessionsAndContext() {
        let app = openUsage()

        tab("请求", in: app)
        XCTAssertTrue(element(id: "usage.requests.period", in: app).appears(timeout: 10), "请求标签没有时间段")
        XCTAssertTrue(element(id: "usage.requests.total", in: app).appears(timeout: 10) || element(id: "usage.request.0", in: app).exists
                      || element(containing: "这段时间没有请求", in: app).exists, "请求标签没有内容")

        tab("会话", in: app)
        let stats = element(id: "usage.sessions.stats", in: app)
        XCTAssertTrue(stats.appears(timeout: 15), "会话标签没有合计")
        XCTAssertTrue(element(id: "usage.sessions.range", in: app).exists)
        let first = element(id: "usage.sessions.item.0", in: app)
        scrollTo(first, in: app)
        XCTAssertTrue(first.appears(timeout: 5), "会话标签没有列出最近的会话")

        tab("上下文", in: app)
        XCTAssertTrue(element(id: "usage.context.range", in: app).appears(timeout: 10), "上下文标签没有范围")
        let claude = element(id: "usage.context.agent.claude", in: app)
        XCTAssertTrue(claude.appears(timeout: 15), "上下文标签没有 Claude Code 的评分卡")
        let session = element(id: "usage.context.session.0", in: app)
        scrollTo(session, in: app)
        XCTAssertTrue(session.appears(timeout: 5), "上下文标签没有会话")
        session.tap()
        XCTAssertTrue(element(id: "usage.context.card", in: app).appears(timeout: 5), "点开会话没有显示最近一次请求的上下文")

        tab("概览", in: app)
        XCTAssertTrue(element(id: "usage.totalCost", in: app).appears(timeout: 10), "回到概览没有总花费")
    }

    func testRequestDetailReadsContent() {
        let app = openUsage()
        tab("请求", in: app)
        // 「今天」刚过零点时可能还没有示例请求，固定看 30 天。
        let period = element(id: "usage.requests.period", in: app)
        XCTAssertTrue(period.appears(timeout: 10))
        period.buttons["30 天"].firstMatch.tap()
        XCTAssertTrue(element(id: "usage.requests.total", in: app).appears(timeout: 10), "请求记录没有显示总条数")
        let agent = element(id: "usage.filter.agent", in: app)
        XCTAssertTrue(agent.appears(timeout: 10))
        agent.tap()
        let claude = app.menuItem(id: "Claude Code", label: "Claude Code")
        XCTAssertTrue(claude.appears(timeout: 5), "Agent 菜单里没有 Claude Code")
        claude.tap()
        let row = element(id: "usage.request.0", in: app)
        scrollTo(row, in: app)
        XCTAssertTrue(row.appears(timeout: 10), "筛选后没有请求")
        row.tap()
        XCTAssertTrue(app.navigationBars["请求详情"].appears(timeout: 10))
        let content = element(containing: "示例回答", in: app)
        scrollTo(content, in: app)
        XCTAssertTrue(content.appears(timeout: 10), "请求详情没有读出说了什么")
    }
}
