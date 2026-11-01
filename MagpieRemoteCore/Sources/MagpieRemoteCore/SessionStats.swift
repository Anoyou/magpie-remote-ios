import Foundation

// 「用量 › 会话」：按会话看用量（magpie 网页 Usage 页的 Sessions 标签，plugins/usage/page.js renderSessions）。
// 跟「Agent 会话记录」（/api/sessions/manage，管理与删除会话文件）不是一回事：这里是某段时间里各会话花了多少、
// 在哪些项目和模型上、什么时段、调了哪些工具和技能。
//
//   GET /api/sessions                         全部会话（列表：标题、目录、模型、词元、花费…），以及读取目录 dirs
//   GET /api/sessions/stats?days=N            范围内每天按 Agent × 目录 × 模型的用量与活跃时长（0 = 全部）
//   GET /api/sessions/overview?days=&agent=&model=&cwd=   筛选后的会话数、中位数 / p90、每天会话与消息数、
//                                             最费的会话、会话形态、工具与技能

/// 会话标签的时间范围（magpie `SESS_RANGES`）。
public enum SessionRange: String, CaseIterable, Identifiable, Hashable, Sendable {
    case today, week = "7d", month = "30d", quarter = "90d", all
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .today: "今天"
        case .week: "7 天"
        case .month: "30 天"
        case .quarter: "90 天"
        case .all: "全部"
        }
    }
    /// 接口的 days（0 = 全部）。
    public var days: Int {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .all: 0
        }
    }
}

/// 一天里某个 Agent 在某个目录用某个模型花的（`sessions.Usage`）。
public struct SessionUsageRow: Hashable, Sendable {
    public var date: String
    public var agent: String
    public var cwd: String
    public var model: String
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var cost: Double
    public var priced: Bool

    public var inOut: Int { input + output }
}

/// 一天里某个 Agent 在某个目录的活跃时长（`sessions.Active`），hours 是按本地小时拆开的 24 格。
public struct SessionActiveRow: Hashable, Sendable {
    public var date: String
    public var agent: String
    public var cwd: String
    public var seconds: Int
    public var hours: [Int]
}

/// `GET /api/sessions/stats?days=`。
public struct SessionStats: Hashable, Sendable {
    public var from: String
    public var to: String
    public var usage: [SessionUsageRow]
    public var active: [SessionActiveRow]
    /// 范围内在干活的会话（`agent:id`）。
    public var keys: Set<String>?
    /// Agent id → 名字。
    public var agents: [String: String]

    public init(json: WebJSON) {
        from = json["from"]?.string ?? ""
        to = json["to"]?.string ?? ""
        var usage: [SessionUsageRow] = []
        var active: [SessionActiveRow] = []
        for day in json["days"]?.array ?? [] {
            let date = day["date"]?.string ?? ""
            for u in day["usage"]?.array ?? [] {
                usage.append(SessionUsageRow(date: date, agent: u["agent"]?.string ?? "", cwd: u["cwd"]?.string ?? "",
                                             model: u["model"]?.string ?? "", input: u["input"]?.int ?? 0, output: u["output"]?.int ?? 0,
                                             cacheRead: u["cache_read"]?.int ?? 0, cacheWrite: u["cache_write"]?.int ?? 0,
                                             cost: u["cost"]?.double ?? 0, priced: u["priced"]?.bool ?? false))
            }
            for a in day["active"]?.array ?? [] {
                active.append(SessionActiveRow(date: date, agent: a["agent"]?.string ?? "", cwd: a["cwd"]?.string ?? "",
                                               seconds: a["seconds"]?.int ?? 0, hours: (a["hours"]?.array ?? []).map { $0.int ?? 0 }))
            }
        }
        self.usage = usage
        self.active = active
        keys = json["keys"]?.array.map { Set($0.compactMap(\.string)) }
        var agents: [String: String] = [:]
        for (id, name) in json["agents"]?.object ?? [:] { agents[id] = name.string ?? id }
        self.agents = agents
    }

    /// 从 from 到 to 的每一天（YYYY-MM-DD）。
    public var dates: [String] {
        guard let first = UsageHeatmap.date(from), let last = UsageHeatmap.date(to), first <= last else { return [] }
        let calendar = Calendar(identifier: .gregorian)
        var out: [String] = []
        var cursor = first
        while cursor <= last && out.count < 4_000 {
            out.append(UsageHeatmap.key(cursor))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86_400)
        }
        return out
    }
}

/// 一个会话在范围里花的（`sessions.Summary`，「最费的会话」用）。
public struct SessionSummary: Hashable, Sendable, Identifiable {
    public var key: String
    public var agent: String
    public var sessionID: String
    public var cwd: String
    public var title: String
    public var last: Date?
    public var gateway: Bool
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cost: Double
    public var priced: Bool
    /// 秒。
    public var active: Int
    public var models: [String]
    public var prompts: Int
    public var replies: Int
    public var toolCalls: Int

    public var id: String { key.isEmpty ? agent + ":" + sessionID : key }
    public var inOut: Int { input + output }

    public init(json: WebJSON) {
        key = json["key"]?.string ?? ""
        agent = json["agent"]?.string ?? ""
        sessionID = json["id"]?.string ?? ""
        cwd = json["cwd"]?.string ?? ""
        let title = json["title"]?.string ?? ""
        self.title = title.isEmpty ? (json["nickname"]?.string ?? "") : title
        last = sessionDate(json["last"])
        gateway = json["gateway"]?.bool ?? false
        input = json["input"]?.int ?? 0
        output = json["output"]?.int ?? 0
        cacheRead = json["cache_read"]?.int ?? 0
        cost = json["cost"]?.double ?? 0
        priced = json["priced"]?.bool ?? false
        active = json["active"]?.int ?? 0
        models = json["models"]?.strings ?? []
        prompts = json["prompts"]?.int ?? 0
        replies = json["replies"]?.int ?? 0
        toolCalls = json["tool_calls"]?.int ?? 0
    }
}

/// 会话形态：多少会话落在各个区间（`sessions.Shape`）。
public struct SessionShape: Hashable, Sendable {
    public var edges: [Int]
    public var counts: [Int]
    public var total: Int

    public init(json: WebJSON?) {
        edges = (json?["edges"]?.array ?? []).map { $0.int ?? 0 }
        counts = (json?["counts"]?.array ?? []).map { $0.int ?? 0 }
        total = json?["total"]?.int ?? 0
    }

    /// 每个区间的说明（「1–5」、「121+」）。
    public func labels(unit: String = "") -> [String] {
        edges.enumerated().map { i, edge in
            if i + 1 < edges.count {
                let hi = edges[i + 1] - 1
                return hi > edge ? "\(edge)–\(hi)\(unit)" : "\(edge)\(unit)"
            }
            return "\(edge)+\(unit)"
        }
    }
}

/// 工具（或工具类别）的调用次数。
public struct SessionToolStat: Hashable, Sendable, Identifiable {
    public var name: String
    public var category: String
    public var calls: Int
    public var sessions: Int
    public var id: String { name + "|" + category }

    init(json: WebJSON) {
        name = json["name"]?.string ?? ""
        category = json["category"]?.string ?? ""
        calls = json["calls"]?.int ?? 0
        sessions = json["sessions"]?.int ?? 0
    }
}

/// 一个技能的调用（`sessions.Skill`）。
public struct SessionSkill: Hashable, Sendable, Identifiable {
    public var name: String
    public var calls: Int
    public var sessions: Int
    public var last: String
    public var agents: [String: Int]
    public var projects: [SessionToolStat]
    public var id: String { name }

    init(json: WebJSON) {
        name = json["name"]?.string ?? ""
        calls = json["calls"]?.int ?? 0
        sessions = json["sessions"]?.int ?? 0
        last = json["last"]?.string ?? ""
        var agents: [String: Int] = [:]
        for (id, n) in json["agents"]?.object ?? [:] { agents[id] = n.int ?? 0 }
        self.agents = agents
        projects = (json["projects"]?.array ?? []).map(SessionToolStat.init(json:))
    }
}

/// `GET /api/sessions/overview`。
public struct SessionStatsOverview: Hashable, Sendable {
    public var count: Int
    public var median: Int
    public var p90: Int
    /// 每天在干活的会话数（与 stats 的 from...to 一一对应）。
    public var days: [Int]
    public var messages: [Int]
    public var output: [Int]
    /// tokens / cost / active → 最费的会话。
    public var top: [String: [SessionSummary]]
    /// messages / minutes / autonomy。
    public var shape: [String: SessionShape]
    public var toolCalls: Int
    public var toolSessions: Int
    public var tools: [SessionToolStat]
    public var toolCategories: [SessionToolStat]
    public var skillCalls: Int
    public var skillCount: Int
    public var skills: [SessionSkill]

    public init(json: WebJSON) {
        count = json["count"]?.int ?? 0
        median = json["median"]?.int ?? 0
        p90 = json["p90"]?.int ?? 0
        days = (json["days"]?.array ?? []).map { $0.int ?? 0 }
        messages = (json["messages"]?.array ?? []).map { $0.int ?? 0 }
        output = (json["output"]?.array ?? []).map { $0.int ?? 0 }
        var top: [String: [SessionSummary]] = [:]
        for (k, v) in json["top"]?.object ?? [:] { top[k] = (v.array ?? []).map(SessionSummary.init(json:)) }
        self.top = top
        var shape: [String: SessionShape] = [:]
        for (k, v) in json["shape"]?.object ?? [:] { shape[k] = SessionShape(json: v) }
        self.shape = shape
        let tools = json["tools"]
        toolCalls = tools?["calls"]?.int ?? 0
        toolSessions = tools?["sessions"]?.int ?? 0
        self.tools = (tools?["top"]?.array ?? []).map(SessionToolStat.init(json:))
        toolCategories = (tools?["categories"]?.array ?? []).map(SessionToolStat.init(json:))
        let skills = json["skills"]
        skillCalls = skills?["calls"]?.int ?? 0
        skillCount = skills?["count"]?.int ?? 0
        self.skills = (skills?["top"]?.array ?? []).map(SessionSkill.init(json:))
    }
}

/// `GET /api/sessions` 的一行（`sessionJSON`：会话本身加 Agent 名字与图标）。
public struct UsageSessionItem: Hashable, Sendable, Identifiable {
    public var session: AgentSession
    /// 在哪个 Agent 里跑的（Claude Desktop 的 Code 标签在 Claude Code 的目录里，app 是 claude-desktop）。
    public var app: String
    public var agentName: String
    public var icon: String
    public var resume: String

    public var id: String { session.agent + ":" + session.sessionID }

    public init(json: WebJSON) {
        session = AgentSession(json: json)
        let app = json["app"]?.string ?? ""
        self.app = app.isEmpty ? session.agent : app
        agentName = json["name"]?.string ?? session.agent
        icon = json["icon"]?.string ?? ""
        resume = json["resume"]?.string ?? ""
    }
}

/// `GET /api/sessions`。
public struct UsageSessionList: Hashable, Sendable {
    public var sessions: [UsageSessionItem]
    public var dirs: [String]

    public init(json: WebJSON) {
        sessions = (json["sessions"]?.array ?? []).map(UsageSessionItem.init(json:))
        dirs = json["dirs"]?.strings ?? []
    }
}

/// 会话标签的筛选（Agent / 模型 / 文件夹，nil 为全部）。
public struct SessionFilter: Hashable, Sendable {
    public var agent: String?
    public var model: String?
    public var folder: String?
    public var search: String

    public init(agent: String? = nil, model: String? = nil, folder: String? = nil, search: String = "") {
        self.agent = agent; self.model = model; self.folder = folder; self.search = search
    }

    public var isFiltered: Bool { agent != nil || model != nil || folder != nil || !search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// overview 的参数。
    public func overviewQuery(_ range: SessionRange) -> [URLQueryItem] {
        [URLQueryItem(name: "days", value: String(range.days)), URLQueryItem(name: "agent", value: agent ?? ""),
         URLQueryItem(name: "model", value: model ?? ""), URLQueryItem(name: "cwd", value: folder ?? "")]
    }
}

/// 筛选里的一个可选项（按词元从多到少）。
public struct SessionPick: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var tokens: Int
    public var cost: Double
}

/// 每天的图（magpie `SESS_METRICS`）。
public enum SessionMetric: String, CaseIterable, Identifiable, Hashable, Sendable {
    case tokens, output, messages, sessions, cost, active
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .tokens: "词元"
        case .output: "输出"
        case .messages: "消息"
        case .sessions: "会话"
        case .cost: "花费"
        case .active: "活跃"
        }
    }
}

/// 每天的一个点。
public struct SessionDayPoint: Hashable, Sendable, Identifiable {
    public var date: String
    public var input: Int
    public var output: Int
    public var cost: Double
    public var sessions: Int
    public var messages: Int
    public var activeSeconds: Int
    public var id: String { date }

    public func value(_ metric: SessionMetric) -> Double {
        switch metric {
        case .tokens: Double(input + output)
        case .output: Double(output)
        case .messages: Double(messages)
        case .sessions: Double(sessions)
        case .cost: cost
        case .active: Double(activeSeconds)
        }
    }
}

/// 一个范围、一组筛选下算出来的会话标签（magpie 在页面上算的那部分：合计、筛选项、项目与模型排名、时段）。
public struct SessionUsageReport: Hashable, Sendable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public var cost = 0.0
    /// 没有价格的模型（花费里没算）。
    public var unpricedModels: [String] = []
    /// 秒；按模型筛选时 magpie 不分模型记活跃时长，为 nil。
    public var activeSeconds: Int?
    public var activeDays = 0
    public var agents: [SessionPick] = []
    public var models: [SessionPick] = []
    public var folders: [SessionPick] = []
    /// 有用量的行（筛选后）。
    public var hasUsage = false
    public var days: [SessionDayPoint] = []
    /// 周一 = 0 … 周日 = 6，每行 24 小时的活跃秒数；按模型筛选时为 nil。
    public var hours: [[Int]]?

    public init(stats: SessionStats, overview: SessionStatsOverview?, filter: SessionFilter) {
        let byAgent: (String) -> Bool = { filter.agent == nil || $0 == filter.agent }
        let byModel: (String) -> Bool = { filter.model == nil || $0 == filter.model }
        let byFolder: (String) -> Bool = { filter.folder == nil || $0 == filter.folder }

        func picks(_ rows: [SessionUsageRow], _ key: (SessionUsageRow) -> String, name: (String) -> String) -> [SessionPick] {
            var order: [String] = []
            var tokens: [String: Int] = [:]
            var cost: [String: Double] = [:]
            for r in rows {
                let k = key(r)
                guard !k.isEmpty else { continue }
                if tokens[k] == nil { order.append(k) }
                tokens[k, default: 0] += r.inOut
                cost[k, default: 0] += r.cost
            }
            return order.map { SessionPick(id: $0, name: name($0), tokens: tokens[$0] ?? 0, cost: cost[$0] ?? 0) }
                .sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.id < $1.id }
        }
        models = picks(stats.usage.filter { byAgent($0.agent) && byFolder($0.cwd) }, \.model) { $0 }
        folders = picks(stats.usage.filter { byAgent($0.agent) && byModel($0.model) }, \.cwd) { SessionUsageReport.baseName($0) }
        var agentPicks = picks(stats.usage.filter { byModel($0.model) && byFolder($0.cwd) }, \.agent) { stats.agents[$0] ?? $0 }
        for (id, name) in stats.agents.sorted(by: { $0.key < $1.key }) where !agentPicks.contains(where: { $0.id == id }) {
            agentPicks.append(SessionPick(id: id, name: name, tokens: 0, cost: 0))
        }
        agents = agentPicks

        let used = stats.usage.filter { byAgent($0.agent) && byModel($0.model) && byFolder($0.cwd) }
        hasUsage = !used.isEmpty
        var unpriced = Set<String>()
        for r in used {
            input += r.input; output += r.output; cacheRead += r.cacheRead; cacheWrite += r.cacheWrite; cost += r.cost
            if !r.priced { unpriced.insert(r.model) }
        }
        unpricedModels = unpriced.sorted()
        activeDays = Set(used.map(\.date)).count
        let acts = filter.model == nil ? stats.active.filter { byAgent($0.agent) && byFolder($0.cwd) } : nil
        activeSeconds = acts?.reduce(0) { $0 + $1.seconds }

        let dates = stats.dates
        let perDay = overview?.days.count == dates.count ? overview?.days : nil
        let messages = overview?.messages.count == dates.count ? overview?.messages : nil
        var index: [String: Int] = [:]
        days = dates.enumerated().map { i, date in
            index[date] = i
            return SessionDayPoint(date: date, input: 0, output: 0, cost: 0, sessions: perDay?[i] ?? 0,
                                   messages: messages?[i] ?? 0, activeSeconds: 0)
        }
        for r in used { if let i = index[r.date] { days[i].input += r.input; days[i].output += r.output; days[i].cost += r.cost } }
        for a in acts ?? [] { if let i = index[a.date] { days[i].activeSeconds += a.seconds } }

        if let acts {
            let calendar = Calendar(identifier: .gregorian)
            var grid = Array(repeating: Array(repeating: 0, count: 24), count: 7)
            for a in acts where !a.hours.isEmpty {
                guard let date = UsageHeatmap.date(a.date) else { continue }
                let weekday = (calendar.component(.weekday, from: date) + 5) % 7
                for (h, s) in a.hours.prefix(24).enumerated() { grid[weekday][h] += s }
            }
            hours = grid
        }
    }

    public var tokens: Int { input + output }
    /// 缓存命中率：输入不含缓存读写，所以提示 = 输入 + 缓存读 + 缓存写。
    public var cacheHitRate: Double? {
        let prompt = input + cacheRead + cacheWrite
        return prompt > 0 && cacheRead > 0 ? Double(cacheRead) / Double(prompt) : nil
    }

    /// 最忙的时段（周几 0...6，小时 0...23）。
    public var busiestHour: (weekday: Int, hour: Int)? {
        guard let hours else { return nil }
        var best: (weekday: Int, hour: Int)?
        var most = 0
        for (w, row) in hours.enumerated() { for (h, s) in row.enumerated() where s > most { most = s; best = (w, h) } }
        return best
    }

    /// 列表：范围内在干活的会话（有 keys 时按 keys，没有时按最后时间），再按筛选与搜索过滤。
    public static func sessions(_ list: [UsageSessionItem], stats: SessionStats, range: SessionRange, filter: SessionFilter) -> [UsageSessionItem] {
        let from = stats.keys == nil && range.days > 0 ? UsageHeatmap.date(stats.from) : nil
        let words = filter.search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return list.filter { item in
            let s = item.session
            if let agent = filter.agent, item.app != agent { return false }
            if let folder = filter.folder, s.cwd != folder { return false }
            if let model = filter.model, !s.modelNames.contains(model) { return false }
            if let keys = stats.keys {
                if !keys.contains(s.agent + ":" + s.sessionID) { return false }
            } else if let from, let last = s.last, last < from {
                return false
            }
            if !words.isEmpty {
                let hay = ([s.title, s.cwd, s.sessionID, item.agentName] + s.modelNames).joined(separator: "\n").lowercased()
                if !words.allSatisfy({ hay.contains($0) }) { return false }
            }
            return true
        }
    }

    /// 路径最后一段。
    public static func baseName(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }
}

/// 秒 → 「3 小时 12 分」「8 分」「<1 分」。
public func sessionDuration(_ seconds: Int) -> String {
    if seconds <= 0 { return "0" }
    let m = Int((Double(seconds) / 60).rounded())
    if m < 1 { return "<1 分" }
    if m < 60 { return "\(m) 分" }
    return "\(m / 60) 小时 \(m % 60) 分"
}

extension WebClient {
    /// `GET /api/sessions`。
    public func usageSessions() async throws -> UsageSessionList {
        UsageSessionList(json: try await get("/api/sessions"))
    }

    /// `GET /api/sessions/stats?days=`。
    public func sessionStats(_ range: SessionRange) async throws -> SessionStats {
        SessionStats(json: try await get("/api/sessions/stats", query: [URLQueryItem(name: "days", value: String(range.days))]))
    }

    /// `GET /api/sessions/overview`。
    public func sessionStatsOverview(_ range: SessionRange, filter: SessionFilter) async throws -> SessionStatsOverview {
        SessionStatsOverview(json: try await get("/api/sessions/overview", query: filter.overviewQuery(range)))
    }
}
