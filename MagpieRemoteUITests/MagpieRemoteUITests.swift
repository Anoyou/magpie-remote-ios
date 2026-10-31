import XCTest

/// 全部在 fixture 模式下运行（`--ui-testing`），不需要真实主机。
@MainActor
final class MagpieRemoteUITests: XCTestCase {
    /// 首屏等待时间：CI 预热时用 `MAGPIE_REMOTE_WARMUP_TIMEOUT` 放宽（新启动的模拟器第一次冷启动很慢）。
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

    /// 不依赖元素类型：SwiftUI 合并后的无障碍元素可能是按钮或其它类型，只按文字查找。
    private func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func testFourTabsExist() {
        let app = launch()
        for title in ["额度", "用量", "对话", "管理"] {
            XCTAssertTrue(app.tabBars.buttons[title].exists, "缺少标签：\(title)")
        }
        app.tabBars.buttons["管理"].tap()
        XCTAssertTrue(app.navigationBars["管理"].waitForExistence(timeout: 10))
    }

    func testFixtureHostConnectsAndShowsQuota() {
        let app = launch()
        XCTAssertTrue(element(containing: "示例供应商 A", in: app).waitForExistence(timeout: 15))
    }

    func testHostSheetOpensAndAddForm() {
        let app = launch()
        let open = app.buttons["hosts.open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        XCTAssertTrue(app.navigationBars["主机"].waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "示例 Mac", in: app).exists)
        app.buttons["hosts.add"].tap()
        XCTAssertTrue(app.navigationBars["添加主机"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["host.address"].exists)
        XCTAssertTrue(app.secureTextFields["host.secret.gateway-key"].exists)
        // 地址为空时不能保存
        XCTAssertFalse(app.buttons["host.save"].isEnabled)
    }

    func testSetupGuideOpensFromEmptyState() {
        let app = launch(["--fixture-empty"])
        XCTAssertTrue(app.descendants(matching: .any)["state.noHost"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["guide.open"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["配置引导"].waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "开启「在局域网共享」", in: app).exists)
        XCTAssertTrue(element(containing: "magpie daemon web on --lan", in: app).exists)
    }

    func testOfflineHostShowsChineseError() {
        let app = launch(["--fixture-offline"])
        XCTAssertTrue(element(containing: "连不上主机", in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["state.retry"].exists)
    }

    func testAboutShowsVersionAndChangelog() {
        let app = launch()
        app.tabBars.buttons["管理"].tap()
        let about = app.buttons["manage.about"].firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 10))
        about.tap()
        XCTAssertTrue(app.navigationBars["关于"].waitForExistence(timeout: 10))
        app.buttons["about.changelog"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["更新日志"].waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "0.1.0", in: app).waitForExistence(timeout: 5))
    }
}
