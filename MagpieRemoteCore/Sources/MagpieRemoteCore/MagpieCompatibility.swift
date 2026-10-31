import Foundation

/// 语义化版本号（只比较 major.minor.patch，忽略 `-beta` 等后缀与前缀 `v`）。
public struct SemanticVersion: Comparable, CustomStringConvertible, Hashable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ text: String) {
        var core = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if core.hasPrefix("v") || core.hasPrefix("V") { core.removeFirst() }
        if let cut = core.firstIndex(where: { $0 == "-" || $0 == "+" || $0 == " " }) { core = String(core[..<cut]) }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            numbers.append(value)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(numbers[0], numbers[1], numbers[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public enum MagpieCompatibility {
    /// App 支持的最低 magpie 版本。
    /// v0.1.2438（提交 80af3b8）是接口契约（contract/gateway-contract.json、contract/web-contract.json）
    /// 生成时所基于、并经实时契约测试验证过的版本；更早的版本未经验证。
    /// contract.yml（每个 PR）与 magpie-compat.yml（每周）会对 magpie 最新发布版再跑一遍契约测试；
    /// 接口出现不兼容变化时，更新 MagpieRemoteCore 后再把这里与 `testedHostVersion` 一起调整。
    public static let minimumHostVersion = SemanticVersion(0, 1, 2438)

    /// 最近一次通过实时契约测试的 magpie 版本（仅作记录，不参与判断；无已知上限）。
    public static let testedHostVersion = SemanticVersion(0, 1, 2438)

    /// 主机报告的版本是否可用；无法解析时视为可用（不因版本号格式阻止使用），由接口层面的错误兜底。
    public static func check(hostVersion: String?) -> MagpieError? {
        guard let hostVersion, let version = SemanticVersion(hostVersion) else { return nil }
        if version < minimumHostVersion {
            return .incompatibleHost(found: hostVersion, required: minimumHostVersion.description)
        }
        return nil
    }
}
