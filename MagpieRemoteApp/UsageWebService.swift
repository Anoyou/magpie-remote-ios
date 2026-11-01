import Foundation
import MagpieRemoteCore

/// 「用量」页里只有 magpie 网页接口（3430，Web 密钥）才有的部分：请求的热力图、内容与 CSV，「会话」与「上下文」两个标签。
/// 跟「管理」类页面共用 `ManageStore` 的主机与 Web 密钥。
protocol UsageWebServing: Sendable {
    func heatmap(_ query: UsageRequestQuery) async throws -> UsageHeatmap
    func requestContent(_ row: UsageRequestRow) async throws -> UsageRequestContent
    func requestsCSV(_ query: UsageRequestQuery) async throws -> UsageRequestsCSV
    func sessions() async throws -> UsageSessionList
    func sessionStats(_ range: SessionRange) async throws -> SessionStats
    func sessionOverview(_ range: SessionRange, filter: SessionFilter) async throws -> SessionStatsOverview
    func context(days: Int) async throws -> ContextReport
}

enum UsageWebServices {
    static func make(from service: (any ManageServing)?) -> (any UsageWebServing)? {
        if let live = service as? LiveManageService {
            // 第一次读会话文件、算上下文都可能要一会儿。
            return LiveUsageWebService(web: WebClient(baseURL: live.web.baseURL, key: live.web.key, timeout: 60))
        }
        if service is FixtureManageService { return FixtureUsageWebService() }
        return nil
    }
}

struct LiveUsageWebService: UsageWebServing {
    let web: WebClient

    func heatmap(_ query: UsageRequestQuery) async throws -> UsageHeatmap { try await web.usageHeatmap(query) }
    func requestContent(_ row: UsageRequestRow) async throws -> UsageRequestContent {
        guard let query = row.contentQuery else { return UsageRequestContent(json: ["found": false, "why": "session"]) }
        return try await web.usageRequestContent(query)
    }
    func requestsCSV(_ query: UsageRequestQuery) async throws -> UsageRequestsCSV { try await web.usageRequestsCSV(query) }
    func sessions() async throws -> UsageSessionList { try await web.usageSessions() }
    func sessionStats(_ range: SessionRange) async throws -> SessionStats { try await web.sessionStats(range) }
    func sessionOverview(_ range: SessionRange, filter: SessionFilter) async throws -> SessionStatsOverview {
        try await web.sessionStatsOverview(range, filter: filter)
    }
    func context(days: Int) async throws -> ContextReport { try await web.contextReport(days: days) }
}

/// fixture 模式：示例数据（UsageTabsFixtureData），请求记录的 CSV 由示例请求拼出来。
struct FixtureUsageWebService: UsageWebServing {
    private var data: UsageTabsFixtureData { UsageTabsFixtureData() }
    private func pause() async throws { try await Task.sleep(for: .milliseconds(80)) }

    func heatmap(_ query: UsageRequestQuery) async throws -> UsageHeatmap {
        try await pause()
        return UsageHeatmap(json: data.heatmap())
    }

    func requestContent(_ row: UsageRequestRow) async throws -> UsageRequestContent {
        try await pause()
        return UsageRequestContent(json: data.requestContent(agent: row.agent))
    }

    func requestsCSV(_ query: UsageRequestQuery) async throws -> UsageRequestsCSV {
        try await pause()
        var q = query
        q.offset = 0
        q.limit = UsageRequestQuery.maxLimit
        let page = UsageFixtureStore.data.requests(q, heldKey: UsageFixtureStore.heldKey)
        let lines = page.rows.map { row in
            [row.time.raw, row.agentTitle, row.model, row.providerTitle ?? "", String(row.input), String(row.output),
             String(format: "%.6f", row.cost), String(row.ms), String(row.status)].map { "\"\($0)\"" }.joined(separator: ",")
        }
        return UsageRequestsCSV(filename: UsageRequestsCSV.filename(contentDisposition: nil, period: query.period.rawValue),
                                text: (["time,agent,model,provider,in,out,cost,ms,status"] + lines).joined(separator: "\n") + "\n")
    }

    func sessions() async throws -> UsageSessionList {
        try await pause()
        return UsageSessionList(json: data.sessionList())
    }

    func sessionStats(_ range: SessionRange) async throws -> SessionStats {
        try await pause()
        return SessionStats(json: data.sessionStats(range))
    }

    func sessionOverview(_ range: SessionRange, filter: SessionFilter) async throws -> SessionStatsOverview {
        try await pause()
        return SessionStatsOverview(json: data.sessionOverview(range, filter: filter))
    }

    func context(days: Int) async throws -> ContextReport {
        try await pause()
        return ContextReport(json: data.context(days: days))
    }
}
