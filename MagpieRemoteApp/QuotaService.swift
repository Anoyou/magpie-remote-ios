import Foundation
import MagpieRemoteCore

// 「额度」页的数据来源：真实主机走 GatewayClient 的额度接口，fixture 模式用 QuotaSamples。

extension LiveRemoteService {
    private func quotaClient(_ host: HostProfile, _ gatewayKey: String?) throws -> GatewayClient {
        guard let gatewayKey, !gatewayKey.isEmpty else { throw MagpieError.missingKey(.gatewayKey) }
        return GatewayClient(baseURL: host.gatewayURL, key: gatewayKey)
    }

    func quotaSnapshot(host: HostProfile, gatewayKey: String?) async throws -> QuotaSnapshot {
        try await quotaClient(host, gatewayKey).quotaSnapshot()
    }

    func quotaHistory(host: HostProfile, gatewayKey: String?, days: Int) async throws -> [QuotaHistorySeries] {
        try await quotaClient(host, gatewayKey).quotaHistory(days: days)
    }

    func refreshQuotas(host: HostProfile, gatewayKey: String?, provider: String?, user: String?) async throws -> [QuotaCard] {
        try await quotaClient(host, gatewayKey).refreshQuotaCards(provider: provider, user: user)
    }
}

/// fixture 下额度页的场景：
/// - 默认：多个订阅 / 套餐 / 余额账号；
/// - `--fixture-quota-empty`：主机上没有任何订阅账号；
/// - `--fixture-key-held`：网关密钥受限，只能看到它自己的限额。
enum QuotaFixtureScenario {
    case normal, empty, keyHeld

    static var current: QuotaFixtureScenario {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--fixture-key-held") { return .keyHeld }
        if arguments.contains("--fixture-quota-empty") { return .empty }
        return .normal
    }
}

extension FixtureRemoteService {
    func quotaSnapshot(host: HostProfile, gatewayKey: String?) async throws -> QuotaSnapshot {
        try await Task.sleep(for: .milliseconds(120))
        if offline { throw MagpieError.unreachable(.timedOut) }
        switch QuotaFixtureScenario.current {
        case .normal: return .cards(QuotaSamples.cards())
        case .empty: return .cards([])
        case .keyHeld: return .keyHeld(QuotaSamples.heldKeyLimit())
        }
    }

    func quotaHistory(host: HostProfile, gatewayKey: String?, days: Int) async throws -> [QuotaHistorySeries] {
        try await Task.sleep(for: .milliseconds(80))
        switch QuotaFixtureScenario.current {
        case .normal: return QuotaSamples.history(days: days)
        case .empty: return []
        case .keyHeld: throw QuotaAccessError.keyHeld
        }
    }

    func refreshQuotas(host: HostProfile, gatewayKey: String?, provider: String?, user: String?) async throws -> [QuotaCard] {
        try await Task.sleep(for: .milliseconds(300))
        switch QuotaFixtureScenario.current {
        case .normal: return QuotaSamples.refreshedCards()
        case .empty: return []
        case .keyHeld: throw QuotaAccessError.keyHeld
        }
    }
}
