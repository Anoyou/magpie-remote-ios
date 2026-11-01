import XCTest

/// 「路由」舞台的逐帧截图：和官方 magpie 网页路由页逐帧对比喜鹊的样子与时间（网页那边用 Playwright 的假时钟截）。
///
/// `--routes-snapshot=<秒>` 让舞台用停住的时钟（RoutesClock）：fixture 的示例请求（RoutesFixture.trace）从 <秒> 开始，
/// 每点一下导航栏上的「下一帧」（routes.snapshot.step）走 0.1 秒，等它的 value 显示这一刻已经画好再截。每帧既作为附件放进 .xcresult，
/// 也写到仓库的 build/results/routes-frames/（CI 会把 build/results 整个上传成 artifact）。
/// 场景：6.0–10.6 秒是第 13 个请求（先飞到 magpie 等路由，再到第一个 Key，回答衔回来）；
/// 18.0–22.6 秒是第 15 个请求（第一个 Key 限流 429，红圈飞回 magpie，改道到第二个 Key）。
@MainActor
final class RoutesSnapshotUITests: XCTestCase {
    private var launchTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["MAGPIE_REMOTE_WARMUP_TIMEOUT"].flatMap { TimeInterval($0) } ?? 45
    }

    /// build/results/routes-frames（从这个源文件的路径往上两级就是仓库根）。
    private var outputDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/results/routes-frames", isDirectory: true)
    }

    private func frames(_ scene: String, from start: Double, to end: Double, every: Int = 1, dark: Bool = false) {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = dark ? .dark : .light
        defer { XCUIDevice.shared.appearance = .light }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--routes-fliers", "--routes-snapshot=\(start)",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.waitForDock(timeout: launchTimeout), "没有出现底栏「更多」")
        app.openDockTab("路由")
        let stage = app.descendants(matching: .any).matching(identifier: "routes.stage").firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 15), "没有出现实时路由舞台")
        let step = app.buttons["routes.snapshot.step"].firstMatch
        let clock = step
        let directory = outputDirectory.appendingPathComponent(scene, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var ms = Int((start * 1000).rounded())
        let last = Int((end * 1000).rounded())
        var index = 0
        while ms <= last {
            wait(for: clock, toShow: ms)
            if index % every == 0 {
                let shot = stage.screenshot()
                let name = String(format: "ios-%06d", ms)
                let attachment = XCTAttachment(screenshot: shot)
                attachment.name = "\(scene)/\(name)"
                attachment.lifetime = .keepAlways
                add(attachment)
                try? shot.pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
            }
            index += 1
            ms += 100
            if ms <= last { step.tap() }
        }
    }

    private func wait(for clock: XCUIElement, toShow ms: Int) {
        let shown = NSPredicate(format: "value == %@", "\(ms)")
        let done = expectation(for: shown, evaluatedWith: clock)
        wait(for: [done], timeout: 20)
    }

    func testRoutesFramesSuccess() {
        frames("success-light", from: 6.0, to: 10.6)
    }

    func testRoutesFramesReroute() {
        frames("reroute-light", from: 18.0, to: 22.6)
    }

    func testRoutesFramesDark() {
        frames("success-dark", from: 6.0, to: 10.6, every: 3, dark: true)
    }
}
