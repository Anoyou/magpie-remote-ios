import Foundation

// 「管理 › 主机更新」：Mac 上 magpie 自己的更新（internal/gui/update.go）。
//
// GET  /api/update[?fresh=1][&lang=zh]  → updateJSON（state 等）；fresh=1 让主机在很久没问过时重新问一次发布源
// POST /api/update/check[?lang=zh]       → 立刻检查，返回 updateJSON
// GET  /api/update/notes?lang=zh          → {latest, releases[{version, notes, url, pending}], error}
// POST /api/update/install {"when": ""|"now"|"cancel"}
//      state=found / error+retry：开始下载，返回 updateJSON（随后 downloading → ready）
//      state=ready：主机空闲时 204 并退出重启；忙时（when≠now）返回 waiting=true，等空闲再重启；
//                    when=now 不等；when=cancel 取消等待。发布源还没回应时返回 state=checking，稍后再点一次。
//      state=available：主机无法自己替换（只会在 Mac 上打开发布页），App 不发 install。

/// 主机返回的更新状态（`updateJSON`）。
public struct HostUpdateStatus: Hashable, Sendable {
    public enum State: String, Sendable {
        /// 很久没问过发布源，不能断言是否最新。
        case unknown = ""
        case checking, latest, found, downloading, ready, available, source, error, blocked
    }

    public struct Packaged: Hashable, Sendable {
        public var manager: String
        public var package: String
        public var command: String
    }

    public var raw: WebJSON
    public var state: State
    public var current: String
    public var latest: String
    public var notes: String
    public var url: String
    /// available：无法自己更新的原因（translocated / read-only / not-writable / package）。
    public var stuck: String
    public var stuckDir: String
    public var packaged: Packaged?
    public var retry: Bool
    public var mirror: String
    public var network: Bool
    public var error: String
    public var done: Int64
    public var total: Int64
    public var size: Int64
    public var blockedVersion: String
    public var blockedError: String
    public var blockedPolicy: Bool
    /// ready：重启会打断的进行中请求与工具调用。
    public var busyRequests: Int
    public var busyTools: Int
    public var waiting: Bool
    public var gaveUp: Bool
    public var handover: Bool

    public init(json: WebJSON) {
        raw = json
        state = State(rawValue: json["state"]?.string ?? "") ?? .unknown
        current = json["current"]?.string ?? ""
        latest = json["latest"]?.string ?? ""
        notes = json["notes"]?.string ?? ""
        url = json["url"]?.string ?? ""
        stuck = json["stuck"]?.string ?? ""
        stuckDir = json["stuckDir"]?.string ?? ""
        if let p = json["packaged"], p.object != nil {
            packaged = Packaged(manager: p["manager"]?.string ?? "", package: p["package"]?.string ?? "", command: p["command"]?.string ?? "")
        }
        retry = json["retry"]?.bool ?? false
        mirror = json["mirror"]?.string ?? ""
        network = json["network"]?.bool ?? false
        error = json["error"]?.string ?? ""
        done = Int64(json["done"]?.int ?? 0)
        total = Int64(json["total"]?.int ?? 0)
        size = Int64(json["size"]?.int ?? 0)
        blockedVersion = json["blocked"]?["version"]?.string ?? ""
        blockedError = json["blocked"]?["error"]?.string ?? ""
        blockedPolicy = json["blocked"]?["policy"]?.bool ?? false
        busyRequests = json["busy"]?["requests"]?.int ?? 0
        busyTools = json["busy"]?["tools"]?.int ?? 0
        waiting = json["waiting"]?.bool ?? false
        gaveUp = json["gaveUp"]?.bool ?? false
        handover = json["handover"]?.bool ?? false
    }

    /// 有比当前更新的版本。
    public var hasUpdate: Bool {
        guard !latest.isEmpty else { return false }
        if let l = SemanticVersion(latest), let c = SemanticVersion(current) { return l > c }
        return latest != current && state != .latest
    }

    public var isBusy: Bool { busyRequests > 0 || busyTools > 0 }

    /// 下载进度 0...1（不知道总大小时为 nil）。
    public var progress: Double? {
        guard state == .downloading, total > 0 else { return nil }
        return min(1, max(0, Double(done) / Double(total)))
    }

    /// 主机还在动（检查 / 下载 / 等空闲重启）：界面应每隔一两秒再读一次。
    public var isWorking: Bool { state == .checking || state == .downloading || waiting }

    /// 当前可以对主机做的操作。
    public var action: HostUpdateAction? {
        if waiting { return .cancelWait }
        switch state {
        case .found: return .download
        case .error where retry: return .retryDownload
        case .ready: return .restart
        default: return nil
        }
    }

    /// 一句话中文状态。
    public var summary: String {
        if waiting {
            return "等主机空闲后重启：还有\(busyText)进行中。"
        }
        switch state {
        case .unknown: return "有一阵子没检查更新了。"
        case .checking: return "正在检查更新…"
        case .latest: return "已是最新版本。"
        case .found:
            return size > 0 ? "发现新版本 \(display(latest))，下载约 \(HostToolsFormat.bytes(size))。" : "发现新版本 \(display(latest))。"
        case .downloading:
            if total > 0 { return "正在下载 \(display(latest))：\(HostToolsFormat.bytes(done)) / \(HostToolsFormat.bytes(total))" }
            return "正在下载 \(display(latest))…"
        case .ready:
            if gaveUp { return "新版本已下载。上次等主机空闲时超时了，主机仍有请求在进行。" }
            return "新版本 \(display(latest)) 已下载，重启 magpie 即可装好。"
        case .available: return stuckText
        case .source: return "这台主机上的 magpie 是从源码构建的，不能自动更新。"
        case .error:
            if network { return "下载被网络中断了（已自动重试过）。" }
            return error.isEmpty ? "检查更新失败。" : "更新出错：\(error)"
        case .blocked:
            return blockedPolicy
                ? "Mac 拒绝运行 \(display(blockedVersion))（应用控制策略）：\(blockedError)"
                : "主机启动不了 \(display(blockedVersion))：\(blockedError)"
        }
    }

    /// available 时为什么不能自己更新。
    public var stuckText: String {
        switch stuck {
        case "package":
            let name = packaged?.manager ?? ""
            return name.isEmpty ? "magpie 是用包管理器装的，请用它来更新。" : "magpie 是用 \(name) 装的，请用 \(name) 更新。"
        case "translocated": return "magpie 是直接从下载位置（或磁盘映像）运行的，macOS 不允许它替换自己。把它移到「应用程序」文件夹再打开即可自动更新。"
        case "read-only": return "magpie 所在的位置是只读的，不能自动更新。"
        case "not-writable": return stuckDir.isEmpty ? "magpie 没有权限写入自己所在的文件夹，不能自动更新。" : "magpie 没有权限写入 \(stuckDir)，不能自动更新。"
        default: return "这台主机上的 magpie 不能自己更新，需要在 Mac 上手动下载新版本。"
        }
    }

    var busyText: String {
        var parts: [String] = []
        if busyRequests > 0 { parts.append(" \(busyRequests) 个请求") }
        if busyTools > 0 { parts.append(" \(busyTools) 个工具调用") }
        return parts.isEmpty ? "任务" : parts.joined(separator: "、")
    }

    /// 重启会打断什么（确认弹窗用）；不忙时为 nil。
    public var restartWarning: String? {
        guard isBusy else { return nil }
        if handover { return "主机正在处理\(busyText)。magpie 会把网关交给新版本，大部分请求能接着完成，Claude 订阅的对话可能被打断。" }
        return "主机正在处理\(busyText)，立即重启会打断它们。"
    }

    func display(_ version: String) -> String { HostToolsFormat.version(version) }
}

/// 对主机更新可以做的操作（都是 `POST /api/update/install`）。
public enum HostUpdateAction: Hashable, Sendable {
    /// found：开始下载。
    case download
    /// 上次下载失败，再下载一次。
    case retryDownload
    /// ready：重启进新版本（忙时主机会等空闲）。
    case restart
    /// 正在等空闲：取消。
    case cancelWait

    public var title: String {
        switch self {
        case .download: "下载更新"
        case .retryDownload: "重新下载"
        case .restart: "重启并安装"
        case .cancelWait: "取消等待"
        }
    }
}

/// `GET /api/update/notes` 的结果：从当前版本到最新版之间每个版本的说明，新的在前。
public struct HostUpdateNotes: Hashable, Sendable {
    public struct Release: Hashable, Identifiable, Sendable {
        public var version: String
        public var notes: String
        public var url: String
        /// 当前版本之后、尚未安装的版本。
        public var pending: Bool
        public var id: String { version }
    }

    public var latest: String
    public var releases: [Release]
    public var error: String

    public init(json: WebJSON) {
        latest = json["latest"]?.string ?? ""
        error = json["error"]?.string ?? ""
        releases = (json["releases"]?.array ?? []).compactMap { item in
            guard let version = item["version"]?.string else { return nil }
            return Release(version: version, notes: item["notes"]?.string ?? "", url: item["url"]?.string ?? "",
                           pending: item["pending"]?.bool ?? false)
        }
    }
}

/// 发布说明（Markdown）拆成行，App 按标题 / 列表 / 段落显示。
public enum ReleaseNotesFormat {
    public enum Line: Hashable, Sendable {
        case heading(String)
        case bullet(String)
        case text(String)
    }

    public static func lines(_ markdown: String) -> [Line] {
        var out: [Line] = []
        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("<!--") { continue }
            if line.hasPrefix("#") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { out.append(.heading(title)) }
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                out.append(.bullet(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
            } else {
                out.append(.text(line))
            }
        }
        return out
    }
}

/// 新版本与 App 已验证范围的关系（`MagpieCompatibility`）。
public enum HostUpdateCompatibility: Hashable, Sendable {
    /// 在已验证范围内。
    case tested
    /// 比 App 验证过的最新版本还新：大概率可用，但没测过。
    case untested(tested: String)
    /// 比 App 支持的最低版本还旧。
    case unsupported(required: String)
    /// 版本号无法解析。
    case unknown

    public static func of(_ version: String) -> HostUpdateCompatibility {
        guard let v = SemanticVersion(version) else { return .unknown }
        if v < MagpieCompatibility.minimumHostVersion { return .unsupported(required: MagpieCompatibility.minimumHostVersion.description) }
        if v > MagpieCompatibility.testedHostVersion { return .untested(tested: MagpieCompatibility.testedHostVersion.description) }
        return .tested
    }

    /// 需要提醒时的中文说明。
    public var warning: String? {
        switch self {
        case .tested, .unknown: nil
        case .untested(let tested):
            "这个版本比 App 验证过的 v\(tested) 更新。magpie 的接口通常向后兼容，更新后如有页面报错，请回到这里查看提示或更新 App。"
        case .unsupported(let required):
            "这个版本低于 App 需要的 v\(required)，更新后「管理」等页面可能无法使用。"
        }
    }
}

/// 点「重启并安装」之后，等主机重启回来。
///
/// 主机在 204 之后才退出，所以头一两次可能还是旧进程在回应；之后连不上；
/// 新进程起来后 `/api/settings` 的 version 变成新版本。
public struct HostRestartTracker: Sendable {
    public enum Outcome: Hashable, Sendable {
        /// 还在等。
        case waiting(sawDown: Bool)
        /// 回来了；`upgraded` 为 false 表示版本没变（安装没有成功，或主机根本没重启）。
        case back(version: String, upgraded: Bool)
    }

    public let oldVersion: String
    public let expected: String
    public private(set) var sawDown = false
    /// 连续读到旧版本的次数。
    public private(set) var sameCount = 0
    /// 读到旧版本多少次（且从没断开）后判定没有重启。
    public let sameLimit: Int

    public init(oldVersion: String, expected: String = "", sameLimit: Int = 8) {
        self.oldVersion = oldVersion
        self.expected = expected
        self.sameLimit = sameLimit
    }

    /// 读一次 `/api/settings` 的结果：成功时传版本号，连不上时传 nil。
    public mutating func observe(version: String?) -> Outcome {
        guard let version else {
            sawDown = true
            return .waiting(sawDown: true)
        }
        if Self.same(version, oldVersion) {
            sameCount += 1
            // 断开后回来还是旧版本：安装没成功。没断开且多次都是旧版本：主机没有重启。
            if sawDown || sameCount >= sameLimit { return .back(version: version, upgraded: false) }
            return .waiting(sawDown: sawDown)
        }
        return .back(version: version, upgraded: true)
    }

    static func same(_ a: String, _ b: String) -> Bool {
        if let x = SemanticVersion(a), let y = SemanticVersion(b) { return x == y }
        return a == b
    }

    /// 轮询直到主机回来或超时（超时抛 `.unreachable(.timedOut)`）。`fetch` 返回 version，连不上时抛错。
    public static func wait(oldVersion: String, expected: String = "", interval: Duration = .seconds(2), timeout: Duration = .seconds(240),
                            clock: some Clock<Duration> = ContinuousClock(),
                            fetch: @Sendable () async throws -> String?,
                            progress: @Sendable (Outcome) async -> Void = { _ in }) async throws -> Outcome {
        var tracker = HostRestartTracker(oldVersion: oldVersion, expected: expected)
        var elapsed: Duration = .zero
        while elapsed < timeout {
            try await clock.sleep(for: interval)
            elapsed += interval
            try Task.checkCancellation()
            let version: String?
            do {
                version = try await fetch() ?? ""
            } catch {
                if MagpieError.from(error) == .cancelled { throw MagpieError.cancelled }
                version = nil
            }
            let outcome = tracker.observe(version: version)
            await progress(outcome)
            if case .back = outcome { return outcome }
        }
        throw MagpieError.unreachable(.timedOut)
    }
}

/// 主机工具页共用的写法。
public enum HostToolsFormat {
    /// `v0.1.2440`（已带 v 的不重复加）。
    public static func version(_ v: String) -> String {
        let t = v.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "—" }
        return t.hasPrefix("v") || t.hasPrefix("V") ? t : "v" + t
    }

    /// 字节：`512 KB`、`48.3 MB`、`1.2 GB`。
    public static func bytes(_ value: Int64) -> String {
        let v = Double(max(0, value))
        if v >= 1_000_000_000 { return UsageFormat.trimmed(v / 1_000_000_000) + " GB" }
        if v >= 1_000_000 { return UsageFormat.trimmed(v / 1_000_000) + " MB" }
        if v >= 1_000 { return "\(Int((v / 1_000).rounded())) KB" }
        return "\(Int(v)) B"
    }

    /// 词元窗口：`170K`、`1M`、`1.5M`（与 magpie 网页的写法一致）。
    public static func tokensK(_ value: Int) -> String {
        if value >= 1_000_000 { return UsageFormat.trimmed(Double(value) / 1_000_000) + "M" }
        if value >= 1_000 { return "\(Int((Double(value) / 1_000).rounded()))K" }
        return String(value)
    }

    /// 秒数：`45 秒`、`3 分钟`、`1.5 小时`。
    public static func seconds(_ s: Int) -> String {
        if s < 60 { return "\(s) 秒" }
        if s < 3600 { return "\(Int((Double(s) / 60).rounded())) 分钟" }
        return UsageFormat.trimmed(Double(s) / 3600) + " 小时"
    }
}

// MARK: 请求

extension WebClient {
    /// `GET /api/update`；`fresh` 让主机在很久没问过时先问一次发布源。说明按中文。
    public func updateStatus(fresh: Bool = false) async throws -> HostUpdateStatus {
        var query = [URLQueryItem(name: "lang", value: "zh")]
        if fresh { query.insert(URLQueryItem(name: "fresh", value: "1"), at: 0) }
        return HostUpdateStatus(json: try await get("/api/update", query: query))
    }

    /// `POST /api/update/check?lang=zh`：立即检查。
    public func checkUpdate() async throws -> HostUpdateStatus {
        HostUpdateStatus(json: try await send(makeRequest("/api/update/check", method: "POST", query: [URLQueryItem(name: "lang", value: "zh")], body: [:])))
    }

    /// `GET /api/update/notes?lang=zh`：当前版本之后每个版本的中文说明。
    public func updateNotes() async throws -> HostUpdateNotes {
        HostUpdateNotes(json: try await get("/api/update/notes", query: [URLQueryItem(name: "lang", value: "zh")]))
    }

    /// `POST /api/update/install`。返回 nil 表示主机回了 204，正在退出重启。
    public func installUpdate(_ when: HostUpdateInstallWhen = .whenIdle) async throws -> HostUpdateStatus? {
        let json = try await post("/api/update/install", HostToolsRequests.install(when))
        return json.isNull ? nil : HostUpdateStatus(json: json)
    }
}

/// `POST /api/update/install` 的 `when`。
public enum HostUpdateInstallWhen: String, Sendable {
    /// 主机忙时等空闲（默认）。
    case whenIdle = ""
    /// 不等，立刻重启。
    case now
    /// 取消正在等待的重启。
    case cancel
}

/// 主机工具页的请求体。
public enum HostToolsRequests {
    public static func install(_ when: HostUpdateInstallWhen) -> WebJSON {
        when == .whenIdle ? [:] : ["when": .string(when.rawValue)]
    }
}
