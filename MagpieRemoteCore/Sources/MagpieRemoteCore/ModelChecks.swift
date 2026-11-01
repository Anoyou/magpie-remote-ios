import Foundation

// 官方设置 › 模型 ›「已停用的模型」（app.js renderDisabledModels，POST /api/settings/disabled-models），
// 以及供应商编辑器里的「测试模型」（逐个模型发一个极小请求，POST /api/provider/test {id, test:[…], run}，
// 「停止」= POST /api/provider/teststop {run}）。文案用官方中文。

// MARK: 停用的模型

public enum DisabledModels {
    /// 「停用模型」那一行的说明（官方原文）。
    public static let explainer = "停用的模型在经过 magpie 的每条路径上都会被拒绝（直接请求、会话、路由组、回退、子 Agent、决策模型），也不会出现在 magpie 的列表和 Agent 的模型选择里。只管经过 magpie 的请求。输入 *fable* 这样的通配符可停用它匹配的所有模型"

    /// 一条规则下面那句（官方：匹配 n 个：前 4 个…；或「目前没有匹配的模型；出现时也会被拒绝」）。
    public static func matches(_ hits: [String]) -> String {
        guard !hits.isEmpty else { return "目前没有匹配的模型；出现时也会被拒绝" }
        return "匹配 \(hits.count) 个：" + hits.prefix(4).joined(separator: ", ") + (hits.count > 4 ? ", …" : "")
    }

    /// 加一条：去掉空白；空的或已有（不分大小写）返回 nil（官方 onPick）。
    public static func adding(_ pattern: String, to list: [String]) -> [String]? {
        let id = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !list.contains(where: { $0.lowercased() == id.lowercased() }) else { return nil }
        return list + [id]
    }

    /// 可选来停用的模型：有供应商的那些（路由组不算），按供应商分组，保持主机的先后。
    public static func choices(_ settings: WebSettings) -> [(provider: String, models: [SettingsModelRef])] {
        var out: [(provider: String, models: [SettingsModelRef])] = []
        for m in settings.titleModels where !m.provider.isEmpty {
            if let i = out.firstIndex(where: { $0.provider == m.providerName }) { out[i].models.append(m) }
            else { out.append((m.providerName, [m])) }
        }
        return out
    }

    public static func body(_ models: [String]) -> WebJSON { ["models": .strings(models)] }
}

extension WebClient {
    /// 整份保存停用列表，回答是整份设置。
    public func setDisabledModels(_ models: [String]) async throws -> WebSettings {
        WebSettings(json: try await post("/api/settings/disabled-models", DisabledModels.body(models)))
    }
}

// MARK: 测试模型

public enum ProviderModelTest {
    /// 「测试模型」测的：Agent 看得到的（开着的）模型。
    public static func models(of provider: WebProvider) -> [String] {
        provider.models.filter(\.on).map(\.id)
    }

    /// 测不了的原因（官方 modelTestWhy，providerJSON.modelTest）；能测时 nil。
    public static func unavailable(_ provider: WebProvider) -> String? {
        switch provider.raw["modelTest"]?.string {
        case "decide": "分类器模型不单独发测试请求：「端点」下的「测试」会向 Jev 端点检测它们。"
        case "own-api": "\(provider.name) 使用自有接口，由 magpie 转换 Agent 的请求，无法单独发测试请求。请在 Agent 中使用该模型测试。"
        default: nil
        }
    }

    public static func body(provider: String, models: [String], run: String) -> WebJSON {
        ["id": .string(provider), "test": .strings(models), "run": .string(run)]
    }

    /// 用时（官方 ledTook）：毫秒 / 秒。
    public static func took(_ ms: Int) -> String {
        ms < 1000 ? "\(ms) 毫秒" : String(format: ms < 10_000 ? "%.1f 秒" : "%.0f 秒", Double(ms) / 1000)
    }

    /// 失败原因：「状态码 · 原因」。
    public static func error(_ r: ProviderTestResult) -> String {
        (r.status > 0 ? "\(r.status) · " : "") + r.error
    }

    /// 一个模型旁边的说明（官方 tested 的 title）。
    public static func detail(_ r: ProviderTestResult) -> String {
        let via = r.api.isEmpty ? "" : r.apiName
        if r.ok { return via.isEmpty ? "\(took(r.millis))内响应" : "通过 \(via) 协议在 \(took(r.millis))内响应" }
        return (via.isEmpty ? "" : via + " · ") + error(r)
    }

    /// 全部测完后的一句话（官方 status）。`ids` 与 `results` 同序。
    public static func summary(ids: [String], results: [ProviderTestResult]) -> (text: String, ok: Bool) {
        let bad = results.filter { !$0.ok }.count
        guard let i = results.firstIndex(where: { !$0.ok }) else { return ("\(ids.count) 个模型全部可用", true) }
        let model = i < ids.count ? ids[i] : results[i].model
        return ("\(ids.count) 个模型中有 \(bad) 个没有响应；\(model)：\(error(results[i]))", false)
    }

    /// 单测一个模型后的一句话。
    public static func one(model: String, _ r: ProviderTestResult) -> String {
        let via = r.api.isEmpty ? "" : r.apiName
        if r.ok { return via.isEmpty ? "\(model) 在 \(took(r.millis))内响应" : "\(model) 通过 \(via) 协议在 \(took(r.millis))内响应" }
        return via.isEmpty ? "\(model) 没有响应：\(error(r))" : "\(model) 通过 \(via) 协议没有响应：\(error(r))"
    }

    /// 「只选可用」：去掉上次测试失败的；测过、通过的和没测的留下（官方 workOn）。返回新选择与去掉了几个。
    public static func workingOnly(_ provider: WebProvider, results: [String: ProviderTestResult]) -> (keep: [String], dropped: Int) {
        let ids = models(of: provider)
        let bad = ids.filter { results[$0].map { !$0.ok } ?? false }
        return (ids.filter { !bad.contains($0) }, bad.count)
    }

    public static func droppedSaid(_ n: Int) -> String {
        n == 1 ? "已取消选中 1 个没有响应的模型" : "已取消选中 \(n) 个没有响应的模型"
    }
}

extension WebClient {
    /// 「测试模型」：每个模型一个极小请求（主机同时测 4 个，最多 3 分钟）。`run` 用来「停止」。
    public func testProviderModels(_ id: String, models: [String], run: String) async throws -> [ProviderTestResult] {
        var request = try makeRequest("/api/provider/test", method: "POST", body: ProviderModelTest.body(provider: id, models: models, run: run))
        request.timeoutInterval = 200
        return (try await send(request)["results"]?.array ?? []).map(ProviderTestResult.init(json:))
    }

    /// 「停止」：结束主机上这次测试（204）。
    public func stopProviderTest(run: String) async throws {
        _ = try await post("/api/provider/teststop", ["run": .string(run)])
    }
}
