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
        XCTAssertTrue(app.tabBars.buttons["额度"].waitForExistence(timeout: launchTimeout), "首屏没有出现「额度」标签")
        return app
    }

    private func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// 向上滑动直到元素出现在屏幕上（SwiftUI ScrollView 不会自动滚到屏幕外的元素）。
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5) && element.isHittable, "滚动后仍看不到元素：\(element)", file: file, line: line)
    }

    func testQuotaCardsRender() {
        let app = launch()
        XCTAssertTrue(element(containing: "工作 Claude", in: app).waitForExistence(timeout: 15), "没有出现示例订阅卡片「工作 Claude」")
        XCTAssertTrue(element(containing: "剩余 63%", in: app).exists, "5 小时窗口的剩余百分比没有显示")
        XCTAssertTrue(element(containing: "后重置", in: app).exists, "没有显示重置时间")
        XCTAssertTrue(element(containing: "Claude · 2 个账号", in: app).exists, "同一供应商的多个账号没有分组")
        XCTAssertTrue(element(containing: "¥ 23.71", in: app).waitForExistence(timeout: 5) || {
            app.swipeUp()
            return element(containing: "¥ 23.71", in: app).waitForExistence(timeout: 5)
        }(), "余额卡片没有显示余额文字")
    }

    func testHistoryPickerSwitches() {
        let app = launch()
        XCTAssertTrue(element(containing: "工作 Claude", in: app).waitForExistence(timeout: 15))
        let caption = app.staticTexts["quota.history.caption"].firstMatch
        let month = app.buttons["30 天"].firstMatch
        scrollTo(month, in: app)
        XCTAssertEqual(caption.label, "近 7 天")
        month.tap()
        XCTAssertTrue(element(containing: "近 30 天", in: app).waitForExistence(timeout: 5), "切换到 30 天后标题没有变化")
        app.buttons["45 天"].firstMatch.tap()
        XCTAssertTrue(element(containing: "近 45 天", in: app).waitForExistence(timeout: 5), "切换到 45 天后标题没有变化")
        XCTAssertTrue(app.descendants(matching: .any)["quota.history.chart"].firstMatch.exists, "没有画出历史曲线")
    }

    func testEmptyStateWhenNoSubscriptionAccounts() {
        let app = launch(["--fixture-quota-empty"])
        XCTAssertTrue(element(containing: "还没有订阅账号", in: app).waitForExistence(timeout: 15), "没有订阅账号时没有显示空状态")
    }

    func testHeldKeyShowsOwnLimit() {
        let app = launch(["--fixture-key-held"])
        XCTAssertTrue(element(containing: "这把密钥的限额", in: app).waitForExistence(timeout: 15), "受限密钥没有显示自己的限额卡片")
        XCTAssertTrue(element(containing: "每 1 小时", in: app).exists, "限额周期没有显示")
        XCTAssertFalse(element(containing: "主机返回错误", in: app).exists, "受限密钥不应显示错误")
    }
}
