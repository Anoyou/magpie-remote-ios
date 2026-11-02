import XCTest

/// 「更多 › 资源库」：fixture 模式下的示例资源库（`FixtureLibraryService`）。
@MainActor
final class LibraryUITests: XCTestCase {
    private var launchTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["MAGPIE_REMOTE_WARMUP_TIMEOUT"].flatMap { TimeInterval($0) } ?? 45
    }

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.waitForDock(timeout: launchTimeout), "没有出现底栏「更多」")
        app.openFromMore("more.library", title: "资源库")
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tab(_ title: String, in app: XCUIApplication) {
        let control = app.segmentedControls["library.tabs"].exists ? app.segmentedControls["library.tabs"] : app.segmentedControls.firstMatch
        XCTAssertTrue(control.appears(timeout: 15), "资源库顶部没有分页器")
        let button = control.buttons[title]
        XCTAssertTrue(button.appears(timeout: 5), "分页器里没有「\(title)」")
        button.tap()
    }

    /// 打开资源库，切到 MCP 服务器：示例服务器在列表里，进详情能看到检测状态和工具。
    func testServersListAndDetail() {
        let app = launch()
        tab("MCP", in: app)
        let row = element("library.server.github", in: app)
        _ = row.appears(timeout: 10)
        app.swipeUp(until: row, max: 4)
        XCTAssertTrue(row.appears(timeout: 10), "应列出示例服务器 github")
        row.tap()
        XCTAssertTrue(app.navigationBars["github"].appears(timeout: 10), "应打开 github 的详情")
        XCTAssertTrue(element("library.serverDetail.check", in: app).appears(timeout: 10))
        let tool = element("library.tool.search_code", in: app)
        _ = tool.appears(timeout: 10)
        app.swipeUp(until: tool, max: 4)
        XCTAssertTrue(tool.appears(timeout: 10), "检测完应列出它的工具")
    }

    /// 技能：进详情后「移除」要先确认，确认后回到列表、技能不见了。
    func testRemoveSkillAsksFirst() {
        let app = launch()
        tab("技能", in: app)
        let row = element("library.skill.docx", in: app)
        _ = row.appears(timeout: 10)
        app.swipeUp(until: row, max: 6)
        XCTAssertTrue(row.appears(timeout: 10), "应列出示例技能 docx")
        row.tap()
        XCTAssertTrue(app.navigationBars["docx"].appears(timeout: 10))
        let remove = element("library.skillDetail.remove", in: app)
        _ = remove.appears(timeout: 5)
        app.swipeUp(until: remove, max: 6)
        XCTAssertTrue(remove.appears(timeout: 5))
        remove.tap()
        let confirm = app.buttons["library.confirm"].firstMatch
        XCTAssertTrue(confirm.appears(timeout: 5), "移除前应先确认")
        confirm.tap()
        XCTAssertTrue(app.navigationBars["资源库"].appears(timeout: 10), "移除后应回到资源库")
        XCTAssertTrue(element("library.skill.docx", in: app).disappears(timeout: 10), "docx 应已移除")
    }

    /// Hooks：添加一个，填名称和命令，保存后出现在列表里。
    func testAddHook() {
        let app = launch()
        tab("Hooks", in: app)
        let add = element("library.hooks.add", in: app)
        _ = add.appears(timeout: 10)
        app.swipeUp(until: add, max: 6)
        XCTAssertTrue(add.appears(timeout: 10))
        add.tap()
        let name = app.textFields["library.hookEditor.name"]
        XCTAssertTrue(name.appears(timeout: 10), "应打开新 Hook 的编辑器")
        name.tap()
        name.typeText("ping")
        let command = app.textFields["library.hookEditor.command"]
        XCTAssertTrue(command.appears(timeout: 5))
        command.tap()
        command.typeText("say done")
        app.buttons["library.hookEditor.save"].tap()
        let row = element("library.hook.ping", in: app)
        _ = row.appears(timeout: 10)
        app.swipeUp(until: row, max: 6)
        XCTAssertTrue(row.appears(timeout: 10), "保存后应列出 ping")
    }
}
