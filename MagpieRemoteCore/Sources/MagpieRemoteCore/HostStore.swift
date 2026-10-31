import Foundation

/// 已添加的主机列表与当前使用的主机。纯值类型，持久化交给 `HostListPersistence`。
public struct HostList: Codable, Equatable, Sendable {
    public private(set) var hosts: [HostProfile]
    public private(set) var activeID: UUID?

    public init(hosts: [HostProfile] = [], activeID: UUID? = nil) {
        self.hosts = hosts
        self.activeID = activeID.flatMap { id in hosts.contains { $0.id == id } ? id : nil } ?? hosts.first?.id
    }

    public var active: HostProfile? { hosts.first { $0.id == activeID } }

    /// 新增或更新（按 id）。第一台主机自动成为当前主机。
    public mutating func upsert(_ host: HostProfile) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        if activeID == nil { activeID = host.id }
    }

    /// 删除主机；删的是当前主机时切到剩下的第一台。
    public mutating func remove(_ id: UUID) {
        hosts.removeAll { $0.id == id }
        if activeID == id { activeID = hosts.first?.id }
    }

    /// 切换当前主机；id 不在列表里时不变，返回 false。
    @discardableResult
    public mutating func activate(_ id: UUID) -> Bool {
        guard hosts.contains(where: { $0.id == id }) else { return false }
        activeID = id
        return true
    }

    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { hosts[$0] }
        var remaining = hosts.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: max(0, min(insertAt, remaining.count)))
        hosts = remaining
    }
}

public protocol HostListPersistence: Sendable {
    func load() -> HostList
    func save(_ list: HostList)
}

/// 主机列表保存在 UserDefaults（只存名称和地址，不含任何密钥）。
public struct UserDefaultsHostListPersistence: HostListPersistence {
    public static let defaultKey = "magpie.remote.hosts.v1"
    public let suiteName: String?
    public let key: String

    public init(suiteName: String? = nil, key: String = Self.defaultKey) {
        self.suiteName = suiteName
        self.key = key
    }

    private var defaults: UserDefaults { suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard }

    public func load() -> HostList {
        guard let data = defaults.data(forKey: key), let list = try? JSONDecoder().decode(HostList.self, from: data) else {
            return HostList()
        }
        return list
    }

    public func save(_ list: HostList) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: key)
    }
}

public final class InMemoryHostListPersistence: HostListPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: HostList

    public init(_ list: HostList = HostList()) { stored = list }

    public func load() -> HostList {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    public func save(_ list: HostList) {
        lock.lock(); defer { lock.unlock() }
        stored = list
    }
}

/// 主机管理：列表 + 密钥。删除主机时一并清掉它在 Keychain 里的密钥。
public struct HostStore: Sendable {
    public let persistence: any HostListPersistence
    public let keychain: any KeychainStore

    public init(persistence: any HostListPersistence, keychain: any KeychainStore) {
        self.persistence = persistence
        self.keychain = keychain
    }

    public func load() -> HostList { persistence.load() }

    @discardableResult
    public func save(_ host: HostProfile, secrets: [HostSecretKind: String?] = [:]) throws -> HostList {
        for (kind, value) in secrets { try keychain.setSecret(value, kind, host: host.id) }
        var list = persistence.load()
        list.upsert(host)
        persistence.save(list)
        return list
    }

    @discardableResult
    public func remove(_ id: UUID) throws -> HostList {
        try keychain.removeAll(host: id)
        var list = persistence.load()
        list.remove(id)
        persistence.save(list)
        return list
    }

    @discardableResult
    public func activate(_ id: UUID) -> HostList {
        var list = persistence.load()
        list.activate(id)
        persistence.save(list)
        return list
    }

    public func secret(_ kind: HostSecretKind, host: UUID) -> String? {
        (try? keychain.secret(kind, host: host)) ?? nil
    }
}
