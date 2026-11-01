import Foundation

// 「管理 › 自动调优」：magpie 用这台 Mac 上 Claude Code / Codex 的会话文件重放每次调用，
// 算出最省词元的设置（internal/gui/tune.go、internal/tune、internal/agent/tune.go）。
//
// GET  /api/tune?days=7（1...30，其他值按 7）→ {days, agents[{agent, calls, advice[]}]}
// POST /api/tune/apply {agent, knob, model, value} → 该设置的新 TuneSetting
// POST /api/tune/undo  {agent, knob, model}        → 放回原值后的 TuneSetting
// knob：compact（自动压缩窗口，词元数）、cache_ttl / subagent_cache_ttl（Claude Code 缓存 5m / 1h）、
//       async_compact（Codex 后台压缩，模型窗口的百分比 1...100）。

/// 一个设置在 Agent 里现在的样子（`agent.TuneSetting`）。
public struct TuneSetting: Hashable, Sendable {
    /// 现在的值；没有任何地方设置时为空。
    public var value: String
    /// 值来自哪里：settings（Agent 自己的配置）、model（Claude Code 的 modelSettings）、env、long（magpie 的「长对话」）。
    public var source: String
    /// 优先级更高、magpie 不会去改的环境变量名；非空时应用建议没有效果。
    public var locked: String
    /// 是 magpie 调优写进去的，可以撤销。
    public var ours: Bool

    public init(json: WebJSON?) {
        value = json?["value"]?.string ?? json?["value"]?.int.map(String.init) ?? ""
        source = json?["source"]?.string ?? ""
        locked = json?["locked"]?.string ?? ""
        ours = json?["ours"]?.bool ?? false
    }
}

/// 调优用到的统计（`tune.Facts`）。
public struct TuneFacts: Hashable, Sendable {
    public var calls, streams, compacts, peak, after, growth, rework, sessions, took, timed: Int
    public var long, quick, pause, away, hour: Double

    public init(json: WebJSON?) {
        func i(_ k: String) -> Int { json?[k]?.int ?? 0 }
        func d(_ k: String) -> Double { json?[k]?.double ?? 0 }
        calls = i("calls"); streams = i("streams"); compacts = i("compacts"); peak = i("peak"); after = i("after")
        growth = i("growth"); rework = i("rework"); sessions = i("sessions"); took = i("took"); timed = i("timed")
        long = d("long"); quick = d("quick"); pause = d("pause"); away = d("away"); hour = d("hour")
    }
}

/// 曲线上的一个点：用这个值时整段时间会花的词元（加权）。
public struct TunePoint: Hashable, Sendable {
    public var value: Int
    public var cost: Double
    public var compacts: Int
    public var wait: Int
}

/// 一条建议（`tuneAdvice`）。
public struct TuneAdvice: Hashable, Identifiable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// 自动压缩窗口（词元）。
        case compact(current: Int, best: Int, window: Int)
        /// Claude Code 提示缓存时长（5m / 1h）。
        case ttl(current: String, best: String)
    }

    public var agent: String
    public var knob: String
    public var model: String
    public var setting: TuneSetting
    public var kind: Kind
    public var cost: Double
    public var low: Double
    public var facts: TuneFacts
    public var curve: [TunePoint]
    public var wait: Int
    public var waitBest: Int
    public var cheapest: Int
    public var waitCheapest: Int
    /// 模型自己的压缩阈值优先于「长对话」，改这里没用。
    public var ownModel: String
    public var ownValue: Int
    /// Codex 后台压缩建议。
    public var background: TuneAsync?

    public var id: String { [agent, knob, model].joined(separator: "\u{0}") }

    public init?(agent: String, json: WebJSON) {
        self.agent = agent
        knob = json["knob"]?.string ?? ""
        model = json["model"]?.string ?? ""
        setting = TuneSetting(json: json["setting"])
        ownModel = json["own"]?["model"]?.string ?? ""
        ownValue = json["own"]?["value"]?.int ?? 0
        if let c = json["compact"], c.object != nil {
            kind = .compact(current: c["current"]?.int ?? 0, best: c["best"]?.int ?? 0, window: c["window"]?.int ?? 0)
            cost = c["cost"]?.double ?? 0
            low = c["low"]?.double ?? 0
            facts = TuneFacts(json: c["facts"])
            curve = (c["curve"]?.array ?? []).compactMap { p in
                guard let v = p["value"]?.int else { return nil }
                return TunePoint(value: v, cost: p["cost"]?.double ?? 0, compacts: p["compacts"]?.int ?? 0, wait: p["wait"]?.int ?? 0)
            }
            wait = c["wait"]?.int ?? 0
            waitBest = c["wait_best"]?.int ?? 0
            cheapest = c["cheapest"]?.int ?? 0
            waitCheapest = c["wait_cheapest"]?.int ?? 0
        } else if let t = json["ttl"], t.object != nil {
            kind = .ttl(current: t["current"]?.string ?? "", best: t["best"]?.string ?? "")
            cost = t["cost"]?.double ?? 0
            low = t["low"]?.double ?? 0
            facts = TuneFacts(json: t["facts"])
            curve = [TunePoint(value: 5, cost: t["short"]?.double ?? 0, compacts: 0, wait: 0),
                     TunePoint(value: 60, cost: t["hour"]?.double ?? 0, compacts: 0, wait: 0)]
            wait = 0; waitBest = 0; cheapest = 0; waitCheapest = 0
        } else {
            return nil
        }
        if let a = json["async"], a.object != nil {
            background = TuneAsync(json: a)
        }
    }

    // MARK: 状态

    public var currentValue: String {
        switch kind {
        case .compact(let current, _, _): String(current)
        case .ttl(let current, _): current
        }
    }

    /// 建议的值（发给 apply 的字符串）。
    public var bestValue: String {
        switch kind {
        case .compact(_, let best, _): String(best)
        case .ttl(_, let best): best
        }
    }

    public var currentText: String { Self.show(kind, currentValue) }
    public var bestText: String { Self.show(kind, bestValue) }

    static func show(_ kind: Kind, _ value: String) -> String {
        switch kind {
        case .compact: Int(value).map(HostToolsFormat.tokensK) ?? (value.isEmpty ? "—" : value)
        case .ttl: value == "1h" ? "1 小时" : value == "5m" ? "5 分钟" : (value.isEmpty ? "—" : value)
        }
    }

    /// 现在的设置已经是最省的。
    public var isSame: Bool { currentValue == bestValue }

    /// 有更高优先级的设置挡着（环境变量，或模型自己的压缩阈值），应用没有效果。
    public var isHeld: Bool { !setting.locked.isEmpty || !ownModel.isEmpty }

    /// magpie 已经把建议值写进去了。
    public var isApplied: Bool { ownModel.isEmpty && setting.ours && setting.value == bestValue }

    /// 可以「应用」。
    public var canApply: Bool { !isSame && !isApplied && !isHeld }

    /// 可以「撤销」。
    public var canUndo: Bool { setting.ours }

    /// 改成建议值能少花的比例（0...1）。
    public var savingShare: Double { cost > 0 ? max(0, (cost - low) / cost) : 0 }

    /// 整段时间少花的词元（加权）。
    public var savedTokens: Int { Int(max(0, cost - low).rounded()) }

    public var isTimed: Bool { if case .compact = kind { return facts.took > 0 }; return false }

    // MARK: 中文说明

    /// 标题：设置名。
    public var title: String {
        switch knob {
        case "compact": "自动压缩"
        case "cache_ttl": "提示缓存 · 主对话"
        case "subagent_cache_ttl": "提示缓存 · 子代理"
        default: knob
        }
    }

    /// 现在的值从哪里来。
    public var sourceText: String {
        if !setting.locked.isEmpty { return "环境变量 \(setting.locked) 已设置并优先生效" }
        if !ownModel.isEmpty { return "\(ownModel) 有自己的压缩阈值 \(HostToolsFormat.tokensK(ownValue))，它优先生效" }
        if setting.source == "long" { return "magpie 的「长对话」设置（Codex、Claude Code 等共用）" }
        if setting.ours { return "由 magpie 调优设置" }
        if case .compact(_, _, let window) = kind, let v = Int(setting.value), window > 0, v > window {
            return "你设置了 \(HostToolsFormat.tokensK(v))，但模型窗口 \(HostToolsFormat.tokensK(window)) 优先"
        }
        if !setting.value.isEmpty { return "你设置了 \(Self.show(kind, setting.value))" }
        return "Agent 默认值"
    }

    /// 结论（徽标）。
    public var verdict: String {
        if isSame { return "已经是最省的" }
        if isApplied { return "已在使用" }
        return "少用 \(UsageFormat.percent(savingShare)) 词元 · 这段时间约 \(HostToolsFormat.tokensK(savedTokens))"
    }

    /// 为什么这么建议。
    public var explanation: String {
        switch kind {
        case .compact:
            var text = facts.compacts > 0
                ? "你的对话每次调用平均增长 \(HostToolsFormat.tokensK(facts.growth))；压缩后剩 \(HostToolsFormat.tokensK(facts.after))，把丢掉的内容读回来要花 \(HostToolsFormat.tokensK(facts.rework))。这段时间共压缩 \(facts.compacts) 次。"
                : "你的对话每次调用平均增长 \(HostToolsFormat.tokensK(facts.growth))，这段时间没有发生压缩。"
            if isTimed {
                text += isSame
                    ? "每次压缩大约让你等 \(HostToolsFormat.seconds(facts.took))（计时 \(facts.timed) 次），按现在的设置整段时间约等 \(HostToolsFormat.seconds(wait))。"
                    : "每次压缩大约让你等 \(HostToolsFormat.seconds(facts.took))（计时 \(facts.timed) 次）；用 \(bestText) 整段时间约等 \(HostToolsFormat.seconds(waitBest))，现在是 \(HostToolsFormat.seconds(wait))。"
            }
            return text
        case .ttl:
            return "你 \(UsageFormat.percent(facts.quick)) 的调用距上一次不到 5 分钟，\(UsageFormat.percent(facts.pause)) 隔了 5 到 60 分钟。"
        }
    }

    /// 需要提醒的副作用。
    public var caveat: String? {
        guard case .compact = kind, !isSame else { return nil }
        return "这只是词元\(isTimed ? "和等待时间" : "")的估算，没有衡量压缩后 Agent 对任务的记忆好坏。窗口越小，压缩越频繁。"
    }

    /// 应用会替换用户自己设置的值。
    public var replacesUserValue: Bool { !setting.value.isEmpty && !setting.ours }

    public var agentName: String { TuneState.agentName(agent) }

    /// 应用这条建议的请求。
    public var applyChange: TuneChange { TuneChange(agent: agent, knob: knob, model: model, value: bestValue) }

    /// 撤销这条建议的请求。
    public var undoChange: TuneChange { TuneChange(agent: agent, knob: knob, model: model, value: "") }
}

/// Codex 后台压缩的建议（`tuneAsync`）：在模型窗口的 percent% 时后台压缩，前台上限保留作兜底。
public struct TuneAsync: Hashable, Sendable {
    public var percent: Int
    public var value: Int
    public var window: Int
    public var setting: TuneSetting
    /// 版本太旧、不支持后台压缩的 Codex。
    public var held: [String]

    public init(json: WebJSON) {
        percent = json["percent"]?.int ?? 0
        value = json["value"]?.int ?? 0
        window = json["window"]?.int ?? 0
        setting = TuneSetting(json: json["setting"])
        held = (json["held"]?.array ?? []).map { r in
            let kind = r["kind"]?.string ?? "codex"
            let version = r["version"]?.string ?? ""
            return version.isEmpty ? kind : "\(kind) \(version)"
        }
    }

    public var isApplied: Bool { setting.ours && Int(setting.value) == percent }
    public var canApply: Bool { setting.locked.isEmpty && held.isEmpty && !isApplied && percent > 0 }

    public var text: String {
        if !setting.locked.isEmpty { return "后台压缩：Codex 的 config.toml 里设置了 \(setting.locked)，它优先生效。" }
        if !held.isEmpty { return "后台压缩需要 Codex 0.163 或更新，这些版本还不支持：\(held.joined(separator: "、"))。" }
        if isApplied { return "已在后台于 \(HostToolsFormat.tokensK(value)) 时压缩。" }
        return "Codex 可以在模型窗口的 \(percent)%（约 \(HostToolsFormat.tokensK(value)) / \(HostToolsFormat.tokensK(window))）时在后台压缩，不用等；前台上限保留作兜底。这是 Codex 仍在开发中的功能。"
    }
}

/// 一个 Agent 的建议。
public struct TuneAgent: Hashable, Identifiable, Sendable {
    public var agent: String
    public var calls: Int
    public var advice: [TuneAdvice]
    public var id: String { agent }
    public var name: String { TuneState.agentName(agent) }
}

/// `GET /api/tune` 的结果。
public struct TuneState: Hashable, Sendable {
    public var days: Int
    public var agents: [TuneAgent]

    public init(json: WebJSON) {
        days = json["days"]?.int ?? 7
        agents = (json["agents"]?.array ?? []).compactMap { a in
            guard let name = a["agent"]?.string else { return nil }
            return TuneAgent(agent: name, calls: a["calls"]?.int ?? 0,
                             advice: (a["advice"]?.array ?? []).compactMap { TuneAdvice(agent: name, json: $0) })
        }
    }

    /// 有建议的 Agent。
    public var shown: [TuneAgent] { agents.filter { !$0.advice.isEmpty } }

    /// 「全部应用」会发的修改：可应用的每条建议（不含 Codex 后台压缩这种实验功能）。
    public var applicable: [TuneChange] { shown.flatMap(\.advice).filter(\.canApply).map(\.applyChange) }

    public static func agentName(_ id: String) -> String {
        switch id {
        case "claude": "Claude Code"
        case "codex": "Codex"
        default: id
        }
    }

    /// 允许的天数（主机只认 1...30）。
    public static let dayOptions = [1, 7, 14, 30]
}

/// `POST /api/tune/apply|undo` 的请求。
public struct TuneChange: Hashable, Sendable {
    public var agent: String
    public var knob: String
    public var model: String
    public var value: String

    public init(agent: String, knob: String, model: String, value: String) {
        self.agent = agent
        self.knob = knob
        self.model = model
        self.value = value
    }

    /// 主机按字段名（大小写不敏感）解析 `struct{ Agent, Knob, Model, Value string }`。
    public var body: WebJSON {
        ["agent": .string(agent), "knob": .string(knob), "model": .string(model), "value": .string(value)]
    }

    /// 撤销不需要 value。
    public var undoBody: WebJSON {
        ["agent": .string(agent), "knob": .string(knob), "model": .string(model)]
    }

    /// Codex 后台压缩（async_compact）：值是百分比。
    public static func background(_ a: TuneAsync) -> TuneChange {
        TuneChange(agent: "codex", knob: "async_compact", model: "", value: String(a.percent))
    }
}

extension WebClient {
    /// `GET /api/tune?days=`（1...30）。
    public func tune(days: Int = 7) async throws -> TuneState {
        TuneState(json: try await get("/api/tune", query: [URLQueryItem(name: "days", value: String(min(30, max(1, days))))]))
    }

    /// `POST /api/tune/apply`。
    public func applyTune(_ change: TuneChange) async throws -> TuneSetting {
        TuneSetting(json: try await post("/api/tune/apply", change.body))
    }

    /// `POST /api/tune/undo`。
    public func undoTune(_ change: TuneChange) async throws -> TuneSetting {
        TuneSetting(json: try await post("/api/tune/undo", change.undoBody))
    }
}
