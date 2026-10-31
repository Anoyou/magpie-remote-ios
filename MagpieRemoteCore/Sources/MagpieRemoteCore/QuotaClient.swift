import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 额度相关接口（magpie internal/gateway/gateway.go quotas* 与 key_limit.go）。
public enum QuotaEndpoint {
    public static let cards = "/v1/magpie/quotas/cards"
    public static let quotas = "/v1/magpie/quotas"
    public static let history = "/v1/magpie/quotas/history"
    public static let refresh = "/v1/magpie/quotas/refresh"
    public static let limit = "/v1/magpie/limit"
}

/// 额度接口特有的拒绝（按响应体里的 `error.code` 判断），其余错误仍是 `MagpieError`。
public enum QuotaAccessError: Error, Equatable, Sendable {
    /// `gateway_key_held`：这把密钥受预算 / 模型 / 账号限制，主机不告诉它账号额度。
    case keyHeld
    /// `gateway_key_read_only`：只读密钥不能让主机重新读取。
    case readOnly
    /// 400：这张卡片来自另一台 magpie，这台主机不能重新读取。
    case remoteCard

    public var message: String {
        switch self {
        case .keyHeld: "这把网关密钥受预算、模型或账号限制，主机不向它公开账号额度。"
        case .readOnly: "这是只读密钥，不能让主机重新读取额度；显示的是主机上次读到的数值。"
        case .remoteCard: "这张卡片来自另一台 magpie，只能在那台主机上刷新。"
        }
    }

    /// 从错误响应判断；不是额度特有的拒绝时返回 nil。
    public static func from(status: Int, body: Data) -> QuotaAccessError? {
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let code = error?["code"] as? String
        let message = (error?["message"] as? String ?? String(decoding: body, as: UTF8.self)).lowercased()
        switch (status, code) {
        case (403, "gateway_key_held"): return .keyHeld
        case (403, "gateway_key_read_only"): return .readOnly
        case (400, _) where message.contains("only its own cards"): return .remoteCard
        default: return nil
        }
    }
}

extension GatewayClient {
    /// 发请求；额度特有的 403 / 400 转成 `QuotaAccessError`，其它非 2xx 转成 `MagpieError`。
    func quotaData(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MagpieError.from(error)
        }
        guard let http = response as? HTTPURLResponse else { throw MagpieError.unreachable(.other) }
        guard (200..<300).contains(http.statusCode) else {
            if let special = QuotaAccessError.from(status: http.statusCode, body: data) { throw special }
            throw MagpieError.from(status: http.statusCode, body: data)
        }
        return data
    }

    func quotaDecode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MagpieError.decoding(String(describing: error))
        }
    }

    /// 卡片（只读主机缓存，不会去问供应商，很快）。
    public func quotaCards() async throws -> [QuotaCard] {
        try quotaDecode(QuotaList<QuotaCard>.self, await quotaData(makeRequest(QuotaEndpoint.cards))).data
    }

    /// 全部额度读数。`kept: true` 只取上次读到的值，不去问供应商。
    public func quotaReadings(kept: Bool = true) async throws -> [QuotaCard] {
        let query = kept ? [URLQueryItem(name: "kept", value: "1")] : []
        return try quotaDecode(QuotaList<QuotaCard>.self, await quotaData(makeRequest(QuotaEndpoint.quotas, query: query))).data
    }

    /// 历史曲线；`days` 超过 45 时主机按 45 天处理。
    public func quotaHistory(days: Int, provider: String? = nil, user: String? = nil) async throws -> [QuotaHistorySeries] {
        var query = [URLQueryItem(name: "days", value: String(days))]
        if let provider { query.append(URLQueryItem(name: "provider", value: provider)) }
        if let user { query.append(URLQueryItem(name: "user", value: user)) }
        return try quotaDecode(QuotaList<QuotaHistorySeries>.self, await quotaData(makeRequest(QuotaEndpoint.history, query: query))).data
    }

    /// 让主机重新读取（不带参数 = 所有卡片）。主机 30 秒内对同一账号只真正重读一次，否则直接返回缓存。
    public func refreshQuotaCards(provider: String? = nil, user: String? = nil) async throws -> [QuotaCard] {
        var query: [URLQueryItem] = []
        if let provider { query.append(URLQueryItem(name: "provider", value: provider)) }
        if let user { query.append(URLQueryItem(name: "user", value: user)) }
        var request = try makeRequest(QuotaEndpoint.refresh, method: "POST", query: query)
        // 主机等供应商最多 30 秒。
        request.timeoutInterval = max(timeout, 40)
        return try quotaDecode(QuotaList<QuotaCard>.self, await quotaData(request)).data
    }

    /// 这把密钥自己的限额（受限密钥也能读）。
    public func keyLimit() async throws -> KeyLimit {
        try quotaDecode(KeyLimit.self, await quotaData(makeRequest(QuotaEndpoint.limit)))
    }

    /// 额度页首屏：卡片为主，再用 `quotas?kept=1` 补上卡片里没有的账号（例如只有余额的 API 供应商）；
    /// 密钥受限时改为显示它自己的限额。
    public func quotaSnapshot() async throws -> QuotaSnapshot {
        async let extra = try? quotaReadings(kept: true)
        do {
            let cards = try await quotaCards()
            return .cards(QuotaMerge.merge(cards: cards, readings: await extra ?? []))
        } catch QuotaAccessError.keyHeld {
            _ = await extra
            return .keyHeld(try await keyLimit())
        }
    }
}

public enum QuotaMerge {
    /// 卡片优先；读数里卡片没有的账号追加在后面。
    public static func merge(cards: [QuotaCard], readings: [QuotaCard]) -> [QuotaCard] {
        var seen = Set(cards.map(\.id))
        var result = cards
        for reading in readings where !seen.contains(reading.id) {
            seen.insert(reading.id)
            result.append(reading)
        }
        return result
    }

    /// 单卡刷新后把新卡片换进列表（找不到就保持原样）。
    public static func replacing(_ cards: [QuotaCard], with updated: [QuotaCard]) -> [QuotaCard] {
        let map = Dictionary(updated.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return cards.map { map[$0.id] ?? $0 }
    }
}
