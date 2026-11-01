import Foundation
import MagpieRemoteCore

/// 「管理」页里的主机工具：主机更新、自动调优、隐私模型。真实实现走 `WebClient`（和其它管理页同一把 Web 密钥），
/// fixture 实现只改内存。
protocol HostToolsServing: Sendable {
    /// 轮询间隔（fixture 下更短，UI 测试不用久等）。
    var pollInterval: Duration { get }
    func hostVersion() async throws -> String?
    func updateStatus(fresh: Bool) async throws -> HostUpdateStatus
    func checkUpdate() async throws -> HostUpdateStatus
    func updateNotes() async throws -> HostUpdateNotes
    /// nil = 主机回了 204，正在重启。
    func installUpdate(_ when: HostUpdateInstallWhen) async throws -> HostUpdateStatus?
    func tune(days: Int) async throws -> TuneState
    func applyTune(_ change: TuneChange) async throws -> TuneSetting
    func undoTune(_ change: TuneChange) async throws -> TuneSetting
    func privacyModel() async throws -> PrivacyModelState
    func privacyModel(_ action: PrivacyModelAction) async throws -> PrivacyModelState
}

enum HostTools {
    /// 跟着「管理」页当前用的服务走：真实主机用同一个 WebClient，fixture 用示例数据。
    static func service(for manage: (any ManageServing)?) -> (any HostToolsServing)? {
        if let live = manage as? LiveManageService { return LiveHostToolsService(web: live.web) }
        if manage is FixtureManageService { return FixtureHostToolsService.shared }
        return nil
    }
}

struct LiveHostToolsService: HostToolsServing {
    let web: WebClient

    var pollInterval: Duration { .seconds(2) }

    func hostVersion() async throws -> String? {
        // 重启期间每次只等几秒，连不上就算「还没回来」。
        let quick = WebClient(baseURL: web.baseURL, key: web.key, session: web.session, timeout: 4)
        return try await quick.settings().version
    }
    func updateStatus(fresh: Bool) async throws -> HostUpdateStatus { try await web.updateStatus(fresh: fresh) }
    func checkUpdate() async throws -> HostUpdateStatus { try await web.checkUpdate() }
    func updateNotes() async throws -> HostUpdateNotes { try await web.updateNotes() }
    func installUpdate(_ when: HostUpdateInstallWhen) async throws -> HostUpdateStatus? { try await web.installUpdate(when) }
    func tune(days: Int) async throws -> TuneState { try await web.tune(days: days) }
    func applyTune(_ change: TuneChange) async throws -> TuneSetting { try await web.applyTune(change) }
    func undoTune(_ change: TuneChange) async throws -> TuneSetting { try await web.undoTune(change) }
    func privacyModel() async throws -> PrivacyModelState { try await web.privacyModel() }
    func privacyModel(_ action: PrivacyModelAction) async throws -> PrivacyModelState { try await web.privacyModel(action) }
}

/// fixture：一台「发现新版本」的示例主机，下载 / 重启 / 调优 / 隐私模型都只在内存里走一遍。
actor FixtureHostToolsService: HostToolsServing {
    static let shared = FixtureHostToolsService()

    static let oldVersion = "v0.1.2438"
    static let newVersion = "v0.1.2450"

    nonisolated var pollInterval: Duration { .milliseconds(300) }

    // MARK: 更新

    private var version = oldVersion
    private var update: WebJSON = [:]
    private var downloadTicks = 0
    /// 重启后还要「连不上」几次。
    private var restartDown = 0

    init() {
        update = Self.found
        tuneSettings = Self.initialTuneSettings
    }

    private static var found: WebJSON {
        ["state": "found", "current": .string(oldVersion), "latest": .string(newVersion), "size": 48_300_000,
         "notes": "## 新增\n- 示例：用量页可以按密钥筛选\n## 修复\n- 示例：修复了一个偶发的崩溃",
         "url": "https://example.com/magpie/releases/v0.1.2450"]
    }

    private func pause() async throws { try await Task.sleep(for: .milliseconds(80)) }

    func hostVersion() async throws -> String? {
        if restartDown > 0 {
            restartDown -= 1
            throw MagpieError.unreachable(.refused)
        }
        return version
    }

    func updateStatus(fresh: Bool) async throws -> HostUpdateStatus {
        try await pause()
        if update["state"]?.string == "downloading" {
            downloadTicks += 1
            let total = 48_000_000
            let done = min(total, downloadTicks * 16_000_000)
            update["done"] = .int(Int64(done))
            update["total"] = .int(Int64(total))
            if done >= total {
                update = ["state": "ready", "current": .string(version), "latest": .string(Self.newVersion),
                          "url": "https://example.com/magpie/releases/v0.1.2450"]
            }
        }
        return HostUpdateStatus(json: update)
    }

    func checkUpdate() async throws -> HostUpdateStatus {
        try await pause()
        if version == Self.newVersion {
            update = ["state": "latest", "current": .string(version), "latest": .string(version)]
        }
        return HostUpdateStatus(json: update)
    }

    func updateNotes() async throws -> HostUpdateNotes {
        try await pause()
        guard version != Self.newVersion else { return HostUpdateNotes(json: ["releases": []]) }
        return HostUpdateNotes(json: ["latest": .string(Self.newVersion), "releases": [
            ["version": "0.1.2450", "pending": true,
             "notes": "## 新增\n- 示例：用量页可以按密钥筛选\n- 示例：网页设置页更清楚\n## 修复\n- 示例：修复了一个偶发的崩溃"],
            ["version": "0.1.2444", "pending": true, "notes": "- 示例：读取额度更快"],
        ]])
    }

    func installUpdate(_ when: HostUpdateInstallWhen) async throws -> HostUpdateStatus? {
        try await pause()
        switch (update["state"]?.string ?? "", when) {
        case (_, .cancel):
            update["waiting"] = nil
            return HostUpdateStatus(json: update)
        case ("found", _), ("error", _):
            downloadTicks = 0
            update = ["state": "downloading", "current": .string(version), "latest": .string(Self.newVersion), "done": 0, "total": 48_000_000]
            return HostUpdateStatus(json: update)
        case ("ready", _):
            version = Self.newVersion
            restartDown = 2
            update = ["state": "latest", "current": .string(Self.newVersion), "latest": .string(Self.newVersion)]
            return nil
        default:
            return HostUpdateStatus(json: update)
        }
    }

    // MARK: 调优

    private var tuneSettings: [String: WebJSON]

    private static let initialTuneSettings: [String: WebJSON] = [
        "claude|compact|claude-sonnet-example": ["value": "200000", "source": "model"],
        "claude|cache_ttl|": ["value": "5m", "source": "settings"],
        "claude|subagent_cache_ttl|": ["value": "1h", "source": "settings"],
        "codex|compact|": ["value": "272000", "source": "long"],
        "codex|async_compact|": ["source": "async"],
    ]
    private var stash: [String: WebJSON] = [:]

    private func key(_ c: TuneChange) -> String { [c.agent, c.knob, c.model].joined(separator: "|") }

    func tune(days: Int) async throws -> TuneState {
        try await pause()
        let s = tuneSettings
        let scale = Double(max(1, days)) / 7
        func c(_ v: Double) -> WebJSON { .double((v * scale).rounded()) }
        func point(_ value: Int64, _ cost: Double, _ compacts: Int64) -> WebJSON {
            ["value": .int(value), "cost": c(cost), "compacts": .int(compacts)]
        }
        func current(_ key: String, _ fallback: Int) -> WebJSON {
            .int(Int64(s[key]?["value"]?.string.flatMap(Int.init) ?? fallback))
        }

        var claudeCompact: WebJSON = ["model": "claude-sonnet-example", "window": 1_000_000, "best": 150_000]
        claudeCompact["current"] = current("claude|compact|claude-sonnet-example", 200_000)
        claudeCompact["cost"] = c(9_800_000)
        claudeCompact["low"] = c(8_100_000)
        claudeCompact["curve"] = .array([point(100_000, 8_600_000, 40), point(150_000, 8_100_000, 22), point(200_000, 9_800_000, 12)])
        let claudeFacts: WebJSON = ["calls": 4100, "streams": 88, "compacts": 12, "growth": 3100, "after": 42000, "rework": 21000]
        claudeCompact["facts"] = claudeFacts

        var mainTTL: WebJSON = ["best": "1h"]
        mainTTL["current"] = s["claude|cache_ttl|"]?["value"] ?? "5m"
        mainTTL["cost"] = c(5_000_000)
        mainTTL["low"] = c(4_200_000)
        mainTTL["short"] = c(5_000_000)
        mainTTL["hour"] = c(4_200_000)
        let mainFacts: WebJSON = ["calls": 4100, "streams": 88, "quick": .double(0.61), "pause": .double(0.3)]
        mainTTL["facts"] = mainFacts

        var subTTL: WebJSON = ["current": "1h", "best": "1h"]
        subTTL["cost"] = c(800_000)
        subTTL["low"] = c(800_000)
        subTTL["short"] = c(950_000)
        subTTL["hour"] = c(800_000)
        let subFacts: WebJSON = ["calls": 1200, "streams": 40, "quick": .double(0.8), "pause": .double(0.15)]
        subTTL["facts"] = subFacts

        var codexCompact: WebJSON = ["model": "gpt-example", "window": 400_000, "best": 220_000, "wait": 540, "wait_best": 750]
        codexCompact["current"] = current("codex|compact|", 272_000)
        codexCompact["cost"] = c(7_000_000)
        codexCompact["low"] = c(6_400_000)
        codexCompact["curve"] = .array([point(200_000, 6_500_000, 30), point(220_000, 6_400_000, 25), point(272_000, 7_000_000, 18)])
        let codexFacts: WebJSON = ["calls": 2100, "streams": 30, "compacts": 18, "growth": 4200, "after": 51000, "rework": 30000,
                                   "took": 30, "timed": 12]
        codexCompact["facts"] = codexFacts
        var background: WebJSON = ["percent": 55, "value": 220_000, "window": 400_000]
        background["setting"] = s["codex|async_compact|"] ?? [:]

        var a1: WebJSON = ["knob": "compact", "model": "claude-sonnet-example"]
        a1["setting"] = s["claude|compact|claude-sonnet-example"] ?? [:]
        a1["compact"] = claudeCompact
        var a2: WebJSON = ["knob": "cache_ttl"]
        a2["setting"] = s["claude|cache_ttl|"] ?? [:]
        a2["ttl"] = mainTTL
        var a3: WebJSON = ["knob": "subagent_cache_ttl"]
        a3["setting"] = s["claude|subagent_cache_ttl|"] ?? [:]
        a3["ttl"] = subTTL
        var a4: WebJSON = ["knob": "compact"]
        a4["setting"] = s["codex|compact|"] ?? [:]
        a4["compact"] = codexCompact
        a4["async"] = background

        var claude: WebJSON = ["agent": "claude"]
        claude["calls"] = .int(Int64(5321 * scale))
        claude["advice"] = .array([a1, a2, a3])
        var codex: WebJSON = ["agent": "codex"]
        codex["calls"] = .int(Int64(2100 * scale))
        codex["advice"] = .array([a4])
        var root: WebJSON = ["agents": .array([claude, codex])]
        root["days"] = .int(Int64(days))
        return TuneState(json: root)
    }

    func applyTune(_ change: TuneChange) async throws -> TuneSetting {
        try await pause()
        let k = key(change)
        if stash[k] == nil { stash[k] = tuneSettings[k] ?? [:] }
        var s = tuneSettings[k] ?? [:]
        s["value"] = .string(change.value)
        s["ours"] = true
        tuneSettings[k] = s
        return TuneSetting(json: s)
    }

    func undoTune(_ change: TuneChange) async throws -> TuneSetting {
        try await pause()
        let k = key(change)
        if let old = stash.removeValue(forKey: k) { tuneSettings[k] = old }
        return TuneSetting(json: tuneSettings[k])
    }

    // MARK: 隐私模型

    private var pmOn = false
    private var pmModel = PrivacyModelState.astrLinkGuard
    private var pmInstalled: Set<String> = []
    private var pmDownloading: String?
    private var pmDone: Int64 = 0
    private var pmScore: Double = 0

    private static func size(_ id: String) -> Int64 { id == PrivacyModelState.privacyFilter ? 1_500_000_000 : 180_000_000 }

    private func status(_ id: String) -> WebJSON {
        var s: WebJSON = ["model": .string(id), "supported": true, "installed": .bool(pmInstalled.contains(id)), "size": .int(Self.size(id))]
        if pmDownloading == id {
            s["downloading"] = true
            s["done"] = .int(pmDone)
            s["total"] = .int(Self.size(id))
        }
        if pmOn && id == pmModel && pmInstalled.contains(id) {
            s["running"] = true
            s["via"] = "CoreML"
            s["device"] = "Neural Engine"
        }
        return s
    }

    private var pmState: PrivacyModelState {
        let def = pmModel == PrivacyModelState.astrLinkGuard ? 0.7 : 0.5
        var json = status(pmModel)
        json["on"] = .bool(pmOn)
        json["chosen"] = .bool(pmOn)
        json["minScore"] = .double(pmScore == 0 ? def : pmScore)
        json["defaultScore"] = .double(def)
        json["models"] = .array([status(PrivacyModelState.privacyFilter), status(PrivacyModelState.astrLinkGuard)])
        return PrivacyModelState(json: json)
    }

    private func tick() {
        guard let id = pmDownloading else { return }
        pmDone = min(Self.size(id), pmDone + Self.size(id) / 3 + 1)
        if pmDone >= Self.size(id) {
            pmInstalled.insert(id)
            pmDownloading = nil
            pmDone = 0
            pmModel = id
            pmOn = true
        }
    }

    func privacyModel() async throws -> PrivacyModelState {
        try await pause()
        tick()
        return pmState
    }

    func privacyModel(_ action: PrivacyModelAction) async throws -> PrivacyModelState {
        try await pause()
        switch action {
        case .on(let model):
            let id = model ?? pmModel
            if pmInstalled.contains(id) { pmModel = id; pmOn = true } else { pmDownloading = id; pmDone = 0 }
        case .off:
            pmDownloading = nil
            pmOn = false
        case .cancel:
            pmDownloading = nil
        case .remove:
            pmOn = false
            pmInstalled = []
        case .pick(let model):
            if pmOn && !pmInstalled.contains(model) { pmDownloading = model; pmDone = 0 } else { pmModel = model }
        case .score(let s, _):
            pmScore = s
        }
        return pmState
    }
}
