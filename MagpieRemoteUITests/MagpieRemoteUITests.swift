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

    /// 按 identifier 查找，不限元素类型（SwiftUI 可能把按钮暴露成其它类型）。
    private func element(id identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
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
        XCTAssertTrue(element(containing: "还没有添加主机", in: app).waitForExistence(timeout: 10), "空状态没有出现「还没有添加主机」")
        let guide = element(id: "guide.open", in: app)
        XCTAssertTrue(guide.waitForExistence(timeout: 10), "空状态里没有「配置引导」按钮（guide.open）")
        guide.tap()
        XCTAssertTrue(app.navigationBars["配置引导"].waitForExistence(timeout: 10), "没有打开「配置引导」页")
        XCTAssertTrue(element(containing: "在局域网共享", in: app).waitForExistence(timeout: 5), "配置引导里缺少「在局域网共享」步骤")
        XCTAssertTrue(element(containing: "magpie daemon web on --lan", in: app).waitForExistence(timeout: 5), "配置引导里缺少 magpie daemon web on --lan 命令")
    }

    func testOfflineHostShowsChineseError() {
        let app = launch(["--fixture-offline"])
        XCTAssertTrue(element(containing: "连不上主机", in: app).waitForExistence(timeout: 15), "没有出现中文错误标题「连不上主机」")
        XCTAssertTrue(element(containing: "主机都没有回应", in: app).waitForExistence(timeout: 5), "没有出现超时的中文说明")
        XCTAssertTrue(element(id: "state.retry", in: app).waitForExistence(timeout: 5), "错误页里没有「重试」按钮（state.retry）")
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
