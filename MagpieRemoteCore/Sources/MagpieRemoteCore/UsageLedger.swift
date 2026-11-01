import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// 「用量 › 请求」的仪表盘：趋势图、排名、热力图，以及一条请求的速度、协议与内容。
// 口径照搬 magpie 网页（internal/gui/assets/plugins/usage/page.js 的 renderLedgerDash / drawLedTrend /
// drawLedHeat / ledDetail，app.js 的 ledSpeed / ledGroupSpeed / cacheHitOf），数据来自
// usageapi.Ledger（网关 /v1/magpie/usage/requests 与网页 /api/usage/requests 同一份 JSON）。
// 热力图与请求内容只有网页接口：GET /api/usage/heatmap、GET /api/usage/requests/content。

/// 排名里的一项（`usageapi.Share`：id、名字、图标加合计）。
public struct UsageShare: Hashable, Sendable, Identifiable, Decodable {
    public var id: String
    public var name: String
    public var icon: String?
    public var totals: UsageTotals

    public init(id: String, name: String, icon: String? = nil, totals: UsageTotals) {
        self.id = id; self.name = name; self.icon = icon; self.totals = totals
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: UsageKey.self)
        id = c.string("id") ?? ""
        name = c.string("name") ?? id
        icon = c.string("icon")
        totals = try UsageTotals(from: decoder)
    }

    /// 给人看的名字（网关密钥里 id 为 `none` 的是没带密钥的本机调用）。
    public var displayName: String {
        if id == "none" && (name.isEmpty || name == "none") { return "未用网关密钥（本机）" }
        if id == "this" && (name.isEmpty || name == "this") { return "这台电脑" }
        return name.isEmpty ? id : name
    }
}

/// 趋势图一个点里某一项的份额（`usage.Part`）。
public struct UsageLedgerPart: Hashable, Sendable, Decodable {
    public var calls = 0
    public var tokens = 0
    public var cost = 0.0
    public var timed = 0
    public var ttftMs = 0
    public var decodeMs = 0
    public var decodeOut = 0

    public init(calls: Int = 0, tokens: Int = 0, cost: Double = 0, decodeMs: Int = 0, decodeOut: Int = 0) {
        self.calls = calls; self.tokens = tokens; self.cost = cost; self.decodeMs = decodeMs; self.decodeOut = decodeOut
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: UsageKey.self)
        calls = c.int("calls"); tokens = c.int("tokens"); cost = c.double("cost")
        timed = c.int("timed"); ttftMs = c.int("ttft_ms"); decodeMs = c.int("decode_ms"); decodeOut = c.int("decode_out")
    }
}

/// 趋势图的一个点（`usage.SeriesPoint`）。
public struct UsageLedgerPoint: Hashable, Sendable, Decodable {
    public var label: String
    public var time: UsageTimestamp?
    public var totals: UsageTotals
    /// 维度 → 项 id → 份额。
    public var by: [String: [String: UsageLedgerPart]]

    public init(label: String, time: UsageTimestamp?, totals: UsageTotals, by: [String: [String: UsageLedgerPart]]) {
        self.label = label; self.time = time; self.totals = totals; self.by = by
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: UsageKey.self)
        label = c.string("label") ?? ""
        time = c.timestamp("time")
        totals = try UsageTotals(from: decoder)
        by = ((try? c.decodeIfPresent([String: [String: UsageLedgerPart]].self, forKey: UsageKey("by"))) ?? nil) ?? [:]
    }
}

/// 趋势图画什么。
public enum UsageTrendMetric: String, CaseIterable, Identifiable, Hashable, Sendable {
    case tokens, cost, calls, speed
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .tokens: "词元"
        case .cost: "花费"
        case .calls: "请求"
        case .speed: "速度"
        }
    }

    /// 合计在这个指标上的值（速度 = 计时回复的输出词元 / 秒）。
    public func value(_ t: UsageTotals) -> Double {
        switch self {
        case .tokens: Double(t.tokens)
        case .cost: t.cost
        case .calls: Double(t.calls)
        case .speed: t.tokensPerSecond ?? 0
        }
    }

    public func value(_ p: UsageLedgerPart) -> Double {
        switch self {
        case .tokens: Double(p.tokens)
        case .cost: p.cost
        case .calls: Double(p.calls)
        case .speed: p.decodeMs > 0 ? Double(p.decodeOut) / (Double(p.decodeMs) / 1000) : 0
        }
    }

    /// 排名里的值：速度取「实测或估算里样本多的那个」（magpie `ledRankValue`）。
    public func rankValue(_ t: UsageTotals) -> Double {
        self == .speed ? (UsageSpeed(t)?.value ?? 0) : value(t)
    }
}

/// 趋势图按什么拆开。
public enum UsageTrendSplit: String, CaseIterable, Identifiable, Hashable, Sendable {
    case model, modelAt, provider, agent, callerKey
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .model: "模型"
        case .modelAt: "模型 · 供应商"
        case .provider: "供应商"
        case .agent: "Agent"
        case .callerKey: "网关密钥"
        }
    }
}

/// 一组回复的输出速度：实测的（首字之后的输出词元 / 秒）与从会话文件估出的下限，样本多的在前（magpie `ledGroupSpeed`）。
public struct UsageSpeed: Hashable, Sendable {
    public var value: Double
    public var isFloor: Bool
    public var samples: Int
    /// 另一个（样本少的）数字。
    public var otherValue: Double?
    public var otherIsFloor = false
    public var otherSamples = 0

    public init?(_ t: UsageTotals) {
        let measured = t.tokensPerSecond.flatMap { $0 > 0 ? $0 : nil }
        let floor = t.floorSpeed.flatMap { $0 > 0 ? $0 : nil }
        switch (measured, floor) {
        case (nil, nil): return nil
        case (let m?, nil): value = m; isFloor = false; samples = t.decodeN
        case (nil, let f?): value = f; isFloor = true; samples = t.floorN
        case (let m?, let f?):
            if t.floorN > t.decodeN {
                value = f; isFloor = true; samples = t.floorN
                otherValue = m; otherIsFloor = false; otherSamples = t.decodeN
            } else {
                value = m; isFloor = false; samples = t.decodeN
                otherValue = f; otherIsFloor = true; otherSamples = t.floorN
            }
        }
    }

    /// 「123 词元/秒」，下限前面加「≥」。
    public var text: String { Self.text(value, floor: isFloor) }
    public var otherText: String? { otherValue.map { Self.text($0, floor: otherIsFloor) } }

    static func text(_ v: Double, floor: Bool) -> String { (floor ? "≥" : "") + "\(Int(v.rounded())) 词元/秒" }
}

/// 趋势图的一层（一个排名项或「其它」）在每个点上的值。
public struct UsageTrendLayer: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var values: [Double]
    public var isOther: Bool { id == UsageTrend.otherID }
}

/// 拆开画的趋势图：前 7 项各一层，其余并成「其它」（magpie `LED_SHOWN`）。
public struct UsageTrend: Hashable, Sendable {
    public static let shown = 7
    public static let otherID = "\u{0}other"

    public var labels: [String]
    public var times: [Date?]
    public var layers: [UsageTrendLayer]
    /// 每个点的总值（速度时是整点的速度，不是各层相加）。
    public var totals: [Double]

    public init(page: UsageRequestPage, metric: UsageTrendMetric, split: UsageTrendSplit) {
        labels = page.series.map(\.label)
        times = page.series.map { $0.time?.date }
        let ranked = page.ranking(split, metric: metric)
        let top = Array(ranked.prefix(Self.shown))
        let topIDs = Set(top.map(\.id))
        var layers = top.map { share in
            UsageTrendLayer(id: share.id, name: share.displayName,
                            values: page.series.map { metric.value($0.by[split.rawValue]?[share.id] ?? UsageLedgerPart()) })
        }
        if metric != .speed {
            let other = page.series.map { point -> Double in
                let named = (point.by[split.rawValue] ?? [:]).filter { topIDs.contains($0.key) }.values.reduce(0) { $0 + metric.value($1) }
                return max(0, metric.value(point.totals) - named)
            }
            if other.contains(where: { $0 > 0.000_001 }) {
                layers.append(UsageTrendLayer(id: Self.otherID, name: "其它", values: other))
            }
        }
        self.layers = layers
        totals = page.series.map { metric.value($0.totals) }
    }

    public var isEmpty: Bool { totals.allSatisfy { $0 <= 0 } }
}

extension UsageRequestPage {
    /// 某个维度的排名，按指标从大到小。
    public func ranking(_ split: UsageTrendSplit, metric: UsageTrendMetric) -> [UsageShare] {
        let list = by[split.rawValue] ?? []
        guard metric != .tokens else { return list }
        return list.enumerated().sorted { a, b in
            let x = metric.rankValue(a.element.totals), y = metric.rankValue(b.element.totals)
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
    }

    /// 成功率（0...1），没有请求时为 nil。
    public var successRate: Double? { totals.calls > 0 ? 1 - Double(totals.errors) / Double(totals.calls) : nil }
}

// MARK: - 一条请求

extension UsageRequestRow {
    /// 从会话文件读到的（网关没经手）。
    public var isFromSessionFile: Bool { source == "log" }

    /// 首字之后的输出速度（词元 / 秒）；判断不了时为 nil（magpie `ledDecode`）。
    public var outputSpeed: Double? {
        guard !failed, let ttft = ttftMs, ttft > 0 else { return nil }
        if reasoningHidden && !((firstTextMs ?? 0) > 0) { return nil }
        let think = reasoning > 0
        let visible = think && !((firstTextMs ?? 0) > 0) && (firstReasoningMs ?? 0) >= ttft && (flowMs ?? 0) > 0 && reasoning <= output
        let n = think && !visible ? output - reasoning : output
        let from = visible ? (firstReasoningMs ?? 0) : think ? (firstTextMs ?? 0) : ttft
        let w = ms - from
        guard n > 0, from > 0, w >= 100, n * 1000 <= 10_000 * w else { return nil }
        if let flow = flowMs, flow > 0, flow * 4 < w { return nil }
        if think, let text = firstTextMs, text > 0, Double(n) * Double(text - ttft) > 20 * Double(reasoning) * Double(w) { return nil }
        if isFromSessionFile && agent == "codex" && (w < 1_000 || n < 100) { return nil }
        return Double(n) / (Double(w) / 1000)
    }

    /// 发给上游用的协议，与 Agent 说的不同时是「A → B」；会话文件里的没有（magpie `ledProtos`）。
    public var protocolText: String? {
        guard let endpoint, !endpoint.isEmpty, !isFromSessionFile else { return nil }
        func proto(_ path: String) -> String {
            if path.range(of: #"/messages\b"#, options: .regularExpression) != nil { return "Anthropic" }
            if path.range(of: #"/responses\b"#, options: .regularExpression) != nil { return "Responses" }
            if path.range(of: #"/chat/completions\b"#, options: .regularExpression) != nil { return "Chat" }
            if path.range(of: #"[gG]enerateContent|/generate\b"#, options: .regularExpression) != nil { return "Gemini" }
            return ""
        }
        let parts = endpoint.components(separatedBy: " → ")
        let from = proto(parts[0])
        let to = parts.count > 1 ? proto(parts[1]) : from
        guard !to.isEmpty else { return nil }
        let start = from.isEmpty ? to : from
        return start == to ? to : "\(start) → \(to)"
    }

    /// 请求在 magpie 里的时间拆分（发给供应商之前）：脱敏、magpie 自己、先失败的尝试、排队、连接与发送、供应商的首字。
    public var timingBreakdown: [(title: String, ms: Int)] {
        guard let ttft = ttftMs, let sent = sentMs else { return [] }
        var out: [(title: String, ms: Int)] = []
        let split = ownMs != nil
        let own = ownMs ?? 0
        let masking = split && (maskingMs ?? 0) > 0 ? min(maskingMs ?? 0, own) : 0
        if masking > 0 { out.append(("脱敏", masking)) }
        out.append(("在 magpie 里", (split ? own : sent) - masking))
        if split {
            if let r = retriedMs, r > 0 { out.append(("先失败的尝试", r)) }
            if let q = queuedMs, q > 0 { out.append(("排队等名额", q)) }
            let sending = sent - own - (retriedMs ?? 0) - (queuedMs ?? 0)
            if sending > 0 { out.append(("连接与发送", sending)) }
        }
        out.append(("供应商首字", max(0, ttft - sent)))
        return out
    }

    /// 读请求内容（`/api/usage/requests/content`）要用的参数；别的电脑上的请求为 nil（magpie `ledLoadContent`）。
    public var contentQuery: [URLQueryItem]? {
        guard computer == nil, let date = time.date else { return nil }
        let session = nativeSession ?? self.session ?? ""
        let fromSessionFile = isFromSessionFile
        let from = fromSessionFile ? date.addingTimeInterval(-0.001) : date.addingTimeInterval(-5)
        let to = fromSessionFile ? date.addingTimeInterval(0.001) : date.addingTimeInterval(Double(ms) / 1000 + 30)
        let at = fromSessionFile ? date : date.addingTimeInterval(Double(ms) / 1000)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [URLQueryItem(name: "agent", value: agent), URLQueryItem(name: "session", value: session),
                URLQueryItem(name: "from", value: f.string(from: from)), URLQueryItem(name: "to", value: f.string(from: to)),
                URLQueryItem(name: "at", value: f.string(from: at))]
    }
}

// MARK: - 热力图

/// `GET /api/usage/heatmap`：最近 53 周、每天一格（只列有调用的日子）。
public struct UsageHeatmap: Hashable, Sendable {
    public struct Day: Hashable, Sendable {
        public var date: String
        public var calls: Int
        public var tokens: Int
        public var cost: Double
        public var unpriced: Int
    }

    public var from: String
    public var to: String
    public var days: [Day]

    public init(json: WebJSON) {
        from = json["from"]?.string ?? ""
        to = json["to"]?.string ?? ""
        days = (json["days"]?.array ?? []).map {
            Day(date: $0["date"]?.string ?? "", calls: $0["calls"]?.int ?? 0, tokens: $0["tokens"]?.int ?? 0,
                cost: $0["cost"]?.double ?? 0, unpriced: $0["unpriced"]?.int ?? 0)
        }
    }

    public var isEmpty: Bool { !days.contains { $0.calls > 0 } }

    /// 按周排好的格子：每列一周（周一在上），从 `from` 到 `to`；不在范围内的为 nil。
    public func weeks() -> [[Day?]] {
        let calendar = Calendar(identifier: .gregorian)
        guard let first = Self.date(from), let last = Self.date(to), first <= last else { return [] }
        let byDate = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
        let weekday = (calendar.component(.weekday, from: first) + 5) % 7 // 周一 = 0
        guard let monday = calendar.date(byAdding: .day, value: -weekday, to: first) else { return [] }
        var weeks: [[Day?]] = []
        var cursor = monday
        while cursor <= last && weeks.count < 60 {
            var week: [Day?] = []
            for _ in 0..<7 {
                let key = Self.key(cursor)
                if cursor < first || cursor > last { week.append(nil) }
                else { week.append(byDate[key] ?? Day(date: key, calls: 0, tokens: 0, cost: 0, unpriced: 0)) }
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86_400)
            }
            weeks.append(week)
        }
        return weeks
    }

    /// 0（没有）到 4 的深浅：按非零值的四分位；少于 8 个时按占最大值的比例（magpie `sessLevels`）。
    public static func levels(_ values: [Double]) -> @Sendable (Double) -> Int {
        let nz = values.filter { $0 > 0 }.sorted()
        guard let most = nz.last else { return { _ in 0 } }
        if nz.count < 8 {
            return { v in v <= 0 ? 0 : min(4, max(1, Int((4 * v / most - 1e-9).rounded(.up)))) }
        }
        func q(_ p: Double) -> Double { nz[min(nz.count - 1, Int(p * Double(nz.count)))] }
        let a = q(0.25), b = q(0.5), c = q(0.75)
        return { v in v <= 0 ? 0 : v >= most ? 4 : v <= a ? 1 : v <= b ? 2 : v <= c ? 3 : 4 }
    }

    /// YYYY-MM-DD → 那天的 0 点（公历、本地时区）。
    public static func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    public static func key(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: - 请求内容

/// `GET /api/usage/requests/content`：从 Agent 的会话文件里读出这次请求说了什么（magpie 不留副本）。
public struct UsageRequestContent: Hashable, Sendable {
    public var found: Bool
    /// 读不到的原因：session（请求没带会话）、agent（只读 Claude Code / Claude Desktop / Codex）、missing（文件里没有）、read（读不了）。
    public var why: String?
    public var model: String?
    public var input: [TranscriptPart]
    public var output: [TranscriptPart]
    public var cut: Bool

    public init(json: WebJSON) {
        found = json["found"]?.bool ?? false
        why = json["why"]?.string
        model = json["model"]?.string
        input = (json["input"]?.array ?? []).enumerated().map { TranscriptPart(index: $0.offset, json: $0.element) }
        output = (json["output"]?.array ?? []).enumerated().map { TranscriptPart(index: 10_000 + $0.offset, json: $0.element) }
        cut = json["cut"]?.bool ?? false
    }

    public var whyText: String {
        switch why {
        case "session": "这次请求没有带会话 id，找不到它的会话文件。"
        case "agent": "magpie 只读 Claude Code、Claude Desktop 和 Codex 的会话文件。"
        case "missing": "Agent 的会话文件里没有这次请求：可能被删了、移走了，或还没写进去。"
        default: "读不了会话文件。"
        }
    }
}

// MARK: - 网页接口

extension WebClient {
    /// `GET /api/usage/heatmap`：与请求记录同样的筛选（不含时间段与某天）。
    public func usageHeatmap(_ query: UsageRequestQuery) async throws -> UsageHeatmap {
        UsageHeatmap(json: try await get("/api/usage/heatmap", query: query.heatmapItems))
    }

    /// `GET /api/usage/requests/content`。
    public func usageRequestContent(_ query: [URLQueryItem]) async throws -> UsageRequestContent {
        UsageRequestContent(json: try await get("/api/usage/requests/content", query: query))
    }
}

extension UsageRequestQuery {
    /// 热力图的参数：筛选条件，去掉时间段、某天与分页（magpie `ledHeatParams`）。
    public var heatmapItems: [URLQueryItem] {
        queryItems.filter { !["period", "day", "offset", "limit"].contains($0.name) }
    }
}

// MARK: - 导出 CSV

/// `GET /api/usage/requests.csv`：筛选后的全部请求（所有页），magpie 网页「导出 CSV」用的同一份文件。
public struct UsageRequestsCSV: Hashable, Sendable {
    public var filename: String
    public var text: String

    public init(filename: String, text: String) { self.filename = filename; self.text = text }

    /// 从 Content-Disposition 取文件名；没有时用 `magpie-requests-<period>.csv`。
    public static func filename(contentDisposition: String?, period: String) -> String {
        if let header = contentDisposition, let range = header.range(of: "filename=") {
            var name = String(header[range.upperBound...])
            if let semicolon = name.firstIndex(of: ";") { name = String(name[..<semicolon]) }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            name = String(name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-_.".unicodeScalars.contains($0) })
            if !name.isEmpty && !name.hasPrefix(".") { return name.hasSuffix(".csv") ? name : name + ".csv" }
        }
        let safe = String(period.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") ? $0 : "-" })
        return "magpie-requests-\(safe).csv"
    }
}

extension WebClient {
    /// `GET /api/usage/requests.csv`（与请求记录同样的筛选，不分页）。
    public func usageRequestsCSV(_ query: UsageRequestQuery) async throws -> UsageRequestsCSV {
        let items = query.queryItems.filter { $0.name != "offset" && $0.name != "limit" }
        var request = try makeRequest("/api/usage/requests.csv", query: items)
        request.setValue("text/csv, application/json;q=0.5", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MagpieError.from(error)
        }
        guard let http = response as? HTTPURLResponse else { throw MagpieError.unreachable(.other) }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"), body: data)
        }
        let name = UsageRequestsCSV.filename(contentDisposition: http.value(forHTTPHeaderField: "Content-Disposition"), period: query.period.rawValue)
        return UsageRequestsCSV(filename: name, text: String(decoding: data, as: UTF8.self))
    }
}
