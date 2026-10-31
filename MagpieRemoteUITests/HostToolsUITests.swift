import XCTest

/// 「管理 › 主机工具」：fixture 模式下的主机更新、自动调优、隐私模型（`FixtureHostToolsService`）。
@MainActor
final class HostToolsUITests: XCTestCase {
    private var launchTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["MAGPIE_REMOTE_WARMUP_TIMEOUT"].flatMap { TimeInterval($0) } ?? 45
    }

    private func launch(open identifier: String, title: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let tab = app.tabBars.buttons["管理"]
        XCTAssertTrue(tab.waitForExistence(timeout: launchTimeout), "没有出现「管理」标签")
        tab.tap()
        XCTAssertTrue(app.navigationBars["管理"].waitForExistence(timeout: 10))
        let link = element(id: identifier, in: app)
        XCTAssertTrue(link.waitForExistence(timeout: 15), "没有出现入口 \(identifier)")
        scrollTo(link, in: app)
        link.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), "没有打开「\(title)」")
        return app
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

    /// 发现新版本：显示版本、未验证提示、中文说明；下载需要确认，下载完变成「重启并安装」，重启后回到最新版。
    func testHostUpdateDownloadAndRestart() {
        let app = launch(open: "manage.update", title: "主机更新")
        XCTAssertTrue(element(containing: "v0.1.2450", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element(id: "update.compat", in: app).exists, "比已验证版本新时应提示")
        XCTAssertTrue(element(containing: "用量页可以按密钥筛选", in: app).waitForExistence(timeout: 10), "应显示中文更新说明")

        let action = app.buttons["update.action"]
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        action.tap()
        let confirm = app.buttons["update.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "下载前应先确认")
        confirm.tap()

        let restart = app.buttons["重启并安装"]
        XCTAssertTrue(restart.waitForExistence(timeout: 15), "下载完应出现「重启并安装」")
        restart.tap()
        let confirmRestart = app.buttons["update.confirm"].firstMatch
        XCTAssertTrue(confirmRestart.waitForExistence(timeout: 5), "重启前应先确认")
        confirmRestart.tap()

        XCTAssertTrue(element(id: "update.done", in: app).waitForExistence(timeout: 20), "主机回来后应显示已更新")
        XCTAssertTrue(element(containing: "已更新到 v0.1.2450", in: app).exists)
    }

    /// 调优：显示建议与说明；全部应用需要确认，之后显示「已在使用」并可撤销。
    func testTuneApplyAllThenUndo() {
        let app = launch(open: "manage.tune", title: "自动调优")
        XCTAssertTrue(element(id: "tune.advice.claude.compact", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "少用", in: app).exists)

        let all = app.buttons["tune.applyAll"]
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        all.tap()
        let confirm = app.buttons["tune.confirmAll"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "全部应用前应先确认")
        confirm.tap()

        let ok = app.alerts.buttons["好"]
        XCTAssertTrue(ok.waitForExistence(timeout: 10))
        ok.tap()
        let undo = app.buttons["tune.undo.claude.compact"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "magpie 写入的设置应可撤销")
        XCTAssertFalse(app.buttons["tune.apply.claude.compact"].exists, "应用后不应再提示应用")
        undo.tap()
        let ok2 = app.alerts.buttons["好"]
        XCTAssertTrue(ok2.waitForExistence(timeout: 10))
        ok2.tap()
        XCTAssertTrue(app.buttons["tune.apply.claude.compact"].waitForExistence(timeout: 10), "撤销后应能再次应用")
    }

    /// 隐私模型：打开前确认下载，下载完显示运行状态；换模型需要确认。
    func testPrivacyModelTurnOnAndPick() {
        let app = launch(open: "manage.privacyModel", title: "隐私模型")
        let toggle = app.switches["privacy.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let summary = element(id: "privacy.summary", in: app)
        XCTAssertTrue(summary.label.contains("已关闭"), summary.label)
        if toggle.switches.firstMatch.exists { toggle.switches.firstMatch.tap() } else { toggle.tap() }
        let confirmOn = app.buttons["privacy.confirmOn"].firstMatch
        XCTAssertTrue(confirmOn.waitForExistence(timeout: 5), "打开前应提示要下载")
        confirmOn.tap()
        wait(summary, contains: "已打开")

        let other = element(id: "privacy.model.privacy-filter", in: app)
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        other.tap()
        let confirmPick = app.buttons["privacy.confirmPick"].firstMatch
        XCTAssertTrue(confirmPick.waitForExistence(timeout: 5), "换模型前应先确认")
        confirmPick.tap()
        wait(summary, contains: "Privacy Filter")
    }

    private func wait(_ element: XCUIElement, contains text: String, timeout: TimeInterval = 15) {
        expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }
    }
}
