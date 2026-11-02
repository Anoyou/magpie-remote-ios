import XCTest

/// 资源库里「新建 / 添加 / 发现」弹出的表单：弹出来要一直停着，关掉之后还能再打开。
///
/// 0.6.0 的真机问题：这些表单挂在列表里的某一节上（一节里每一行各挂一份），点「新建一套」「添加服务器」「添加技能」
/// 表单弹出马上又自己收回，之后再点没反应。这里每个表单都：打开 → 等 2 秒仍在 → 关掉 → 再打开 → 等 2 秒仍在 → 关掉。
@MainActor
final class LibrarySheetsUITests: XCTestCase {
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

    /// 等一会儿（不查询界面）：给「弹出后马上又收回」留出发生的时间。
    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// 找到列表里的按钮（懒加载：先往下滑，滑过头再往回滑）。
    private func find(_ ids: [String], in app: XCUIApplication, file: StaticString, line: UInt) -> XCUIElement {
        for id in ids {
            let el = element(id, in: app)
            if el.appears(timeout: 2), el.isHittable { return el }
        }
        for _ in 0..<8 {
            app.swipeUp()
            for id in ids {
                let el = element(id, in: app)
                if el.exists && el.isHittable { return el }
            }
        }
        for _ in 0..<10 {
            app.swipeDown()
            for id in ids {
                let el = element(id, in: app)
                if el.exists && el.isHittable { return el }
            }
        }
        XCTFail("资源库里找不到按钮 \(ids.joined(separator: " / "))", file: file, line: line)
        return element(ids[0], in: app)
    }

    /// 打开 → 2 秒后仍在 → 关掉；重复两次（第二次证明关掉后还能再打开）。
    private func checkSheet(open ids: [String], shows marker: (XCUIApplication) -> XCUIElement, close: String, what: String,
                            in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for round in 1...2 {
            let button = find(ids, in: app, file: file, line: line)
            button.tap()
            let shown = marker(app)
            XCTAssertTrue(shown.appears(timeout: 10), "第 \(round) 次点「\(what)」没有弹出表单", file: file, line: line)
            pause(2)
            XCTAssertTrue(shown.exists, "第 \(round) 次打开的「\(what)」表单 2 秒内自己收回去了", file: file, line: line)
            let closeButton = app.navigationBars.buttons[close].firstMatch
            XCTAssertTrue(closeButton.appears(timeout: 5), "「\(what)」表单上没有「\(close)」", file: file, line: line)
            closeButton.tap()
            XCTAssertTrue(shown.disappears(timeout: 10), "点「\(close)」后「\(what)」表单没有关掉", file: file, line: line)
            XCTAssertTrue(app.navigationBars["资源库"].appears(timeout: 10), "关掉「\(what)」后没有回到资源库", file: file, line: line)
        }
    }

    /// 指令 ›「+ 新建一套」。
    func testNewInstructionSetSheetStaysAndReopens() {
        let app = launch()
        tab("指令", in: app)
        checkSheet(open: ["library.sets.add"], shows: { $0.textFields["library.newSet.name"] }, close: "取消", what: "新建一套", in: app)
    }

    /// MCP ›「＋ 添加服务器」和「发现」。
    func testServerSheetsStayAndReopen() {
        let app = launch()
        tab("MCP", in: app)
        checkSheet(open: ["library.servers.add", "library.servers.addEmpty"], shows: { $0.textFields["library.serverEditor.name"] },
                   close: "取消", what: "添加服务器", in: app)
        checkSheet(open: ["library.servers.discover"], shows: { $0.navigationBars["发现"] }, close: "关闭", what: "发现", in: app)
        // 弹窗关掉之后，列表里的别的按钮也还能用：进一个服务器的详情。
        let row = find(["library.server.github"], in: app, file: #filePath, line: #line)
        row.tap()
        XCTAssertTrue(app.navigationBars["github"].appears(timeout: 10), "关掉表单后点服务器应当还能打开详情")
    }

    /// 技能 ›「添加技能」（里面的「查找技能」要能点）和「发现」。
    func testSkillSheetsStayAndReopen() {
        let app = launch()
        tab("技能", in: app)
        checkSheet(open: ["library.skills.install", "library.skills.installEmpty"], shows: { $0.textFields["library.install.source"] },
                   close: "取消", what: "添加技能", in: app)
        // 再打开一次，填一个来源：「查找技能」变成可点，点了之后表单还在。
        let install = find(["library.skills.install", "library.skills.installEmpty"], in: app, file: #filePath, line: #line)
        install.tap()
        let source = app.textFields["library.install.source"]
        XCTAssertTrue(source.appears(timeout: 10), "没有弹出「添加技能」")
        source.tap()
        source.typeText("example/skills")
        let look = app.buttons["library.install.look"]
        XCTAssertTrue(look.appears(timeout: 5), "「添加技能」里没有「查找技能」")
        XCTAssertTrue(waitUntil(5) { look.isEnabled }, "填了来源后「查找技能」应当可以点")
        look.tap()
        pause(2)
        XCTAssertTrue(source.exists, "点「查找技能」后「添加技能」表单不应收回")
        app.navigationBars.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(source.disappears(timeout: 10))

        checkSheet(open: ["library.skills.discover"], shows: { $0.navigationBars["发现"] }, close: "关闭", what: "发现", in: app)
    }

    /// 子代理 ›「＋ 添加子代理」（Hooks 的添加见 LibraryUITests.testAddHook）。
    func testSubagentSheetStaysAndReopens() {
        let app = launch()
        tab("子代理", in: app)
        checkSheet(open: ["library.subagents.add", "library.subagents.addEmpty"],
                   shows: { $0.textFields["library.subagentEditor.name"] }, close: "取消", what: "添加子代理", in: app)
    }
}
