import Foundation

/// fixture 模式（UI 测试与演示）的「用量」示例数据：确定性生成约 35 天的请求记录，
/// 汇总、分组、筛选与分页都按 magpie 的口径从这些记录算出来。所有名字、地址都是假的。
public struct UsageFixtureData: Sendable {
    public static let heldKeyMessage = "this gateway key is held to a budget, models or accounts, so it is told its own calls alone: GET /v1/magpie/usage/requests"
    static let iPhoneKey = (id: "272a331604f65cb03ee5b6c6", name: "iPhone")
    static let laptopKey = (id: "5d1e0c9a7b3f4e2d8c6a1b0f", name: "工作电脑")

    public let now: Date
    public let timeZone: TimeZone
    /// 新的在前。
    let rows: [UsageRequestRow]

    public init(now: Date = Date(), timeZone: TimeZone = .current) {
        self.now = now
        self.timeZone = timeZone
        self.rows = Self.generate(now: now, timeZone: timeZone)
    }

    private struct Upstream {
        var provider: String, providerName: String, model: String, host: String, access: String, account: String?
        var priceIn: Double, priceOut: Double, priceCache: Double
    }

    private static let upstreams: [Upstream] = [
        .init(provider: "anthropic", providerName: "Anthropic", model: "claude-sonnet-4-6", host: "api.anthropic.example", access: "subscription", account: "me@example.com", priceIn: 3e-6, priceOut: 15e-6, priceCache: 0.3e-6),
        .init(provider: "openai", providerName: "OpenAI", model: "gpt-5", host: "api.openai.example", access: "api", account: nil, priceIn: 1.25e-6, priceOut: 10e-6, priceCache: 0.125e-6),
        .init(provider: "deepseek", providerName: "DeepSeek", model: "deepseek-chat", host: "api.deepseek.example", access: "api", account: nil, priceIn: 0.27e-6, priceOut: 1.1e-6, priceCache: 0.07e-6),
        .init(provider: "google", providerName: "Google", model: "gemini-2.5-pro", host: "generativelanguage.example", access: "api", account: nil, priceIn: 1.25e-6, priceOut: 10e-6, priceCache: 0.31e-6),
    ]

    private static func generate(now: Date, timeZone: TimeZone) -> [UsageRequestRow] {
        var seed: UInt64 = 0x5EED_1234
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        var rows: [UsageRequestRow] = []
        var time = now.addingTimeInterval(-45)
        let oldest = now.addingTimeInterval(-35 * 86_400)
        var index = 0
        while time > oldest {
            let agentPick = next(10)
            var agent = "MagpieRemote"
            var agentName = "MagpieRemote"
            var keyID: String? = iPhoneKey.id
            var keyName: String? = iPhoneKey.name
            if agentPick < 5 {
                agent = "claude"; agentName = "Claude Code"; keyID = nil; keyName = nil
            } else if agentPick < 8 {
                agent = "codex"; agentName = "Codex"; keyID = laptopKey.id; keyName = laptopKey.name
            }
            let upstreamIndex: Int
            if agent == "claude" { upstreamIndex = next(4) == 0 ? 2 : 0 } else { upstreamIndex = next(upstreams.count) }
            let upstream = upstreams[upstreamIndex]
            let input = 400 + next(24_000)
            let cacheRead = upstream.provider == "anthropic" ? next(80_000) : next(4_000)
            let cacheWrite = next(5) == 0 ? next(6_000) : 0
            var output = 60 + next(3_500)
            var status = 200
            var error: String?
            var errorType: String?
            var tries = 1
            if index % 13 == 5 {
                status = 502; error = "\(upstream.provider)/\(upstream.model): upstream timed out"; errorType = "timeout"; tries = 2
            } else if index % 19 == 11 {
                status = 429; error = "\(upstream.provider)/\(upstream.model): rate limited by the upstream"; errorType = "rate_limit"; tries = 3
            } else if index % 9 == 2 {
                tries = 2
            }
            let failed = status >= 400
            if failed { output = 0 }
            var cost = 0.0
            if !failed {
                cost = Double(input) * upstream.priceIn + Double(output) * upstream.priceOut
                    + Double(cacheRead) * upstream.priceCache + Double(cacheWrite) * upstream.priceIn * 1.25
            }
            let ms: Int
            if failed { ms = status == 502 ? 30_012 : 420 } else { ms = 800 + next(14_000) }
            let requested = agent == "MagpieRemote" && index % 3 == 0 ? "group/coding" : "\(upstream.provider)/\(upstream.model)"
            let endpoint = agent == "claude" ? "/v1/messages" : agent == "codex" ? "/v1/responses" : "/v1/chat/completions"
            let session: String? = agent == "claude" ? "5f0e7c1a-\(index / 25)" : agent == "MagpieRemote" ? "ios-7E1C5A40" : nil
            let reasoning = upstream.provider == "openai" && !failed ? next(900) : 0
            let ttft: Int? = failed ? nil : 300 + next(1_500)
            let routeId: Int64 = 1_793_472_000_000 - Int64(index) * 37
            let row = UsageRequestRow(
                time: UsageTimestamp(date: time, timeZone: timeZone), routeId: routeId,
                agent: agent, agentName: agentName,
                provider: upstream.provider, providerName: upstream.providerName, host: upstream.host,
                providerAccount: upstream.account, callerKeyId: keyID, callerKeyName: keyName,
                model: upstream.model, requested: requested,
                input: failed ? 0 : input, output: output, cacheRead: failed ? 0 : cacheRead, cacheWrite: failed ? 0 : cacheWrite,
                reasoning: reasoning, ms: ms, ttftMs: ttft, status: status,
                error: error, errorType: errorType, tries: tries,
                endpoint: endpoint, session: session,
                cost: cost, priced: true, access: upstream.access)
            rows.append(row)
            index += 1
            // 最近的十几条间隔几分钟，之后平均一个多小时一条。
            let gap: Int = index < 15 ? 60 + next(240) : 600 + next(7_800)
            time = time.addingTimeInterval(-Double(gap))
        }
        return rows
    }

    // MARK: 时间段

    func start(of period: UsagePeriod) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        switch period {
        case .today: return today
        case .week: return calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .month: return calendar.date(byAdding: .day, value: -29, to: today) ?? today
        case .all: return rows.last?.time.date ?? today
        }
    }

    func rows(in period: UsagePeriod, heldKey: Bool) -> [UsageRequestRow] {
        let since = start(of: period)
        return rows.filter { ($0.time.date ?? now) >= since && (!heldKey || $0.callerKeyId == Self.iPhoneKey.id) }
    }

    static func totals(_ row: UsageRequestRow) -> UsageTotals {
        var t = UsageTotals()
        t.calls = 1
        t.errors = row.failed ? 1 : 0
        t.retried = row.retried && !row.failed ? 1 : 0
        t.input = row.input; t.output = row.output; t.cacheRead = row.cacheRead; t.cacheWrite = row.cacheWrite
        t.reasoning = row.reasoning
        t.cost = row.cost
        t.unpriced = row.priced ? 0 : 1
        if let ttft = row.ttftMs {
            t.timed = 1; t.ttftMs = ttft; t.decodeMs = max(1, row.ms - ttft); t.decodeOut = row.output; t.decodeN = 1
        }
        return t
    }

    private static func group(_ rows: [UsageRequestRow], by key: (UsageRequestRow) -> String?) -> [(String, [UsageRequestRow])] {
        var order: [String] = []
        var map: [String: [UsageRequestRow]] = [:]
        for row in rows {
            guard let k = key(row) else { continue }
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(row)
        }
        return order.map { ($0, map[$0]!) }
    }

    private static func sum(_ rows: [UsageRequestRow]) -> UsageTotals {
        rows.reduce(UsageTotals()) { $0 + totals($1) }
    }

    // MARK: 汇总

    public func summary(_ period: UsagePeriod) -> UsageSummary {
        let rows = rows(in: period, heldKey: false)
        let since = start(of: period)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var series: [UsagePoint] = []
        let hourly = period == .today
        var cursor = hourly ? since : calendar.startOfDay(for: since)
        let label = DateFormatter()
        label.locale = Locale(identifier: "en_US_POSIX")
        label.timeZone = timeZone
        label.dateFormat = hourly ? "HH" : "MMM d"
        while cursor <= now {
            guard let end = calendar.date(byAdding: hourly ? .hour : .day, value: 1, to: cursor) else { break }
            let start = cursor
            let inBucket = rows.filter { guard let d = $0.time.date else { return false }; return d >= start && d < end }
            series.append(UsagePoint(label: label.string(from: cursor), time: UsageTimestamp(date: cursor, timeZone: timeZone), totals: Self.sum(inBucket)))
            cursor = end
        }
        let models = Self.group(rows) { "\($0.provider)/\($0.model)" }.map { id, rs in
            UsageGroup(id: id, name: rs[0].model, sub: rs[0].providerName, provider: rs[0].provider, model: rs[0].model, totals: Self.sum(rs))
        }
        let agents = Self.group(rows) { $0.agent }.map { id, rs in UsageGroup(id: id, name: rs[0].agentName, totals: Self.sum(rs)) }
        let accounts = Self.group(rows) { r in r.providerAccount.map { "\(r.provider)|\($0)" } }.map { id, rs in
            UsageGroup(id: id, name: "工作订阅", sub: rs[0].providerName, provider: rs[0].provider, account: rs[0].providerAccount, totals: Self.sum(rs))
        }
        let callerKeys = Self.group(rows) { $0.callerKeyId ?? "none" }.map { id, rs in
            id == "none" ? UsageGroup(id: "none", name: "none", totals: Self.sum(rs))
                : UsageGroup(id: id, name: rs[0].callerKeyName, callerKeyId: id, callerKeyName: rs[0].callerKeyName, totals: Self.sum(rs))
        }
        let providerKeys = Self.group(rows.filter { $0.access == "api" }) { "\($0.provider)#9bf109433b" }.map { id, rs in
            UsageGroup(id: id, name: nil, provider: rs[0].provider, providerKeyId: "9bf109433b", providerKeyName: "main", totals: Self.sum(rs))
        }
        return UsageSummary(period: period.rawValue, since: UsageTimestamp(date: since, timeZone: timeZone), totals: Self.sum(rows),
                            bucket: hourly ? "hour" : "day", series: series, agents: agents, models: models, accounts: accounts,
                            callerKeys: callerKeys, providerKeys: providerKeys,
                            sessionCount: Set(rows.compactMap(\.session)).count)
    }

    // MARK: 请求记录

    public func requests(_ query: UsageRequestQuery, heldKey: Bool = false) -> UsageRequestPage {
        let q = query.trimmedSearch.lowercased()
        let matching = rows(in: query.period, heldKey: heldKey).filter { row in
            if query.failedOnly && !row.failed { return false }
            if query.retriedOnly && !(row.retried && !row.failed) { return false }
            if let model = query.model, row.model != model { return false }
            if let agent = query.agent, row.agent != agent { return false }
            if let key = query.callerKey, (row.callerKeyId ?? "none") != key { return false }
            if let provider = query.provider, row.provider != provider { return false }
            if let account = query.account, row.providerAccount != account { return false }
            if !q.isEmpty {
                let haystack = [row.model, row.requested ?? "", row.provider, row.host ?? "", row.session ?? ""].joined(separator: " ").lowercased()
                if !haystack.contains(q) { return false }
            }
            return true
        }
        let offset = min(max(0, query.offset), matching.count)
        let limit = min(max(1, query.limit), UsageRequestQuery.maxLimit)
        let page = Array(matching[offset..<min(matching.count, offset + limit)])
        func options(_ key: (UsageRequestRow) -> String?, _ name: (UsageRequestRow) -> String) -> [UsageOption] {
            Self.group(matching, by: key).map { UsageOption(id: $0.0, name: name($0.1[0])) }
        }
        var result = UsageRequestPage(
            period: query.period.rawValue, rows: page, offset: offset, total: matching.count, totals: Self.sum(matching),
            callerKeys: options({ $0.callerKeyId ?? "none" }, { $0.callerKeyName ?? "未用网关密钥（本机）" }),
            agents: options({ $0.agent }, { $0.agentTitle }),
            providers: options({ $0.provider }, { $0.providerTitle ?? $0.provider }),
            models: options({ $0.model }, { $0.model }),
            accounts: options({ $0.providerAccount }, { _ in "工作订阅" }))
        // 趋势图与排名：与 magpie 一样，按小时（今天）或按天，每个点再按维度拆开；排名按词元从多到少。
        typealias Key = (String, (UsageRequestRow) -> String, (UsageRequestRow) -> String)
        let keys: [Key] = [
            ("model", { $0.model }, { $0.model }),
            ("modelAt", { "\($0.provider)/\($0.model)" }, { "\($0.model) · \($0.providerTitle ?? $0.provider)" }),
            ("provider", { $0.provider }, { $0.providerTitle ?? $0.provider }),
            ("agent", { $0.agent }, { $0.agentTitle }),
            ("callerKey", { $0.callerKeyId ?? "none" }, { $0.callerKeyName ?? "none" }),
        ]
        var by: [String: [UsageShare]] = [:]
        for (dim, key, name) in keys {
            by[dim] = Self.group(matching, by: key).map { UsageShare(id: $0.0, name: name($0.1[0]), totals: Self.sum($0.1)) }
                .sorted { $0.totals.tokens != $1.totals.tokens ? $0.totals.tokens > $1.totals.tokens : $0.id < $1.id }
        }
        result.by = by
        let summary = self.summary(query.period)
        result.bucket = summary.bucket ?? "day"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let hourly = query.period == .today
        result.series = summary.series.map { point in
            let start = point.time?.date ?? now
            let end = calendar.date(byAdding: hourly ? .hour : .day, value: 1, to: start) ?? start
            let inBucket = matching.filter { guard let d = $0.time.date else { return false }; return d >= start && d < end }
            var parts: [String: [String: UsageLedgerPart]] = [:]
            for (dim, key, _) in keys {
                var m: [String: UsageLedgerPart] = [:]
                for row in inBucket {
                    let t = Self.totals(row)
                    var part = m[key(row)] ?? UsageLedgerPart()
                    part.calls += 1; part.tokens += row.tokens; part.cost += row.cost
                    part.timed += t.timed; part.ttftMs += t.ttftMs; part.decodeMs += t.decodeMs; part.decodeOut += t.decodeOut
                    m[key(row)] = part
                }
                parts[dim] = m
            }
            return UsageLedgerPoint(label: point.label, time: point.time, totals: Self.sum(inBucket), by: parts)
        }
        result.through = result.totals
        return result
    }

    // MARK: 并发

    public func concurrency() -> ConcurrencySnapshot {
        ConcurrencySnapshot(
            requests: 3, waiting: 1, tools: 0,
            lanes: [ConcurrencyLane(id: "anthropic", busy: 2, waiting: 1, limit: 2),
                    ConcurrencyLane(id: "deepseek#9bf109433b", busy: 1, waiting: 0, limit: 4)],
            active: [ActiveRequest(id: 1201, agent: "claude", model: "claude-sonnet-4-6", provider: "anthropic", ms: 5_320, phase: "upstream"),
                     ActiveRequest(id: 1202, agent: "claude", model: nil, provider: nil, ms: 2_426, phase: "slot"),
                     ActiveRequest(id: 1203, agent: "MagpieRemote", model: "deepseek-chat", provider: "deepseek", ms: 530, phase: "upstream")])
    }
}
