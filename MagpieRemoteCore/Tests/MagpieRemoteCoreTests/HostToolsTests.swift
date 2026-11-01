import XCTest
@testable import MagpieRemoteCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 主机更新、自动调优、隐私模型。fixture 按 magpie 源码（internal/gui/update.go、tune.go、privacymodel.go）的 json 标签整理，数据是假的。
final class HostUpdateTests: XCTestCase {
    private func status(_ name: String) throws -> HostUpdateStatus { HostUpdateStatus(json: try WebFixture.json(name)) }

    func testFoundOffersDownload() throws {
        let s = try status("update-found.json")
        XCTAssertEqual(s.state, .found)
        XCTAssertEqual(s.current, "v0.1.2438")
        XCTAssertEqual(s.latest, "v0.1.2450")
        XCTAssertTrue(s.hasUpdate)
        XCTAssertEqual(s.action, .download)
        XCTAssertTrue(s.summary.contains("v0.1.2450"))
        XCTAssertTrue(s.summary.contains("48.3 MB"))
        XCTAssertFalse(s.isWorking)
    }

    func testDownloadingProgress() throws {
        let s = try status("update-downloading.json")
        XCTAssertEqual(s.progress ?? 0, 0.25, accuracy: 0.001)
        XCTAssertTrue(s.isWorking)
        XCTAssertNil(s.action)
        XCTAssertTrue(s.summary.contains("12 MB / 48 MB"))
    }

    func testReadyBusyWarnsAboutRestart() throws {
        let s = try status("update-ready-busy.json")
        XCTAssertEqual(s.action, .restart)
        XCTAssertTrue(s.isBusy)
        XCTAssertEqual(s.busyRequests, 2)
        XCTAssertEqual(s.busyTools, 1)
        XCTAssertTrue(s.handover)
        XCTAssertNotNil(s.restartWarning)
        XCTAssertTrue(s.restartWarning!.contains("2 个请求"))
    }

    func testWaitingCanBeCancelled() throws {
        let s = try status("update-waiting.json")
        XCTAssertTrue(s.waiting)
        XCTAssertEqual(s.action, .cancelWait)
        XCTAssertTrue(s.isWorking)
        XCTAssertTrue(s.summary.contains("空闲"))
    }

    func testPackagedCannotSelfUpdate() throws {
        let s = try status("update-available-package.json")
        XCTAssertEqual(s.state, .available)
        XCTAssertNil(s.action, "available 时主机只会在 Mac 上打开网页，App 不发 install")
        XCTAssertEqual(s.packaged?.command, "brew upgrade magpie")
        XCTAssertTrue(s.summary.contains("Homebrew"))
    }

    func testErrorRetryAndNetwork() throws {
        let s = try status("update-error-retry.json")
        XCTAssertEqual(s.action, .retryDownload)
        XCTAssertTrue(s.summary.contains("网络"))
    }

    func testLatestAndStale() throws {
        let latest = try status("update-latest.json")
        XCTAssertFalse(latest.hasUpdate)
        XCTAssertNil(latest.action)
        XCTAssertEqual(latest.summary, "已是最新版本。")
        let stale = try status("update-stale.json")
        XCTAssertEqual(stale.state, .unknown)
        XCTAssertFalse(stale.hasUpdate)
    }

    func testUnknownStateDecodesDefensively() {
        let s = HostUpdateStatus(json: ["state": "something-new", "current": "v1.0.0"])
        XCTAssertEqual(s.state, .unknown)
        XCTAssertNil(s.action)
    }

    func testNotes() throws {
        let notes = HostUpdateNotes(json: try WebFixture.json("update-notes.json"))
        XCTAssertEqual(notes.latest, "v0.1.2450")
        XCTAssertEqual(notes.releases.map(\.version), ["0.1.2450", "0.1.2444"])
        XCTAssertTrue(notes.releases[0].pending)
        let lines = ReleaseNotesFormat.lines(notes.releases[0].notes)
        XCTAssertEqual(lines, [.heading("新增"), .bullet("示例：用量页可以按密钥筛选"), .heading("修复"), .bullet("示例：修复了一个崩溃")])
        XCTAssertTrue(HostUpdateNotes(json: ["releases": nil]).releases.isEmpty)
    }

    func testCompatibilityOfNewVersion() {
        XCTAssertEqual(HostUpdateCompatibility.of(MagpieCompatibility.testedHostVersion.description), .tested)
        let newer = SemanticVersion(MagpieCompatibility.testedHostVersion.major, MagpieCompatibility.testedHostVersion.minor,
                                    MagpieCompatibility.testedHostVersion.patch + 12)
        if case .untested = HostUpdateCompatibility.of("v" + newer.description) {} else { XCTFail("应提示未经验证") }
        XCTAssertNotNil(HostUpdateCompatibility.of("v" + newer.description).warning)
        if case .unsupported = HostUpdateCompatibility.of("v0.0.1") {} else { XCTFail("应提示过旧") }
        XCTAssertEqual(HostUpdateCompatibility.of("dev"), .unknown)
        XCTAssertNil(HostUpdateCompatibility.unknown.warning)
    }

    func testInstallBodies() throws {
        XCTAssertEqual(HostToolsRequests.install(.whenIdle), [:])
        XCTAssertEqual(HostToolsRequests.install(.now), ["when": "now"])
        XCTAssertEqual(HostToolsRequests.install(.cancel), ["when": "cancel"])
    }

    // MARK: 重启跟踪

    func testTrackerOldThenDownThenNew() {
        var t = HostRestartTracker(oldVersion: "v0.1.2438")
        XCTAssertEqual(t.observe(version: "v0.1.2438"), .waiting(sawDown: false))
        XCTAssertEqual(t.observe(version: nil), .waiting(sawDown: true))
        XCTAssertEqual(t.observe(version: nil), .waiting(sawDown: true))
        XCTAssertEqual(t.observe(version: "v0.1.2450"), .back(version: "v0.1.2450", upgraded: true))
    }

    func testTrackerBackOnSameVersionAfterDown() {
        var t = HostRestartTracker(oldVersion: "v0.1.2438")
        _ = t.observe(version: nil)
        XCTAssertEqual(t.observe(version: "0.1.2438"), .back(version: "0.1.2438", upgraded: false))
    }

    func testTrackerGivesUpWhenNeverRestarted() {
        var t = HostRestartTracker(oldVersion: "v0.1.2438", sameLimit: 3)
        XCTAssertEqual(t.observe(version: "v0.1.2438"), .waiting(sawDown: false))
        XCTAssertEqual(t.observe(version: "v0.1.2438"), .waiting(sawDown: false))
        XCTAssertEqual(t.observe(version: "v0.1.2438"), .back(version: "v0.1.2438", upgraded: false))
    }

    func testWaitPollsUntilBack() async throws {
        actor Script {
            var answers: [String?] = ["v0.1.2438", nil, nil, "v0.1.2450"]
            var calls = 0
            func next() throws -> String? {
                calls += 1
                let a = answers.removeFirst()
                guard let a else { throw URLError(.cannotConnectToHost) }
                return a
            }
        }
        let script = Script()
        let outcome = try await HostRestartTracker.wait(oldVersion: "v0.1.2438", interval: .milliseconds(1), timeout: .seconds(5)) {
            try await script.next()
        }
        XCTAssertEqual(outcome, .back(version: "v0.1.2450", upgraded: true))
        let calls = await script.calls
        XCTAssertEqual(calls, 4)
    }

    func testWaitTimesOut() async {
        do {
            _ = try await HostRestartTracker.wait(oldVersion: "v1", interval: .milliseconds(1), timeout: .milliseconds(5)) {
                throw URLError(.cannotConnectToHost)
            }
            XCTFail("应超时")
        } catch {
            XCTAssertEqual(error as? MagpieError, .unreachable(.timedOut))
        }
    }

    func testFormats() {
        XCTAssertEqual(HostToolsFormat.version("0.1.2"), "v0.1.2")
        XCTAssertEqual(HostToolsFormat.version("v0.1.2"), "v0.1.2")
        XCTAssertEqual(HostToolsFormat.bytes(180_000_000), "180 MB")
        XCTAssertEqual(HostToolsFormat.bytes(1_500_000_000), "1.5 GB")
        XCTAssertEqual(HostToolsFormat.tokensK(150_000), "150K")
        XCTAssertEqual(HostToolsFormat.tokensK(1_000_000), "1M")
        XCTAssertEqual(HostToolsFormat.seconds(45), "45 秒")
        XCTAssertEqual(HostToolsFormat.seconds(540), "9 分钟")
    }
}

final class HostTuneTests: XCTestCase {
    func testDecodesAdvice() throws {
        let state = TuneState(json: try WebFixture.json("tune.json"))
        XCTAssertEqual(state.days, 7)
        XCTAssertEqual(state.agents.map(\.agent), ["claude", "codex"])
        let claude = state.agents[0]
        XCTAssertEqual(claude.name, "Claude Code")
        XCTAssertEqual(claude.calls, 5321)
        XCTAssertEqual(claude.advice.map(\.knob), ["compact", "cache_ttl", "subagent_cache_ttl"])

        let compact = claude.advice[0]
        XCTAssertEqual(compact.model, "claude-sonnet-example")
        XCTAssertEqual(compact.currentText, "200K")
        XCTAssertEqual(compact.bestText, "150K")
        XCTAssertTrue(compact.canApply)
        XCTAssertFalse(compact.canUndo)
        XCTAssertEqual(compact.savingShare, 1_700_000.0 / 9_800_000.0, accuracy: 0.0001)
        XCTAssertTrue(compact.verdict.contains("17%"))
        XCTAssertTrue(compact.explanation.contains("压缩 12 次"))
        XCTAssertNotNil(compact.caveat)
        XCTAssertTrue(compact.replacesUserValue)
        XCTAssertEqual(compact.applyChange.body, ["agent": "claude", "knob": "compact", "model": "claude-sonnet-example", "value": "150000"])

        let ttl = claude.advice[1]
        XCTAssertEqual(ttl.currentText, "5 分钟")
        XCTAssertEqual(ttl.bestText, "1 小时")
        XCTAssertTrue(ttl.canApply)
        XCTAssertTrue(ttl.explanation.contains("61%"))
        XCTAssertNil(ttl.caveat)

        let sub = claude.advice[2]
        XCTAssertTrue(sub.isSame)
        XCTAssertFalse(sub.canApply)
        XCTAssertTrue(sub.canUndo)
        XCTAssertEqual(sub.verdict, "已经是最省的")
        XCTAssertEqual(sub.undoChange.undoBody, ["agent": "claude", "knob": "subagent_cache_ttl", "model": ""])
    }

    func testCodexTimedAndBackground() throws {
        let state = TuneState(json: try WebFixture.json("tune.json"))
        let codex = try XCTUnwrap(state.agents.last?.advice.first)
        XCTAssertEqual(codex.model, "", "Codex 的 compact 没有 model 字段，请求里发空字符串")
        XCTAssertTrue(codex.isTimed)
        XCTAssertTrue(codex.sourceText.contains("长对话"))
        XCTAssertTrue(codex.explanation.contains("30 秒"))
        let bg = try XCTUnwrap(codex.background)
        XCTAssertEqual(bg.percent, 55)
        XCTAssertTrue(bg.canApply)
        XCTAssertEqual(TuneChange.background(bg).body, ["agent": "codex", "knob": "async_compact", "model": "", "value": "55"])
    }

    func testApplyAllSkipsDoneAndHeld() throws {
        let state = TuneState(json: try WebFixture.json("tune.json"))
        XCTAssertEqual(state.applicable.map(\.knob), ["compact", "cache_ttl", "compact"])
        let locked = TuneState(json: try WebFixture.json("tune-locked.json"))
        XCTAssertEqual(locked.shown.map(\.agent), ["claude"])
        let advice = try XCTUnwrap(locked.shown.first?.advice.first)
        XCTAssertTrue(advice.isHeld)
        XCTAssertFalse(advice.canApply)
        XCTAssertTrue(advice.sourceText.contains("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"))
        XCTAssertTrue(locked.applicable.isEmpty)
    }

    func testAppliedSetting() throws {
        let s = TuneSetting(json: try WebFixture.json("tune-apply.json"))
        XCTAssertTrue(s.ours)
        XCTAssertEqual(s.value, "150000")
        XCTAssertEqual(TuneSetting(json: ["value": 120000]).value, "120000", "数字形式也能读")
    }

    func testEmptyAndUnknownAdviceDecode() {
        XCTAssertTrue(TuneState(json: ["days": 7, "agents": []]).shown.isEmpty)
        let odd = TuneState(json: ["agents": [["agent": "claude", "advice": [["knob": "new_knob"]]]]])
        XCTAssertTrue(odd.agents[0].advice.isEmpty, "既没有 compact 也没有 ttl 的建议跳过")
    }
}

final class HostPrivacyModelTests: XCTestCase {
    func testOff() throws {
        let m = PrivacyModelState(json: try WebFixture.json("privacy-model-off.json"))
        XCTAssertFalse(m.on)
        XCTAssertFalse(m.showsOn)
        XCTAssertEqual(m.current.model, "astrlink-guard")
        XCTAssertEqual(m.current.name, "AstrLink Guard")
        XCTAssertEqual(m.models.map(\.model), ["privacy-filter", "astrlink-guard"])
        XCTAssertTrue(m.summary.contains("180 MB"))
        XCTAssertFalse(m.canRemove)
        XCTAssertTrue(m.usesDefaultScore)
        XCTAssertEqual(m.selectedScore, 0)
        XCTAssertEqual(m.scoreChoices.first?.title, "默认（0.7）")
        XCTAssertFalse(m.scoreChoices.contains { $0.value == 0.7 })
    }

    func testOnWithCoreML() throws {
        let m = PrivacyModelState(json: try WebFixture.json("privacy-model-on.json"))
        XCTAssertTrue(m.on)
        XCTAssertTrue(m.chosen)
        XCTAssertTrue(m.current.running)
        XCTAssertEqual(m.summary, "已打开，用 CoreML 运行在神经网络引擎上。")
        XCTAssertFalse(m.usesDefaultScore)
        XCTAssertEqual(m.selectedScore, 0.85)
        XCTAssertFalse(m.isWorking)
    }

    func testDownloadingOther() throws {
        let m = PrivacyModelState(json: try WebFixture.json("privacy-model-downloading.json"))
        XCTAssertEqual(m.downloadingModel?.model, "privacy-filter")
        XCTAssertEqual(m.downloadingModel?.progress ?? 0, 0.2, accuracy: 0.001)
        XCTAssertTrue(m.isWorking)
        XCTAssertTrue(m.summary.contains("Privacy Filter"))
        XCTAssertTrue(m.summary.contains("300 MB / 1.5 GB"))
    }

    func testActionBodies() {
        XCTAssertEqual(PrivacyModelAction.on(model: nil).body, ["do": "on"])
        XCTAssertEqual(PrivacyModelAction.on(model: "astrlink-guard").body, ["do": "on", "model": "astrlink-guard"])
        XCTAssertEqual(PrivacyModelAction.off.body, ["do": "off"])
        XCTAssertEqual(PrivacyModelAction.cancel.body, ["do": "cancel"])
        XCTAssertEqual(PrivacyModelAction.remove.body, ["do": "remove"])
        XCTAssertEqual(PrivacyModelAction.pick(model: "privacy-filter").body, ["do": "pick", "model": "privacy-filter"])
        XCTAssertEqual(PrivacyModelAction.score(0.8, model: "astrlink-guard").body, ["do": "score", "score": .double(0.8), "model": "astrlink-guard"])
        XCTAssertTrue(PrivacyModelAction.validScore(0))
        XCTAssertTrue(PrivacyModelAction.validScore(0.5))
        XCTAssertFalse(PrivacyModelAction.validScore(0.4))
        XCTAssertFalse(PrivacyModelAction.validScore(1))
        XCTAssertEqual(PrivacyModelState.score(0.85), "0.85")
        XCTAssertEqual(PrivacyModelState.score(0.5), "0.5")
    }

    func testUnsupportedHost() {
        let m = PrivacyModelState(json: ["on": false, "model": "privacy-filter", "supported": false, "installed": false, "models": []])
        XCTAssertFalse(m.usable)
        XCTAssertTrue(m.summary.contains("不能运行"))
    }
}

/// 请求的路径、查询参数、Cookie 与请求体。
final class HostToolsClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
    }

    private var client: WebClient { WebClient(baseURL: URL(string: "http://100.64.0.1:3430")!, key: "sk-magpie-key-EXAMPLE", session: session) }

    private func body(_ request: URLRequest?) throws -> WebJSON {
        guard let request else { return .null }
        if let data = request.httpBody { return try WebJSON.decode(data) }
        guard let stream = request.httpBodyStream else { return .null }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return try WebJSON.decode(data)
    }

    private func reply(_ name: String) throws {
        let data = try WebFixture.data(name)
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], data) }
    }

    func testUpdateStatusQuery() async throws {
        try reply("update-found.json")
        let s = try await client.updateStatus(fresh: true)
        XCTAssertEqual(s.state, .found)
        let url = try XCTUnwrap(StubURLProtocol.lastRequest?.url)
        XCTAssertEqual(url.path, "/api/update")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "fresh" }?.value, "1")
        XCTAssertEqual(items.first { $0.name == "lang" }?.value, "zh")
        XCTAssertNil(items.first { $0.name == "k" })
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Cookie"), "magpie_web_3430=sk-magpie-key-EXAMPLE")
    }

    func testCheckAndNotes() async throws {
        try reply("update-found.json")
        _ = try await client.checkUpdate()
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/update/check")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.query, "lang=zh")
        try reply("update-notes.json")
        let notes = try await client.updateNotes()
        XCTAssertEqual(notes.releases.count, 2)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/update/notes")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.query, "lang=zh")
    }

    func testInstall204MeansRestarting() async throws {
        StubURLProtocol.handler = { _ in (204, [:], Data()) }
        let result = try await client.installUpdate(.now)
        XCTAssertNil(result)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/update/install")
        XCTAssertEqual(try body(StubURLProtocol.lastRequest), ["when": "now"])
        try reply("update-waiting.json")
        let waiting = try await client.installUpdate()
        XCTAssertEqual(waiting?.waiting, true)
        XCTAssertEqual(try body(StubURLProtocol.lastRequest), [:])
    }

    func testTuneRequests() async throws {
        try reply("tune.json")
        _ = try await client.tune(days: 99)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.query, "days=30")
        try reply("tune-apply.json")
        let change = TuneChange(agent: "claude", knob: "compact", model: "claude-sonnet-example", value: "150000")
        let applied = try await client.applyTune(change)
        XCTAssertTrue(applied.ours)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/tune/apply")
        XCTAssertEqual(try body(StubURLProtocol.lastRequest), change.body)
        _ = try await client.undoTune(change)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/tune/undo")
        XCTAssertEqual(try body(StubURLProtocol.lastRequest), change.undoBody)
    }

    func testPrivacyModelRequests() async throws {
        try reply("privacy-model-on.json")
        let m = try await client.privacyModel()
        XCTAssertTrue(m.on)
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "GET")
        _ = try await client.privacyModel(.pick(model: "privacy-filter"))
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/privacy-model")
        XCTAssertEqual(try body(StubURLProtocol.lastRequest), ["do": "pick", "model": "privacy-filter"])
        do {
            _ = try await client.privacyModel(.score(0.3, model: nil))
            XCTFail("阈值过低应在本地拒绝")
        } catch {
            if case .webRejected = error as? MagpieError {} else { XCTFail("\(error)") }
        }
    }

    func testRejectedActionCarriesMagpieMessage() async throws {
        StubURLProtocol.handler = { _ in (400, ["Content-Type": "application/json"], Data(#"{"error":"the local masking model doesn't run on this system yet"}"#.utf8)) }
        do {
            _ = try await client.privacyModel(.on(model: nil))
            XCTFail("应抛错")
        } catch {
            XCTAssertEqual(error as? MagpieError, .webRejected(message: "the local masking model doesn't run on this system yet", code: nil))
        }
    }
}
