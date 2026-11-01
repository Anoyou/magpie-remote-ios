import XCTest

/// 第二轮对齐官方网页（fixture）：Agent 隐藏与模型列表、网关密钥限额、已停用的模型、供应商「测试模型」。
@MainActor
final class ParityGaps2UITests: XCTestCase {
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

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 8) {
        var tries = 0
        while (!element.exists || !element.isHittable) && tries < attempts {
            app.swipeUp()
            tries += 1
        }
    }

    private func waitForStatus(_ text: String, in app: XCUIApplication, timeout: TimeInterval = 10) {
        // 状态栏只停 4 秒：每 0.25 秒查一次（waitForExistence 每秒才查一次，赶上弹窗收起的动画就可能错过）。
        let status = element(id: "agents.status", in: app)
        XCTAssertTrue(status.hasLabel(containing: text, within: timeout), "没有出现状态提示「\(text)」")
    }

    /// Agent「更多操作 › 隐藏」：Codex 收进折叠组，提示在「已隐藏」里找回。
    func testHideAgentFromMenu() {
        let app = launch()
        app.openHome("Agent")
        let more = element(id: "agent.more.codex", in: app)
        scrollTo(more, in: app)
        XCTAssertTrue(more.waitForExistence(timeout: 15), "Codex 应当有「更多操作」")
        more.tap()
        let hide = app.menuItem(id: "agent.hide", label: "隐藏")
        // 列表行里的 Menu：菜单的触发区是里面那个按钮；第一下没弹出菜单就点它。
        if !hide.appears(timeout: 3) {
            let trigger = more.buttons.firstMatch
            (trigger.exists ? trigger : more).tap()
        }
        XCTAssertTrue(hide.appears(timeout: 5), "菜单里应当有「隐藏」")
        hide.tap()
        waitForStatus("已隐藏 Codex", in: app)
    }

    /// 「模型列表」：打开 Codex 的模型列表，能看到路由组和供应商的模型，切换一个。
    func testAgentModelList() {
        let app = launch()
        app.openHome("Agent")
        let entry = element(id: "agent.models.codex", in: app)
        scrollTo(entry, in: app)
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "Codex 应当有「模型列表」一行")
        entry.tap()
        XCTAssertTrue(app.navigationBars["Codex 的模型列表"].waitForExistence(timeout: 10))
        // 「只显示我勾选的模型」在最上面：先看它，再往下滑到示例中转的 o3（列表懒加载，屏幕外的行不在无障碍树里）。
        XCTAssertTrue(element(id: "agentModels.only", in: app).appears(timeout: 10), "应当有「只显示我勾选的模型」")
        let o3 = element(id: "agentModels.model.relay-example/o3", in: app)
        _ = o3.appears(timeout: 2)
        scrollTo(o3, in: app, attempts: 4)
        XCTAssertTrue(o3.appears(timeout: 10), "列表里应当有示例中转的 o3")
        o3.tap()
    }

    /// 网关密钥「修改限额」：改估算费用后保存，提示已保存。
    func testEditKeyLimit() {
        let app = launch()
        app.openFromMore("manage.keys", title: "网关密钥")
        let menu = element(id: "key.menu.iPhone", in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let edit = app.menuItem(id: "key.limit.edit", label: "修改限额")
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "菜单里应当有「修改限额」")
        edit.tap()
        let cost = app.textFields["key.limit.cost"]
        XCTAssertTrue(cost.waitForExistence(timeout: 10), "限额编辑器应当有估算费用")
        cost.tap()
        cost.typeText("5")
        let save = element(id: "key.limit.save", in: app)
        XCTAssertTrue(save.isEnabled, "改过之后应当能保存")
        save.tap()
        waitForStatus("已保存 iPhone 的限额", in: app)
    }

    /// 「已停用的模型」：示例里有一条 *preview*；从列表里再停用一个。
    func testDisabledModels() {
        let app = launch()
        app.openFromMore("manage.disabledModels", title: "已停用的模型")
        XCTAssertTrue(element(containing: "*preview*", in: app).waitForExistence(timeout: 10), "应当列出已停用的 *preview*")
        element(id: "disabledModels.add", in: app).tap()
        let pick = element(id: "disabledModels.pick.deepseek/deepseek-reasoner", in: app)
        scrollTo(pick, in: app)
        XCTAssertTrue(pick.waitForExistence(timeout: 10), "选择器里应当有 DeepSeek Reasoner")
        pick.tap()
        XCTAssertTrue(element(containing: "deepseek/deepseek-reasoner", in: app).waitForExistence(timeout: 10), "停用后应当出现在列表里")
    }

    /// 供应商「测试模型」：每个开着的模型一个结果（fixture：o3 失败），之后有「只选可用」。
    func testProviderTestModels() {
        let app = launch()
        app.openHome("供应商")
        let row = element(id: "provider.row.relay-example", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let test = element(id: "provider.testModels", in: app)
        scrollTo(test, in: app)
        XCTAssertTrue(test.waitForExistence(timeout: 10), "模型一栏应当有「测试模型」")
        test.tap()
        let mark = element(id: "provider.modelTest.o3", in: app)
        XCTAssertTrue(mark.waitForExistence(timeout: 10), "测试后 o3 旁边应当有结果")
        let working = element(id: "provider.workingOnly", in: app)
        scrollTo(working, in: app)
        XCTAssertTrue(working.waitForExistence(timeout: 10), "测过之后应当有「只选可用」")
    }
}
