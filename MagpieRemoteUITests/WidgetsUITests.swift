import XCTest

/// 小组件相关的 App 行为：点小组件打开（深链）切到对应页面；「关于」里显示小组件状态。
/// 小组件本身（WidgetKit 扩展）UI 测试碰不到，只能在真机上看。深链用启动参数 `--ui-open-url` 模拟（fixture 模式）。
@MainActor
final class WidgetsUITests: XCTestCase {
    private var launchTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["MAGPIE_REMOTE_WARMUP_TIMEOUT"].flatMap { TimeInterval($0) } ?? 45
    }

    private func launch(openURL: String? = nil) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if let openURL { app.launchArguments += ["--ui-open-url", openURL] }
        app.launch()
        XCTAssertTrue(app.waitForDock(timeout: launchTimeout), "没有出现底栏「更多」")
        return app
    }

    func testQuotaWidgetLinkOpensHomeQuota() {
        let app = launch(openURL: "magpieremote://widget/quota")
        XCTAssertTrue(app.navigationBars["额度"].waitForExistence(timeout: 15), "点「额度」小组件后应当打开主页的额度分页")
        XCTAssertTrue(app.homeSegments.buttons["额度"].isSelected, "分页器应当选着额度")
    }

    func testUsageWidgetLinkOpensUsage() {
        let app = launch(openURL: "magpieremote://widget/usage")
        let total = app.descendants(matching: .any).matching(identifier: "usage.totalCost").firstMatch
        XCTAssertTrue(total.waitForExistence(timeout: 15), "点「今日用量」小组件后应当打开用量页（usage.totalCost）")
        XCTAssertTrue(app.tabBars.buttons["用量"].isSelected, "底栏应当选着「用量」")
    }

    func testAboutShowsWidgetStatus() {
        let app = launch()
        app.openFromMore("manage.about", title: "关于")
        let row = app.descendants(matching: .any).matching(identifier: "about.widgets").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "「关于」里没有小组件状态")
    }
}
