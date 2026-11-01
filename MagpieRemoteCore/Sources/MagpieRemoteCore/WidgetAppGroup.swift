import Foundation

// App 与小组件共享快照用的 App Group。
//
// 难点在自签：工程里写的是 `group.com.magpieremote.personal`，但 App Group 名在苹果那边全局唯一，
// 用免费 Apple ID 自签时签名工具通常会改名——AltStore / SideStore 在后面加 `.<团队 ID>`，并把真正的
// 名字写进 Info.plist 的 `ALTAppGroups`；其它工具（Sideloadly 等）改法不公开。所以 App 和小组件都在
// 运行时按同一套规则找组：
// 1. 自己包里 `embedded.mobileprovision` 授权的 App Group（签名工具实际开通的名字，最可靠）；
// 2. Info.plist 的 `ALTAppGroups`；
// 3. Info.plist 的 `MagpieAppGroup`（构建时写入的原名）；
// 4. 原名 + `.<团队 ID>`、`group.<主 App bundle id>`（以及再加团队 ID）。
// 系统认可（`containerURL` 返回目录、且能写入）的都算可用。App 把快照写进**每个**可用的组，
// 小组件从所有可用组里取最新的一份，所以两边即使挑到的顺序不同也能对上。
// 都不可用时（签名工具没开通 App Group），小组件显示「打开 App 刷新」，App 在「关于」里说明原因。

public enum WidgetAppGroup {
    /// 工程里写的原名（project.yml / 两个 .entitlements / Info.plist 的 `MagpieAppGroup`）。
    public static let baseIdentifier = "group.com.magpieremote.personal"
    /// Info.plist 里构建时写入的原名。
    public static let infoKey = "MagpieAppGroup"
    /// AltStore / SideStore 改名后写入的 Info.plist 键。
    public static let altStoreKey = "ALTAppGroups"
    /// 小组件扩展 bundle id 的后缀（`<主 App>.widgets`）。
    public static let extensionSuffix = ".widgets"

    /// 按优先级排好、去重后的候选组名。
    /// - Parameters:
    ///   - info: 自己的 Info.plist（`Bundle.main.infoDictionary`）。
    ///   - bundleID: 自己的 bundle id；小组件扩展会去掉 `.widgets` 后缀，换成主 App 的。
    ///   - profile: 自己包里描述文件的内容（没有时为 nil，例如模拟器）。
    public static func candidates(info: [String: Any], bundleID: String?, profile: ProvisioningProfileInfo?) -> [String] {
        var out: [String] = []
        func add(_ id: String?) {
            guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), id.hasPrefix("group."), id.count > 6,
                  !id.contains("*"), !id.contains("$("), !out.contains(id) else { return }
            out.append(id)
        }
        profile?.appGroups.forEach(add)
        (info[altStoreKey] as? [String])?.forEach(add)
        let built = info[infoKey] as? String
        add(built)
        add(baseIdentifier)
        let team = profile?.teamID
        var parent = bundleID?.trimmingCharacters(in: .whitespaces)
        if let p = parent, p.hasSuffix(extensionSuffix) { parent = String(p.dropLast(extensionSuffix.count)) }
        if let team, !team.isEmpty {
            for base in [built, baseIdentifier].compactMap({ $0 }) { add(base + "." + team) }
        }
        if let parent, !parent.isEmpty {
            add("group." + parent)
            if let team, !team.isEmpty, !parent.hasSuffix("." + team) { add("group." + parent + "." + team) }
        }
        return out
    }
}

/// 描述文件（`embedded.mobileprovision`）里关心的部分。
public struct ProvisioningProfileInfo: Hashable, Sendable {
    public var teamID: String?
    /// 授权的 App Group（不含通配符的）。
    public var appGroups: [String]

    public init(teamID: String?, appGroups: [String]) {
        self.teamID = teamID
        self.appGroups = appGroups
    }

    /// 描述文件是 CMS 签名包着的 XML plist：不验签，直接取出 `<?xml … </plist>` 那一段解析。
    public static func parse(_ data: Data) -> ProvisioningProfileInfo? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any] else { return nil }
        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        let team = (plist["TeamIdentifier"] as? [String])?.first
            ?? entitlements["com.apple.developer.team-identifier"] as? String
        let groups = (entitlements["com.apple.security.application-groups"] as? [String] ?? []).filter { !$0.contains("*") }
        return ProvisioningProfileInfo(teamID: team, appGroups: groups)
    }
}

/// 读写共享目录里的快照。`directories` 是所有可用 App Group 的目录（可能为空）。
public struct WidgetSnapshotStore: Sendable {
    public var directories: [URL]

    public init(directories: [URL]) {
        self.directories = directories
    }

    public var isAvailable: Bool { !directories.isEmpty }

    /// 写进每个可用目录（原子写入）。返回写成功的个数。
    @discardableResult
    public func write(_ snapshot: WidgetSnapshot) -> Int {
        guard let data = try? WidgetSnapshotCodec.encode(snapshot) else { return 0 }
        var written = 0
        for dir in directories {
            let url = dir.appendingPathComponent(WidgetSnapshotCodec.fileName)
            if (try? data.write(to: url, options: [.atomic])) != nil { written += 1 }
        }
        return written
    }

    /// 所有目录里最新的一份快照；都读不到时为 nil。
    public func read() -> WidgetSnapshot? {
        directories
            .compactMap { try? Data(contentsOf: $0.appendingPathComponent(WidgetSnapshotCodec.fileName)) }
            .compactMap(WidgetSnapshotCodec.decode)
            .max { $0.generatedAt < $1.generatedAt }
    }

    /// 小组件用：没有可用目录 → `.noAppGroup`；有目录没快照 → `.noSnapshot`。
    public func content() -> WidgetContent {
        guard isAvailable else { return .noAppGroup }
        return read().map(WidgetContent.snapshot) ?? .noSnapshot
    }

    /// 删除快照（删除最后一台主机时）。
    public func clear() {
        for dir in directories {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(WidgetSnapshotCodec.fileName))
        }
    }

    /// 按候选组名找出可用目录。`container` 是系统的 `containerURL(forSecurityApplicationGroupIdentifier:)`
    /// （单元测试里换成假的）；返回的目录要真的能写入才算可用（没授权时有的系统版本也会给出路径）。
    public static func resolve(candidates: [String], container: (String) -> URL?) -> (groups: [String], store: WidgetSnapshotStore) {
        var groups: [String] = []
        var dirs: [URL] = []
        for id in candidates {
            guard let root = container(id) else { continue }
            let dir = root.appendingPathComponent("Library/Application Support/Widgets", isDirectory: true)
            guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { continue }
            let probe = dir.appendingPathComponent(".probe")
            guard (try? Data("ok".utf8).write(to: probe, options: [.atomic])) != nil else { continue }
            try? FileManager.default.removeItem(at: probe)
            groups.append(id)
            dirs.append(dir)
        }
        return (groups, WidgetSnapshotStore(directories: dirs))
    }

    #if canImport(Darwin)
    /// 真机 / 模拟器上：按本进程的 Info.plist、bundle id 与描述文件找出可用目录。
    public static func live(bundle: Bundle = .main) -> (groups: [String], store: WidgetSnapshotStore) {
        let profile = bundle.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap(ProvisioningProfileInfo.parse)
        let ids = WidgetAppGroup.candidates(info: bundle.infoDictionary ?? [:], bundleID: bundle.bundleIdentifier, profile: profile)
        return resolve(candidates: ids) { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }
    #endif
}
