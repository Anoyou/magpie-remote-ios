import XCTest

/// 官方图标：底栏用 magpie 网页导航的线条图，供应商行前有官方标志；图标只是装饰，不能被读出资源名。
@MainActor
final class OfficialIconsUITests: XCTestCase {
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

    private func assertNoAssetName(_ label: String, _ what: String) {
        for leak in ["Brand/", "Nav/", "nav-", "-color"] {
            XCTAssertFalse(label.contains(leak), "\(what)的朗读文字里带了图标资源名：\(label)")
        }
    }

    /// 底栏换成官方图标后，标签仍按页面名称找得到，朗读文字里没有图标资源名。
    func testDockTabsKeepTheirTitles() {
        let app = launch()
        for title in ["主页", "会话", "路由", "用量", "更多"] {
            let tab = app.tabBars.buttons[title]
            XCTAssertTrue(tab.waitForExistence(timeout: 10), "底栏里没有「\(title)」")
            assertNoAssetName(tab.label, "底栏「\(title)」")
        }
    }

    /// 供应商行前加了官方标志：行仍能点开，朗读的是供应商名字而不是图标名。
    func testProviderRowsShowNameNotIconAsset() {
        let app = launch()
        app.openHome("供应商")
        let row = app.descendants(matching: .any).matching(identifier: "provider.row.deepseek").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "没有示例供应商「示例 DeepSeek」")
        XCTAssertTrue(row.label.contains("示例 DeepSeek"), "供应商行应当读出名字：\(row.label)")
        assertNoAssetName(row.label, "供应商行")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "provider.name").firstMatch.waitForExistence(timeout: 10),
                      "点供应商行没有打开详情")
    }
}
