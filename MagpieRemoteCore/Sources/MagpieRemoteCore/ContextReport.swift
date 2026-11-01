import Foundation

// 「用量 › 上下文」：各 Agent 的提示里装了什么、上下文窗口用得怎么样（magpie internal/gui/context.go、
// assets/context.js）。数据来自网关看到的请求（gateway.Route.Prompt），只在 magpie 这台 Mac 的路由历史里。
//
//   GET /api/context?days=N（1...30，其他值按 7）→ {days, agents[], sessions[]}
//
// 「为你调优」部分是 GET /api/tune（HostTune.swift），已有原生页面。

/// 提示里的一类内容（magpie `PARTS`，按这个顺序画）。
public enum ContextPartKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case system, tools, skills, memory, files, results, chat
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: "系统提示"
        case .tools: "工具"
        case .skills: "技能"
        case .memory: "记忆"
        case .files: "文件"
        case .results: "工具结果"
        case .chat: "对话"
        }
    }
    public var note: String {
        switch self {
        case .system: "Agent 自己的指令"
        case .tools: "它能调用的工具的定义"
        case .skills: "它能加载的技能：名字和用途"
        case .memory: "指令文件、记忆和提醒"
        case .files: "它读过的文件和图片"
        case .results: "它调用的其它工具返回的内容"
        case .chat: "你和模型一轮一轮说的话"
        }
    }
}

/// 一项内容：一个工具、一个 MCP 服务的工具、一个指令文件、一个读过的文件、一轮对话。
public struct ContextItem: Hashable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var tag: String
    public var n: Int
    public var tokens: Int

    init(index: Int, json: WebJSON) {
        id = index
        name = json["name"]?.string ?? ""
        tag = json["tag"]?.string ?? ""
        n = json["n"]?.int ?? 0
        tokens = json["tokens"]?.int ?? 0
    }

    /// 给人看的名字（magpie `itemName`）。
    public var title: String {
        switch tag {
        case "turn": return "第 \(name) 轮"
        case "turns": return "更早的 \(n) 轮"
        case "more": return "另外 \(n) 项"
        default: break
        }
        switch name {
        case "prompt": return "Agent 提示"
        case "harness": return "框架消息"
        case "billing": return "计费头"
        case "environment": return "环境说明"
        case "context": return "上下文"
        case "skills": return "技能"
        case "reminders": return "系统提醒"
        case "compacted": return "压缩后的摘要"
        case "image": return "图片"
        case "document": return "文档"
        default: return name
        }
    }

    /// 小标签（MCP、项目、读取…）；没有时为 nil。
    public var tagTitle: String? {
        switch tag {
        case "", "turn", "turns", "more", "compacted": return nil
        case "mcp": return "MCP"
        case "namespace": return "命名空间"
        case "read": return "读取"
        case "shell": return "命令"
        case "result": return "结果"
        case "user": return "用户"
        case "project": return "项目"
        case "local": return "本地"
        case "memory": return "记忆"
        case "skills": return "技能"
        case "reminder": return "提醒"
        case "image": return "图片"
        default: return tag
        }
    }
}

/// 一类内容及其中的各项（`gateway.PromptPart`）。
public struct ContextPart: Hashable, Sendable, Identifiable {
    public var kind: String
    public var tokens: Int
    public var items: [ContextItem]
    public var id: String { kind }
    public var known: ContextPartKind? { ContextPartKind(rawValue: kind) }
    public var title: String { known?.title ?? kind }
}

/// 一次请求的提示（`gateway.Prompt`）。
public struct ContextPrompt: Hashable, Sendable {
    /// 回答的模型的上下文窗口；不知道时为 0。
    public var window: Int
    public var tokens: Int
    /// 词元是供应商数的（否则是按正文估的）。
    public var counted: Bool
    /// 请求引用了之前的回复，那几轮在供应商那里。
    public var held: Bool
    public var turns: Int
    /// 按 magpie 的顺序（系统提示、工具、技能、记忆、文件、工具结果、对话），空的去掉。
    public var parts: [ContextPart]

    public init(json: WebJSON) {
        window = json["window"]?.int ?? 0
        tokens = json["tokens"]?.int ?? 0
        counted = json["counted"]?.bool ?? false
        held = json["held"]?.bool ?? false
        turns = json["turns"]?.int ?? 0
        let raw = (json["parts"]?.array ?? []).map { p in
            ContextPart(kind: p["kind"]?.string ?? "", tokens: p["tokens"]?.int ?? 0,
                        items: (p["items"]?.array ?? []).enumerated().map { ContextItem(index: $0.offset, json: $0.element) })
        }
        let order = ContextPartKind.allCases.map(\.rawValue)
        parts = raw.filter { $0.tokens > 0 }.sorted {
            (order.firstIndex(of: $0.kind) ?? order.count) < (order.firstIndex(of: $1.kind) ?? order.count)
        }
    }

    /// 窗口用了多少（0...1）；不知道窗口时为 nil。
    public var fill: Double? { window > 0 ? min(1, Double(tokens) / Double(window)) : nil }
}

/// 一个会话里一次请求的点。
public struct ContextPoint: Hashable, Sendable, Identifiable {
    public var id: Int64
    public var time: Date?
    public var tokens: Int
    public var window: Int
    /// 其中从供应商缓存读的。
    public var cache: Int
    public var cacheUnknown: Bool
}

/// 一个会话的上下文（`ctxSession`）。
public struct ContextSession: Hashable, Sendable, Identifiable {
    public var agent: String
    public var key: String
    public var title: String
    public var model: String
    public var first: Date?
    public var last: Date?
    public var requests: Int
    /// 最大的一次提示。
    public var peak: Int
    public var window: Int
    public var compacts: Int
    public var latest: ContextPrompt?
    public var latestID: Int64
    public var points: [ContextPoint]

    public var id: String { agent + "\u{0}" + key }
    public var displayTitle: String { title.isEmpty ? String(key.prefix(8)) : title }
    public var peakFill: Double? { window > 0 ? Double(peak) / Double(window) : nil }

    init(json: WebJSON) {
        agent = json["agent"]?.string ?? ""
        key = json["key"]?.string ?? ""
        title = json["title"]?.string ?? ""
        model = json["model"]?.string ?? ""
        first = sessionDate(json["first"])
        last = sessionDate(json["last"])
        requests = json["requests"]?.int ?? 0
        peak = json["peak"]?.int ?? 0
        window = json["window"]?.int ?? 0
        compacts = json["compacts"]?.int ?? 0
        if let latest = json["latest"], !latest.isNull { self.latest = ContextPrompt(json: latest) } else { latest = nil }
        latestID = Int64(json["latestId"]?.double ?? 0)
        points = (json["points"]?.array ?? []).map {
            ContextPoint(id: Int64($0["id"]?.double ?? 0), time: sessionDate($0["time"]), tokens: $0["tokens"]?.int ?? 0,
                         window: $0["window"]?.int ?? 0, cache: $0["cache"]?.int ?? 0, cacheUnknown: $0["cache_unknown"]?.bool ?? false)
        }
    }

    /// 最近一次请求从缓存读的比例；供应商不报告缓存或没有数字时为 nil。
    public var latestCacheShare: Double? {
        guard let last = points.last, latest?.counted == true, last.tokens > 0, !last.cacheUnknown else { return nil }
        return Double(last.cache) / Double(last.tokens)
    }
}

/// 评分的一项（`ctxScore`）。
public struct ContextScore: Hashable, Sendable, Identifiable {
    public var key: String
    public var points: Double
    public var most: Double
    public var id: String { key }
    public var ratio: Double { most > 0 ? points / most : 0 }

    public var title: String {
        switch key {
        case "cache": "缓存"
        case "lean": "起步轻"
        case "pace": "增长慢"
        case "reliable": "可靠"
        default: key
        }
    }
    public var note: String {
        switch key {
        case "cache": "提示里从供应商缓存读的比例：90% 得满分"
        case "lean": "每次请求一开始就带的（系统提示、工具、记忆）占窗口的比例：5% 以内得满分"
        case "pace": "每次请求比上一次多出的部分：窗口的 1% 以内得满分"
        case "reliable": "没有失败的请求：失败 20% 时为 0 分"
        default: ""
        }
    }
}

/// 一个标签（`ctxTag`）：tone 为 good / warn / info。
public struct ContextTag: Hashable, Sendable, Identifiable {
    public var key: String
    public var tone: String
    public var value: Double
    public var id: String { key }

    public var title: String {
        switch key {
        case "cache-friendly": "缓存友好"
        case "cache-misses": "缓存命中少"
        case "lean": "起步轻"
        case "heavy-start": "起步重"
        case "mcp-heavy": "MCP 偏重"
        case "tool-heavy": "工具结果多"
        case "file-reader": "常读文件"
        case "memory-heavy": "记忆偏重"
        case "fills-fast": "涨得快"
        case "near-full": "常接近满"
        case "compacts": "会压缩"
        case "steady": "稳定"
        case "flaky": "不太稳"
        default: key
        }
    }

    public var detail: String {
        let pct = ContextFormat.percent(value)
        let tokens = ContextFormat.tokens(Int(value))
        switch key {
        case "cache-friendly": return "\(pct) 的提示是从供应商缓存读的"
        case "cache-misses": return "只有 \(pct) 的提示从缓存读：每次请求大部分提示都要重新付费"
        case "lean": return "每次请求一开始带 \(tokens) 的系统提示、工具和记忆"
        case "heavy-start": return "还没说一个字，每次请求就先带了 \(tokens) 的系统提示、工具和记忆"
        case "mcp-heavy": return "MCP 服务的工具定义每次请求占 \(tokens)"
        case "tool-heavy": return "工具结果占提示的 \(pct)"
        case "file-reader": return "读过的文件占提示的 \(pct)"
        case "memory-heavy": return "指令文件和记忆占提示的 \(pct)"
        case "fills-fast": return "每次请求比上一次多 \(tokens)（中位数）"
        case "near-full": return "有会话用到了窗口的 \(pct)"
        case "compacts": return "上下文被压缩了 \(Int(value)) 次"
        case "steady": return "失败的请求不到 1%"
        case "flaky": return "\(pct) 的请求失败了"
        default: return key
        }
    }
}

/// 一个 Agent 的上下文卡片（`ctxAgent`）。
public struct ContextAgent: Hashable, Sendable, Identifiable {
    public var agent: String
    public var requests: Int
    public var sessions: Int
    public var errors: Int
    public var calls: Int
    /// 典型（中位数）提示、90% 分位、起步（系统提示 + 工具 + 记忆）、每次增长，词元。
    public var median: Int
    public var p90: Int
    public var baseline: Int
    public var window: Int
    public var cache: Double
    public var growth: Int
    public var peakFill: Double
    public var compacts: Int
    /// 各类内容占提示的比例。
    public var shares: [String: Double]
    public var mcp: Int
    public var score: Int
    public var scores: [ContextScore]
    public var tags: [ContextTag]
    public var models: [String]
    public var latestID: Int64
    public var latestTime: Date?
    /// 「脚本」卡片里只写了 HTTP 库或 SDK 名字的客户端。
    public var clients: [String]

    public var id: String { agent }

    init(json: WebJSON) {
        agent = json["agent"]?.string ?? ""
        requests = json["requests"]?.int ?? 0
        sessions = json["sessions"]?.int ?? 0
        errors = json["errors"]?.int ?? 0
        calls = json["calls"]?.int ?? 0
        median = json["median"]?.int ?? 0
        p90 = json["p90"]?.int ?? 0
        baseline = json["baseline"]?.int ?? 0
        window = json["window"]?.int ?? 0
        cache = json["cache"]?.double ?? 0
        growth = json["growth"]?.int ?? 0
        peakFill = json["peakFill"]?.double ?? 0
        compacts = json["compacts"]?.int ?? 0
        var shares: [String: Double] = [:]
        for (k, v) in json["shares"]?.object ?? [:] { shares[k] = v.double ?? 0 }
        self.shares = shares
        mcp = json["mcp"]?.int ?? 0
        score = json["score"]?.int ?? 0
        scores = (json["scores"]?.array ?? []).map {
            ContextScore(key: $0["key"]?.string ?? "", points: $0["points"]?.double ?? 0, most: $0["most"]?.double ?? 0)
        }
        tags = (json["tags"]?.array ?? []).map {
            ContextTag(key: $0["key"]?.string ?? "", tone: $0["tone"]?.string ?? "info", value: $0["value"]?.double ?? 0)
        }
        models = json["models"]?.strings ?? []
        latestID = Int64(json["latestId"]?.double ?? 0)
        latestTime = sessionDate(json["latestTime"])
        clients = json["clients"]?.strings ?? []
    }

    /// 评分的等级（magpie `grade`）。
    public var grade: ContextGrade { ContextGrade(score) }
    /// 有缓存分时才显示缓存命中。
    public var showsCache: Bool { scores.contains { $0.key == "cache" } && cache > 0 }
    /// 比例 ≥ 1% 的内容，按 magpie 的顺序。
    public var visibleShares: [(kind: ContextPartKind, share: Double)] {
        ContextPartKind.allCases.compactMap { k in
            let v = shares[k.rawValue] ?? 0
            return v >= 0.01 ? (k, v) : nil
        }
    }
}

public enum ContextGrade: String, Hashable, Sendable {
    case great, good, fair, poor
    public init(_ score: Int) {
        self = score >= 85 ? .great : score >= 70 ? .good : score >= 50 ? .fair : .poor
    }
    public var title: String {
        switch self {
        case .great: "很好"
        case .good: "不错"
        case .fair: "一般"
        case .poor: "需要留意"
        }
    }
}

/// 窗口用量的健康度（magpie `health`）：75% 以下正常，90% 以下渐满，再往上接近满。
public enum ContextHealth: String, Hashable, Sendable {
    case ok, warn, bad
    public init(fill: Double) { self = fill < 0.75 ? .ok : fill < 0.9 ? .warn : .bad }
    public var title: String {
        switch self {
        case .ok: "正常"
        case .warn: "渐满"
        case .bad: "接近满"
        }
    }
}

/// `GET /api/context?days=`。
public struct ContextReport: Hashable, Sendable {
    /// 范围：今天 / 7 天 / 30 天（magpie `CTX_RANGES`）。
    public static let dayOptions = [1, 7, 30]

    public var days: Int
    public var agents: [ContextAgent]
    public var sessions: [ContextSession]

    public init(json: WebJSON) {
        days = json["days"]?.int ?? 7
        agents = (json["agents"]?.array ?? []).map(ContextAgent.init(json:))
        sessions = (json["sessions"]?.array ?? []).map(ContextSession.init(json:))
    }

    /// 会话里出现的 Agent（按出现顺序）。
    public var sessionAgents: [String] {
        var seen = Set<String>()
        return sessions.map(\.agent).filter { seen.insert($0).inserted }
    }

    /// 范围的标题。
    public static func dayTitle(_ days: Int) -> String { days == 1 ? "今天" : "\(days) 天" }
}

public enum ContextFormat {
    /// 1234 → 1.2K，1234567 → 1.23M（magpie `fmtK`）。
    public static func tokens(_ n: Int) -> String {
        let n = max(0, n)
        func short(_ x: Double, _ d: Int) -> String {
            var s = String(format: "%.\(d)f", x)
            if s.contains(".") {
                while s.hasSuffix("0") { s.removeLast() }
                if s.hasSuffix(".") { s.removeLast() }
            }
            return s
        }
        if n >= 1_000_000 { return short(Double(n) / 1e6, n >= 10_000_000 ? 1 : 2) + "M" }
        if n >= 1_000 { return short(Double(n) / 1e3, n >= 100_000 ? 0 : 1) + "K" }
        return String(n)
    }

    public static func percent(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
}

extension WebClient {
    /// `GET /api/context?days=`（1...30）。
    public func contextReport(days: Int) async throws -> ContextReport {
        ContextReport(json: try await get("/api/context", query: [URLQueryItem(name: "days", value: String(min(30, max(1, days))))]))
    }
}
