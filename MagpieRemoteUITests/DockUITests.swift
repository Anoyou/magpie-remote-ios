import XCTest

/// 「更多 › 自定义底栏」：换页面、底栏与「更多」同步变化、恢复默认（示例模式不保存设置，每次启动都是默认底栏）。
@MainActor
final class DockUITests: XCTestCase {
    private var launchTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["MAGPIE_REMOTE_WARMUP_TIMEOUT"].flatMap { TimeInterval($0) } ?? 45
    }

    private func element(id identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 6) {
        app.swipeUp(until: element, max: attempts)
    }

    /// 往回滑到列表顶部附近，直到元素可点（列表懒加载，滑走的行不在无障碍树里）。
    private func scrollBack(to element: XCUIElement, in app: XCUIApplication, attempts: Int = 6) {
        app.swipeDown(until: element, max: attempts)
    }

    private func launchCustomize() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.waitForDock(timeout: launchTimeout), "没有出现底栏「更多」")
        app.openFromMore("more.customize", title: "自定义底栏")
        return app
    }

    /// 把「对话」放到第 1 个位置：底栏换成对话、主页回到「更多」；恢复默认后回到主页、会话、路由、用量。
    func testCustomizeDockAndRestoreDefault() {
        let app = launchCustomize()
        let first = element(id: "dock.slot.0", in: app)
        XCTAssertTrue(first.appears(timeout: 10), "没有显示底栏第 1 个位置")
        XCTAssertTrue(first.label.contains("主页"), "默认第 1 个应当是主页：\(first.label)")
        XCTAssertTrue(element(id: "dock.slot.more", in: app).exists, "第 5 个位置应当固定为「更多」")
        // 「恢复默认」在列表最下面（懒加载，要先滑到它）。
        let defaultReset = element(id: "dock.reset", in: app)
        scrollTo(defaultReset, in: app)
        XCTAssertTrue(defaultReset.appears(timeout: 5), "没有「恢复默认」按钮")
        XCTAssertFalse(defaultReset.isEnabled, "默认底栏时「恢复默认」应当不可点")

        let chat = element(id: "dock.candidate.chat", in: app)
        scrollBack(to: chat, in: app)
        XCTAssertTrue(chat.appears(timeout: 10), "「在『更多』里」没有列出对话")
        chat.tap()
        let place = app.menuItem(id: "dock.place.0", label: "第 1 个位置（换下「主页」）")
        XCTAssertTrue(place.appears(timeout: 5), "没有出现「放进底栏」的位置选项")
        place.tap()

        XCTAssertTrue(app.tabBars.buttons["对话"].appears(timeout: 10), "底栏没有出现「对话」")
        XCTAssertFalse(app.tabBars.buttons["主页"].exists, "被换下的主页不应还在底栏")
        XCTAssertTrue(app.tabBars.buttons["更多"].exists, "「更多」应当一直在底栏")
        let slot0 = element(id: "dock.slot.0", in: app)
        scrollBack(to: slot0, in: app)
        XCTAssertTrue(slot0.label.contains("对话"), "第 1 个位置应当换成对话：\(slot0.label)")
        let home = element(id: "dock.candidate.home", in: app)
        scrollTo(home, in: app)
        XCTAssertTrue(home.appears(timeout: 5), "被换下的主页应当回到「更多」")
        XCTAssertFalse(element(id: "dock.candidate.chat", in: app).exists, "放进底栏的对话不应还在「更多」里")

        let reset = element(id: "dock.reset", in: app)
        scrollTo(reset, in: app)
        XCTAssertTrue(reset.isEnabled, "自定义后「恢复默认」应当可点")
        reset.tap()
        XCTAssertTrue(app.tabBars.buttons["主页"].appears(timeout: 10), "恢复默认后底栏没有回到主页")
        for title in ["会话", "路由", "用量", "更多"] {
            XCTAssertTrue(app.tabBars.buttons[title].exists, "恢复默认后缺少「\(title)」")
        }
        XCTAssertFalse(app.tabBars.buttons["对话"].exists, "恢复默认后「对话」应当回到「更多」")
    }

    /// 放进底栏的页面直接从底栏打开，「更多」列表里不再出现它，换下来的页面出现在「更多」里。
    func testDockedPageOpensFromTabAndLeavesMore() {
        let app = launchCustomize()
        // 用第 4 个位置（用量）的菜单换成「网关密钥」。
        let menu = element(id: "dock.slot.3.menu", in: app)
        XCTAssertTrue(menu.appears(timeout: 10), "底栏第 4 个位置没有更换按钮")
        menu.tap()
        let keys = app.menuItem(id: "dock.slot.3.use.keys", label: "网关密钥")
        XCTAssertTrue(keys.appears(timeout: 5), "更换菜单里没有「网关密钥」")
        keys.tap()
        XCTAssertTrue(app.tabBars.buttons["网关密钥"].appears(timeout: 10), "底栏没有出现「网关密钥」")
        XCTAssertFalse(app.tabBars.buttons["用量"].exists, "被换下的「用量」不应还在底栏")

        app.openDockTab("网关密钥")
        XCTAssertTrue(element(id: "key.add", in: app).appears(timeout: 15), "从底栏打开的网关密钥页没有内容")

        // 回到「更多」根列表：网关密钥不在了，用量回来了。
        app.tabBars.buttons["更多"].tap()
        let back = app.navigationBars["自定义底栏"].buttons.element(boundBy: 0)
        if back.appears(timeout: 5) { back.tap() }
        XCTAssertTrue(app.navigationBars["更多"].appears(timeout: 10), "没有回到「更多」")
        // 「更多」列表停在上次滑到的位置（打开「自定义底栏」时滑到了底部），用量在上面的「网关」一节里。
        let usage = element(id: "more.usage", in: app)
        if !usage.appears(timeout: 3) { scrollBack(to: usage, in: app) }
        XCTAssertTrue(usage.exists, "换下来的「用量」应当出现在「更多」里")
        XCTAssertFalse(element(id: "manage.keys", in: app).exists, "放进底栏的「网关密钥」不应还在「更多」里")
    }
}
