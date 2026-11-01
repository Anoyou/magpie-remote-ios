import Foundation

// 会话的「回收站」，照官方网页会话页（plugins/sessions/client.js 的 Trash）：删除的会话移到 magpie 的回收站，
// 在这里可以「恢复」或「永久删除」，也可以「清空回收站」。

/// 回收站里的一个会话（magpie `sessions.Trashed` + 名字和图标）。
public struct TrashedSession: Hashable, Identifiable, Sendable {
    /// 它在回收站里的目录（`<agent>/<name>`），恢复 / 永久删除都用它。
    public var key: String
    public var agent: String
    public var sessionID: String
    public var title: String
    public var cwd: String
    public var last: Date?
    public var deleted: Date?
    public var size: Int64
    /// Agent 的名字与图标。
    public var name: String
    public var icon: String
    /// 只经过 magpie 网关看到的会话（回收站里是 magpie 记录的对话文本）。
    public var gateway: Bool
    public var id: String { key }

    public init?(json: WebJSON) {
        guard let key = json["key"]?.string, !key.isEmpty else { return nil }
        self.key = key
        agent = json["agent"]?.string ?? ""
        sessionID = json["id"]?.string ?? ""
        title = json["title"]?.string ?? ""
        cwd = json["cwd"]?.string ?? ""
        last = sessionDate(json["last"])
        deleted = sessionDate(json["deleted"])
        size = Int64(json["size"]?.int ?? 0)
        let name = json["name"]?.string ?? ""
        self.name = name.isEmpty ? agent : name
        icon = json["icon"]?.string ?? ""
        gateway = json["gateway"]?.bool ?? false
    }

    public var displayTitle: String { title.isEmpty ? sessionID : title }
}

/// `POST /api/sessions/purge` 的结果。
public struct SessionPurgeResult: Hashable, Sendable {
    public struct Refused: Hashable, Sendable {
        public var key: String
        public var error: String
    }

    public var purged: [String]
    public var refused: [Refused]

    public init(json: WebJSON) {
        purged = json["purged"]?.strings ?? []
        refused = (json["refused"]?.array ?? []).map { Refused(key: $0["key"]?.string ?? "", error: $0["error"]?.string ?? "") }
    }

    public var failureMessage: String? { refused.isEmpty ? nil : refused.map(\.error).joined(separator: "；") }
}

extension WebClient {
    /// 把回收站里的一个会话放回原处；返回它的标题。
    public func restoreSession(key: String) async throws -> String {
        let json = try await post("/api/sessions/restore", ["key": .string(key)])
        return json["title"]?.string ?? json["id"]?.string ?? ""
    }

    /// 永久删除回收站里的会话（`all` = 清空回收站）。
    public func purgeSessions(keys: [String], all: Bool = false) async throws -> SessionPurgeResult {
        var body: [String: WebJSON] = ["keys": .strings(keys)]
        if all { body["all"] = true }
        return SessionPurgeResult(json: try await post("/api/sessions/purge", .object(body)))
    }
}
