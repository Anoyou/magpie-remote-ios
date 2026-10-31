import Foundation
#if canImport(Security)
import Security
#endif

/// 主机密钥的保存位置。App 里用 Keychain，测试和 fixture 模式用内存实现。
public protocol KeychainStore: Sendable {
    func secret(_ kind: HostSecretKind, host: UUID) throws -> String?
    func setSecret(_ value: String?, _ kind: HostSecretKind, host: UUID) throws
    func removeAll(host: UUID) throws
}

extension KeychainStore {
    public func hasSecret(_ kind: HostSecretKind, host: UUID) -> Bool {
        ((try? secret(kind, host: host)) ?? nil).map { !$0.isEmpty } ?? false
    }

    public func removeAll(host: UUID) throws {
        for kind in HostSecretKind.allCases { try setSecret(nil, kind, host: host) }
    }
}

public enum KeychainStoreError: Error, Equatable, Sendable {
    case unavailable
    case status(Int32)
}

/// 测试与 fixture 模式使用：只存在内存里，进程结束即消失。
public final class InMemoryKeychainStore: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init(_ initial: [UUID: [HostSecretKind: String]] = [:]) {
        for (host, secrets) in initial {
            for (kind, value) in secrets { values[Self.key(kind, host)] = value }
        }
    }

    private static func key(_ kind: HostSecretKind, _ host: UUID) -> String { host.uuidString + "/" + kind.rawValue }

    public func secret(_ kind: HostSecretKind, host: UUID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[Self.key(kind, host)]
    }

    public func setSecret(_ value: String?, _ kind: HostSecretKind, host: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        if let value, !value.isEmpty { values[Self.key(kind, host)] = value } else { values[Self.key(kind, host)] = nil }
    }
}

#if canImport(Security)
/// 系统 Keychain：每台主机每种密钥一条 generic password，仅本机、解锁后可读，不随 iCloud 同步。
public struct SystemKeychainStore: KeychainStore {
    public let service: String

    public init(service: String = "MagpieRemote.HostSecrets") {
        self.service = service
    }

    private func query(_ kind: HostSecretKind, _ host: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: host.uuidString + "/" + kind.rawValue,
         kSecAttrSynchronizable as String: false]
    }

    public func secret(_ kind: HostSecretKind, host: UUID) throws -> String? {
        var query = query(kind, host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainStoreError.status(status) }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ value: String?, _ kind: HostSecretKind, host: UUID) throws {
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query(kind, host) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainStoreError.status(status) }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query(kind, host) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(kind, host)
            item.merge(attributes) { _, new in new }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainStoreError.status(added) }
        } else if status != errSecSuccess {
            throw KeychainStoreError.status(status)
        }
    }
}
#endif
