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
    /// TODO(spec): 以 spec/ 中确定的接口契约首次出现的 magpie 版本为准，contract.yml 会校验。
    public static let minimumHostVersion = SemanticVersion(0, 0, 0)

    /// 主机报告的版本是否可用；无法解析时视为可用（不因版本号格式阻止使用），由接口层面的错误兜底。
    public static func check(hostVersion: String?) -> MagpieError? {
        guard let hostVersion, let version = SemanticVersion(hostVersion) else { return nil }
        if version < minimumHostVersion {
            return .incompatibleHost(found: hostVersion, required: minimumHostVersion.description)
        }
        return nil
    }
}
