import XCTest

/// 「额度」页（fixture 模式，示例账号见 QuotaSamples）。
@MainActor
final class QuotaUITests: XCTestCase {
    private var launchTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["MAGPIE_REMOTE_WARMUP_TIMEOUT"].flatMap { TimeInterval($0) } ?? 45
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + extra
        app.launch()
        XCTAssertTrue(app.waitForDock(timeout: launchTimeout), "首屏没有出现底栏「更多」")
        // 额度在「主页」分页器里。
        app.openHome("额度")
        return app
    }

    private func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// 向上滑动直到元素出现在屏幕上（SwiftUI ScrollView 不会自动滚到屏幕外的元素）。
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        app.swipeUp(until: element, max: 8)
        XCTAssertTrue(element.appears(timeout: 5) && element.isHittable, "滚动后仍看不到元素：\(element)", file: file, line: line)
    }

    /// 账号的折叠行（按钮），按账号名找。
    private func header(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: "quota.account.header")
            .matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    /// 展开后才会出现的卡片明细。
    private func cards(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "quota.card")
    }

    func testAccountsStartCollapsedWithSummary() {
        let app = launch()
        let work = header("工作 Claude", in: app)
        XCTAssertTrue(work.appears(timeout: 15), "没有出现示例账号「工作 Claude」的折叠行")
        XCTAssertTrue(element(containing: "最低剩余 38.5%", in: app).exists, "折叠行没有显示最低剩余百分比")
        XCTAssertTrue(element(containing: "后重置", in: app).exists, "折叠行没有显示最近的重置时间")
        XCTAssertTrue(element(containing: "Claude · 2 个账号", in: app).exists, "同一供应商的多个账号没有分组")
        XCTAssertEqual(cards(app).count, 0, "启动时账号应该默认折叠")
        XCTAssertEqual(work.value as? String, "已收起")
        let balance = element(containing: "余额 ¥ 23.71", in: app)
        if !balance.exists { app.swipeUp() }
        XCTAssertTrue(balance.appears(timeout: 5), "余额账号的折叠行没有显示余额文字")
    }

    func testTapExpandsAndCollapsesAccount() {
        let app = launch()
        let work = header("工作 Claude", in: app)
        XCTAssertTrue(work.appears(timeout: 15))
        work.tap()
        XCTAssertTrue(cards(app).firstMatch.appears(timeout: 5), "点按后没有展开账号明细")
        XCTAssertTrue(element(containing: "剩余 63%", in: app).exists, "展开后 5 小时窗口的剩余百分比没有显示")
        XCTAssertTrue(app.buttons["quota.account.refresh"].firstMatch.exists, "展开后没有「重新读取」按钮")
        XCTAssertEqual(work.value as? String, "已展开")
        XCTAssertEqual(cards(app).count, 1, "只应展开点按的那个账号")
        // 折叠行的点按 / 无障碍区域只应是标题这一行，不能被撑成整张卡片（否则点中心会落在明细里）。
        XCTAssertLessThan(work.frame.height, 160, "展开后折叠行的区域覆盖了整张卡片：\(work.frame)")
        work.tap()
        XCTAssertTrue(waitUntil(5) { (work.value as? String) == "已收起" }, "再次点按后折叠行没有变成「已收起」")
        XCTAssertTrue(cards(app).firstMatch.disappears(timeout: 5), "再次点按后没有收起账号明细")
    }

    func testExpandedStateKeptAcrossTabs() {
        let app = launch()
        let work = header("工作 Claude", in: app)
        XCTAssertTrue(work.appears(timeout: 15))
        work.tap()
        XCTAssertTrue(cards(app).firstMatch.appears(timeout: 5))
        // 切到底栏「路由」，再回「主页」：分页器应当还停在额度（不在就重新切过去）。
        app.tabBars.buttons["路由"].tap()
        app.tabBars.buttons["主页"].tap()
        if !header("工作 Claude", in: app).appears(timeout: 5) {
            app.openHome("额度")
        }
        XCTAssertTrue(header("工作 Claude", in: app).appears(timeout: 10))
        XCTAssertTrue(cards(app).firstMatch.appears(timeout: 5), "切换标签后展开状态没有保留")
    }

    func testHistoryPickerSwitches() {
        let app = launch()
        let work = header("工作 Claude", in: app)
        XCTAssertTrue(work.appears(timeout: 15))
        work.tap()
        XCTAssertTrue(cards(app).firstMatch.appears(timeout: 5), "点按后没有展开账号明细")
        let caption = app.staticTexts["quota.history.caption"].firstMatch
        let month = app.buttons["30 天"].firstMatch
        scrollTo(month, in: app)
        XCTAssertEqual(caption.label, "近 7 天")
        month.tap()
        XCTAssertTrue(element(containing: "近 30 天", in: app).appears(timeout: 5), "切换到 30 天后标题没有变化")
        app.buttons["45 天"].firstMatch.tap()
        XCTAssertTrue(element(containing: "近 45 天", in: app).appears(timeout: 5), "切换到 45 天后标题没有变化")
        XCTAssertTrue(app.descendants(matching: .any)["quota.history.chart"].firstMatch.exists, "没有画出历史曲线")
    }

    func testEmptyStateWhenNoSubscriptionAccounts() {
        let app = launch(["--fixture-quota-empty"])
        XCTAssertTrue(element(containing: "还没有订阅账号", in: app).appears(timeout: 15), "没有订阅账号时没有显示空状态")
    }

    func testHeldKeyShowsOwnLimit() {
        let app = launch(["--fixture-key-held"])
        XCTAssertTrue(element(containing: "这把密钥的限额", in: app).appears(timeout: 15), "受限密钥没有显示自己的限额卡片")
        XCTAssertTrue(element(containing: "每 1 小时", in: app).exists, "限额周期没有显示")
        XCTAssertFalse(element(containing: "主机返回错误", in: app).exists, "受限密钥不应显示错误")
    }
}
