import Foundation
import MagpieRemoteCore

/// 「用量」页访问主机的接口（`RemoteServing` 继承它）。都走网关（3425 端口，Bearer 网关密钥）。
protocol UsageServing: Sendable {
    func usageSummary(host: HostProfile, gatewayKey: String?, period: UsagePeriod) async throws -> UsageAccess<UsageSummary>
    func usageRequests(host: HostProfile, gatewayKey: String?, query: UsageRequestQuery) async throws -> UsageRequestPage
    func concurrency(host: HostProfile, gatewayKey: String?) async throws -> UsageAccess<ConcurrencySnapshot>
}

extension LiveRemoteService {
    func usageSummary(host: HostProfile, gatewayKey: String?, period: UsagePeriod) async throws -> UsageAccess<UsageSummary> {
        try await GatewayClient(baseURL: host.gatewayURL, key: gatewayKey).usageSummary(period: period)
    }

    func usageRequests(host: HostProfile, gatewayKey: String?, query: UsageRequestQuery) async throws -> UsageRequestPage {
        try await GatewayClient(baseURL: host.gatewayURL, key: gatewayKey).usageRequests(query)
    }

    func concurrency(host: HostProfile, gatewayKey: String?) async throws -> UsageAccess<ConcurrencySnapshot> {
        try await GatewayClient(baseURL: host.gatewayURL, key: gatewayKey).concurrency()
    }
}

/// fixture 模式的用量数据：启动时生成一次（约 35 天的示例请求）。
/// 启动参数 `--fixture-held-key` 模拟受限密钥：看不到汇总与并发，只能看自己的请求记录。
enum UsageFixtureStore {
    static let data = UsageFixtureData()
    static var heldKey: Bool { ProcessInfo.processInfo.arguments.contains("--fixture-held-key") }
}

extension FixtureRemoteService {
    func usageSummary(host: HostProfile, gatewayKey: String?, period: UsagePeriod) async throws -> UsageAccess<UsageSummary> {
        try await Task.sleep(for: .milliseconds(80))
        if UsageFixtureStore.heldKey { return .held(message: UsageFixtureData.heldKeyMessage) }
        return .available(UsageFixtureStore.data.summary(period))
    }

    func usageRequests(host: HostProfile, gatewayKey: String?, query: UsageRequestQuery) async throws -> UsageRequestPage {
        try await Task.sleep(for: .milliseconds(80))
        return UsageFixtureStore.data.requests(query, heldKey: UsageFixtureStore.heldKey)
    }

    func concurrency(host: HostProfile, gatewayKey: String?) async throws -> UsageAccess<ConcurrencySnapshot> {
        if UsageFixtureStore.heldKey { return .held(message: UsageFixtureData.heldKeyMessage) }
        return .available(UsageFixtureStore.data.concurrency())
    }
}
