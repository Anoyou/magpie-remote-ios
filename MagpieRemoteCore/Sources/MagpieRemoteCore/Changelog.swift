import Foundation

/// App 内「更新日志」：解析随 App 打包的 CHANGELOG.md。
///
/// 格式（与仓库根目录 CHANGELOG.md 约定一致）：
/// ```
/// ## [0.1.0] - 2026-11-01 · minor（次版本） · 主题
/// > 说明（可选）
/// ### 新增
/// - 条目
/// ```
public struct ChangelogRelease: Hashable, Identifiable, Sendable {
    public struct Group: Hashable, Identifiable, Sendable {
        public var title: String
        public var items: [String]
        public var id: String { title }
    }

    public var version: String
    public var date: String?
    public var level: String?
    public var theme: String?
    public var note: String?
    public var groups: [Group]
    public var id: String { version }
}

public enum Changelog {
    public static func parse(_ text: String) -> [ChangelogRelease] {
        var releases: [ChangelogRelease] = []
        var current: ChangelogRelease?

        func flush() {
            if let release = current, release.version.lowercased() != "unreleased" || !release.groups.isEmpty {
                releases.append(release)
            }
            current = nil
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                flush()
                current = header(String(line.dropFirst(3)))
                continue
            }
            guard var release = current else { continue }
            if line.hasPrefix("### ") {
                release.groups.append(.init(title: String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces), items: []))
            } else if line.hasPrefix("> ") {
                let note = String(line.dropFirst(2))
                release.note = release.note.map { $0 + "\n" + note } ?? note
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                if release.groups.isEmpty { release.groups.append(.init(title: "变化", items: [])) }
                release.groups[release.groups.count - 1].items.append(String(line.dropFirst(2)))
            } else {
                continue
            }
            current = release
        }
        flush()
        return releases
    }

    static func header(_ text: String) -> ChangelogRelease? {
        guard text.hasPrefix("["), let close = text.firstIndex(of: "]") else { return nil }
        let version = String(text[text.index(after: text.startIndex)..<close])
        var rest = text[text.index(after: close)...].trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("-") { rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) }
        let parts = rest.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return ChangelogRelease(version: version,
                                date: parts.count > 0 ? parts[0] : nil,
                                level: parts.count > 1 ? parts[1] : nil,
                                theme: parts.count > 2 ? parts[2...].joined(separator: " · ") : nil,
                                note: nil,
                                groups: [])
    }
}
