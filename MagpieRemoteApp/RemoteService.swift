import Foundation
import MagpieRemoteCore

/// 页面通过它访问主机；真实实现走 `GatewayClient`，fixture 实现返回固定的示例数据。
protocol RemoteServing: UsageServing, Sendable {
    func testConnection(host: HostProfile, gatewayKey: String?) async throws -> ConnectionReport
    func quotaSnapshot(host: HostProfile, gatewayKey: String?) async throws -> QuotaSnapshot
    func quotaHistory(host: HostProfile, gatewayKey: String?, days: Int) async throws -> [QuotaHistorySeries]
    func refreshQuotas(host: HostProfile, gatewayKey: String?, provider: String?, user: String?) async throws -> [QuotaCard]
    func gatewayKeys(host: HostProfile, issuerKey: String?) async throws -> [GatewayKeySummary]
    func chatModels(host: HostProfile, gatewayKey: String?) async throws -> ModelCatalog
    func chatStream(host: HostProfile, gatewayKey: String?, request: ChatCompletionRequest, sessionID: UUID) -> AsyncThrowingStream<ChatStreamEvent, any Error>
}

struct LiveRemoteService: RemoteServing {
    func testConnection(host: HostProfile, gatewayKey: String?) async throws -> ConnectionReport {
        try await GatewayClient(baseURL: host.gatewayURL, key: gatewayKey).testConnection()
    }

    // TODO(spec): 以下接口的路径与 JSON 形状等 spec/ 契约确定后接入；在此之前页面显示「接入中」的空状态。
    func gatewayKeys(host: HostProfile, issuerKey: String?) async throws -> [GatewayKeySummary] { [] }

    func chatModels(host: HostProfile, gatewayKey: String?) async throws -> ModelCatalog {
        guard let gatewayKey, !gatewayKey.isEmpty else { throw MagpieError.missingKey(.gatewayKey) }
        return try await GatewayClient(baseURL: host.gatewayURL, key: gatewayKey).chatModels()
    }

    func chatStream(host: HostProfile, gatewayKey: String?, request: ChatCompletionRequest, sessionID: UUID) -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        guard let gatewayKey, !gatewayKey.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: MagpieError.missingKey(.gatewayKey)) }
        }
        return GatewayClient(baseURL: host.gatewayURL, key: gatewayKey).chatStream(request, sessionID: sessionID)
    }
}

/// fixture 模式：所有数据都是明显的示例值，不会访问网络。
struct FixtureRemoteService: RemoteServing {
    var offline: Bool

    func testConnection(host: HostProfile, gatewayKey: String?) async throws -> ConnectionReport {
        try await Task.sleep(for: .milliseconds(150))
        if offline { throw MagpieError.unreachable(.timedOut) }
        guard let gatewayKey, !gatewayKey.isEmpty else { throw MagpieError.missingKey(.gatewayKey) }
        return ConnectionReport(hostVersion: "0.0.0-fixture", modelCount: 3, latency: .milliseconds(42))
    }

    func gatewayKeys(host: HostProfile, issuerKey: String?) async throws -> [GatewayKeySummary] {
        [GatewayKeySummary(id: "k1", name: "iPhone", masked: "sk-magpie-…EXMP", enabled: true),
         GatewayKeySummary(id: "k2", name: "旧电脑", masked: "sk-magpie-…OLD0", enabled: false)]
    }

    func chatModels(host: HostProfile, gatewayKey: String?) async throws -> ModelCatalog {
        try await Task.sleep(for: .milliseconds(100))
        return FixtureChat.catalog
    }

    func chatStream(host: HostProfile, gatewayKey: String?, request: ChatCompletionRequest, sessionID: UUID) -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        FixtureChat.stream(for: request)
    }
}
