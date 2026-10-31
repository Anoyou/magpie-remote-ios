import Foundation
import Observation
import MagpieRemoteCore

enum AppTab: String, Hashable, CaseIterable {
    case quota, usage, chat, manage

    var title: String {
        switch self {
        case .quota: "额度"
        case .usage: "用量"
        case .chat: "对话"
        case .manage: "管理"
        }
    }

    var symbol: String {
        switch self {
        case .quota: "gauge.with.dots.needle.67percent"
        case .usage: "chart.bar.xaxis"
        case .chat: "bubble.left.and.bubble.right"
        case .manage: "slider.horizontal.3"
        }
    }
}

enum AppSheet: String, Identifiable {
    case hosts, guide
    var id: String { rawValue }
}

enum ConnectionState: Equatable {
    case noHost
    case connecting
    case connected(ConnectionReport)
    case failed(MagpieError)
}

@MainActor
@Observable
final class AppModel {
    let environment: AppEnvironment
    private let store: HostStore
    private let service: any RemoteServing

    private(set) var hosts: HostList
    private(set) var connection: ConnectionState = .noHost
    var selectedTab: AppTab = .quota
    var sheet: AppSheet?

    var activeHost: HostProfile? { hosts.active }
    var isFixture: Bool { environment.isFixture }

    init(environment: AppEnvironment) {
        self.environment = environment
        if environment.isFixture {
            let keychain = InMemoryKeychainStore()
            var list = HostList()
            if !environment.fixtureEmpty, let host = HostProfile(name: "示例 Mac", address: "100.64.0.1") {
                list.upsert(host)
                try? keychain.setSecret("sk-magpie-key-EXAMPLE", .gatewayKey, host: host.id)
                try? keychain.setSecret("web-key-EXAMPLE", .webKey, host: host.id)
            }
            store = HostStore(persistence: InMemoryHostListPersistence(list), keychain: keychain)
            service = FixtureRemoteService(offline: environment.fixtureOffline)
        } else {
            store = HostStore(persistence: UserDefaultsHostListPersistence(), keychain: SystemKeychainStore())
            service = LiveRemoteService()
        }
        hosts = store.load()
    }

    func start() async {
        await reconnect()
    }

    /// 重新连接当前主机（切换主机、保存设置、点「重试」后调用）。
    func reconnect() async {
        guard let host = activeHost else {
            connection = .noHost
            return
        }
        connection = .connecting
        do {
            let report = try await service.testConnection(host: host, gatewayKey: store.secret(.gatewayKey, host: host.id))
            guard activeHost?.id == host.id else { return }
            connection = .connected(report)
        } catch {
            guard activeHost?.id == host.id else { return }
            connection = .failed(MagpieError.from(error))
        }
    }

    // MARK: 主机管理

    func hasSecret(_ kind: HostSecretKind, host: UUID) -> Bool {
        store.keychain.hasSecret(kind, host: host)
    }

    /// 保存主机。`secrets` 里只放用户这次填写的密钥：值为 nil 表示清除，没有出现的保持不变。
    func save(_ host: HostProfile, secrets: [HostSecretKind: String?]) throws {
        hosts = try store.save(host, secrets: secrets)
        if host.id == activeHost?.id { Task { await reconnect() } }
    }

    func delete(_ id: UUID) {
        let wasActive = id == activeHost?.id
        hosts = (try? store.remove(id)) ?? store.load()
        if wasActive { Task { await reconnect() } }
    }

    func activate(_ id: UUID) {
        guard id != activeHost?.id else { return }
        hosts = store.activate(id)
        Task { await reconnect() }
    }

    /// 编辑页「测试连接」：优先用刚输入的密钥，没输入则用已保存的。
    func testConnection(_ host: HostProfile, gatewayKey typed: String) async -> Result<ConnectionReport, MagpieError> {
        let key = typed.isEmpty ? store.secret(.gatewayKey, host: host.id) : typed
        do {
            return .success(try await service.testConnection(host: host, gatewayKey: key))
        } catch {
            return .failure(MagpieError.from(error))
        }
    }

    // MARK: 页面数据

    func loadQuota() async throws -> [QuotaItem] {
        guard let host = activeHost else { return [] }
        return try await service.quota(host: host, gatewayKey: store.secret(.gatewayKey, host: host.id))
    }

    func loadUsage() async throws -> [UsageRow] {
        guard let host = activeHost else { return [] }
        return try await service.usage(host: host, webKey: store.secret(.webKey, host: host.id))
    }

    func loadGatewayKeys() async throws -> [GatewayKeySummary] {
        guard let host = activeHost else { return [] }
        return try await service.gatewayKeys(host: host, issuerKey: store.secret(.issuerKey, host: host.id))
    }

    func reply(to messages: [ChatMessage]) async throws -> String {
        guard let host = activeHost else { throw MagpieError.invalidURL }
        return try await service.reply(host: host, gatewayKey: store.secret(.gatewayKey, host: host.id), to: messages)
    }
}
