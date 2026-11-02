import XCTest

/// 0.6.3：页面顶部分页器的间距规则（DESIGN.md「顶部分页器」，`PageTopStripMetrics`）在每一页都一样：
/// 分页器离导航栏的距离各页相同，分页器到下面第一块内容 12pt（不叠加列表的分组间距），
/// 「用量」的两个分页器在同一条里、中间 8pt。「卡片间距」紧凑 / 宽松两种都要一样。
@MainActor
final class PickerGapUITests: XCTestCase {
    private var launchTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["MAGPIE_REMOTE_WARMUP_TIMEOUT"].flatMap { TimeInterval($0) } ?? 45
    }

    private func launch(spacing: String? = nil) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if let spacing { app.launchArguments += ["-app.cardSpacing", spacing] }
        app.launch()
        XCTAssertTrue(app.waitForDock(timeout: launchTimeout), "没有出现底栏「更多」")
        return app
    }

    private struct Gap {
        let page: String
        let top: CGFloat
        let below: CGFloat
        var text: String { "\(page)：顶 \(Int(top.rounded()))，下 \(Int(below.rounded()))" }
    }

    /// 分页器 `pickerID`（条里最下面那个）的上沿离导航栏底边多远、下沿离下面第一块内容多远。
    /// 列表页的「第一块内容」是分页器下面最靠上的那一行（cell）；`ScrollView` 页给出那块内容的 id。
    private func measure(_ page: String, picker pickerID: String, topPicker: String? = nil, firstContent: String? = nil,
                         in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> Gap? {
        let picker = app.segmentedControls[pickerID]
        let first = app.segmentedControls[topPicker ?? pickerID]
        XCTAssertTrue(picker.appears(timeout: 10), "\(page)：没有分页器 \(pickerID)", file: file, line: line)
        // 等内容读出来、布局停下来
        _ = waitUntil(1.5) { false }
        let p = picker.frame
        let bar = app.navigationBars.firstMatch.frame
        var next: CGFloat?
        if let firstContent {
            let element = app.descendants(matching: .any).matching(identifier: firstContent).firstMatch
            XCTAssertTrue(element.appears(timeout: 10), "\(page)：没有 \(firstContent)", file: file, line: line)
            next = element.frame.minY
        } else {
            let list = app.collectionViews.containing(.segmentedControl, identifier: pickerID).firstMatch
            guard let snap = try? list.snapshot() else {
                XCTFail("\(page)：读不到列表", file: file, line: line)
                return nil
            }
            var cells: [CGRect] = []
            func walk(_ s: XCUIElementSnapshot) {
                if s.elementType == .cell { cells.append(s.frame) }
                s.children.forEach(walk)
            }
            walk(snap)
            next = cells.filter { $0.minY > p.maxY - 0.5 && $0.height > 1 && !$0.contains(CGPoint(x: p.midX, y: p.midY)) }
                .map(\.minY).min()
        }
        guard let next else {
            XCTFail("\(page)：分页器下面没有内容", file: file, line: line)
            return nil
        }
        return Gap(page: page, top: first.frame.minY - bar.maxY, below: next - p.maxY)
    }

    private func checkAllPages(_ mode: String, in app: XCUIApplication) {
        var gaps: [Gap] = []
        app.openHome("Agent")
        gaps.append(measure("主页 Agent", picker: "home.segment", in: app)!)
        app.openHome("供应商")
        gaps.append(measure("主页 供应商", picker: "home.segment", in: app)!)
        app.openHome("额度")
        gaps.append(measure("主页 额度", picker: "home.segment", firstContent: "host.status", in: app)!)

        app.openDockTab("用量")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "usage.totalCost").firstMatch.appears(timeout: 15), "概览没有出现总花费")
        let tab = app.segmentedControls["usage.tab"]
        app.swipeDown(until: tab, max: 4)
        let usage = measure("用量 概览", picker: "usage.period", topPicker: "usage.tab", in: app)!
        gaps.append(usage)
        // 两个分页器在同一条里，中间 8pt
        let between = app.segmentedControls["usage.period"].frame.minY - tab.frame.maxY
        XCTAssertEqual(between, 8, accuracy: 3, "[\(mode)] 用量的两个分页器之间应当约 8pt，实际 \(between)")

        let all = gaps.map(\.text).joined(separator: "；")
        let belows = gaps.map(\.below), tops = gaps.map(\.top)
        XCTAssertLessThanOrEqual(belows.max()! - belows.min()!, 2, "[\(mode)] 分页器到第一块内容的距离各页不一样：\(all)")
        XCTAssertLessThanOrEqual(tops.max()! - tops.min()!, 2, "[\(mode)] 分页器离导航栏的距离各页不一样：\(all)")
        for gap in gaps {
            XCTAssertEqual(gap.below, 12, accuracy: 3, "[\(mode)] 分页器到第一块内容应当约 12pt：\(all)")
        }
    }

    func testPickerGapsCompact() {
        checkAllPages("紧凑", in: launch(spacing: "compact"))
    }

    func testPickerGapsRoomy() {
        checkAllPages("宽松", in: launch(spacing: "roomy"))
    }

    /// 「更多 › App › 卡片间距」：紧凑 / 宽松，默认紧凑；点了会记住。
    func testCardSpacingSetting() {
        let app = launch()
        app.openMore()
        let control = app.segmentedControls["more.cardSpacing"]
        app.swipeUp(until: control, max: 5)
        XCTAssertTrue(control.appears(timeout: 10), "「更多 › App」里没有「卡片间距」")
        XCTAssertTrue(control.buttons["紧凑"].isSelected, "默认应当是「紧凑」")
        control.buttons["宽松"].tap()
        XCTAssertTrue(waitUntil(3) { control.buttons["宽松"].isSelected }, "点「宽松」没有选上")
        control.buttons["紧凑"].tap()
        XCTAssertTrue(waitUntil(3) { control.buttons["紧凑"].isSelected }, "点回「紧凑」没有选上")
    }
}
