import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// 「Agent 会话记录」：magpie 在 Mac 上读到的 Claude Code / Codex 等 Agent 的会话。
// 接口在 magpie Web 管理接口（3430）里，形状取自 magpie 源码 internal/gui/sessions*.go 与
// internal/sessions（v0.1.2438 / 80af3b8）：
//   GET  /api/sessions/manage?agent=      有会话的 Agent、所选 Agent 的全部会话、回收站、读取授权
//   GET  /api/sessions/transcript?agent=&id=[&sub=]   会话内容 {parts[], cut?}
//   GET  /api/sessions/search?agent=&q=   按对话内容搜索（q 至少 2 个字）
//   GET  /api/sessions/markdown?agent=&id=   整段对话的 Markdown 文件（text/markdown）
//   POST /api/sessions/export?agent=&id=  把 Markdown 存到 Mac 的「下载」文件夹，返回 {path}
//   POST /api/sessions/delete {agent, ids[]}   移到 magpie 回收站（可在 Mac 上恢复），返回 {deleted[], refused[]}
//   POST /api/sessions/reads {all?, agents{}}  允许 magpie 读取哪些 Agent 的会话
// 字段都按「可能缺失 / 为 null」读取：magpie 的 omitempty 很多，且随版本增减。

/// Go 的零值时间（0001-01-01T00:00:00Z）当作没有。
func sessionDate(_ json: WebJSON?) -> Date? {
    guard let text = json?.string, let date = QuotaTime.parse(text) else { return nil }
    return date.timeIntervalSince1970 < 86_400 ? nil : date
}

// MARK: Agent

/// 在这台 Mac 上有会话记录的 Agent。
public struct SessionAgent: Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var icon: String
    public var count: Int
    /// magpie 能否把这个 Agent 的会话移到回收站。
    public var deletable: Bool

    public init(id: String, name: String, icon: String = "generic", count: Int, deletable: Bool) {
        self.id = id; self.name = name; self.icon = icon; self.count = count; self.deletable = deletable
    }

    init?(json: WebJSON) {
        guard let id = json["agent"]?.string, !id.isEmpty else { return nil }
        self.id = id
        let name = json["name"]?.string ?? ""
        self.name = name.isEmpty ? id : name
        icon = json["icon"]?.string ?? "generic"
        count = json["count"]?.int ?? 0
        deletable = json["deletable"]?.bool ?? false
    }
}

// MARK: 会话

/// 会话里一个模型用掉的量。
public struct SessionModelShare: Hashable, Sendable {
    public var model: String
    public var effort: String?
    public var tokens: Int
    public var cost: Double
    public var priced: Bool

    init?(json: WebJSON) {
        guard let model = json["model"]?.string, !model.isEmpty else { return nil }
        self.model = model
        let effort = json["effort"]?.string ?? ""
        self.effort = effort.isEmpty ? nil : effort
        tokens = ["input", "output", "cache_read", "cache_write"].reduce(0) { $0 + (json[$1]?.int ?? 0) }
        cost = json["cost"]?.double ?? 0
        priced = json["priced"]?.bool ?? false
    }
}

/// 会话里由 Agent 自己开出的子会话（Claude Code 的 Explore 等）。
public struct SessionSubagent: Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var kind: String
    public var last: Date?

    init?(json: WebJSON) {
        guard let id = json["id"]?.string, !id.isEmpty else { return nil }
        self.id = id
        title = json["title"]?.string ?? ""
        kind = json["kind"]?.string ?? ""
        last = sessionDate(json["last"])
    }

    public var displayTitle: String {
        if !title.isEmpty { return title }
        return kind.isEmpty ? id : kind
    }
}

/// 一次 Agent 会话（「会话」页的一行）。
public struct AgentSession: Hashable, Identifiable, Sendable {
    public var agent: String
    public var sessionID: String
    public var title: String
    public var nickname: String
    public var cwd: String
    public var start: Date?
    public var last: Date?
    public var models: [SessionModelShare]
    /// 经由 magpie 网关时实际发往的模型（`via[].model`）。
    public var viaModels: [String]
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    /// 美元，只算有价格的模型。
    public var cost: Double
    /// 用了词元但没有价格的模型数。
    public var unpriced: Int
    /// 会话文件的字节数（网关会话为 magpie 记录的对话文本大小）。
    public var size: Int64
    public var messages: Int
    public var files: Int
    public var deletable: Bool
    /// magpie 还在第一次读它的文件：花费和消息数还没算出来。
    public var pending: Bool
    /// 只经过 magpie 网关看到、这台 Mac 上没有 Agent 自己的文件。
    public var gateway: Bool
    public var readOnly: Bool
    /// 能读出对话内容。
    public var hasTranscript: Bool
    public var role: String
    public var path: String
    public var subagents: [SessionSubagent]

    public var id: String { agent + "|" + sessionID }

    public init(json: WebJSON) {
        agent = json["agent"]?.string ?? ""
        sessionID = json["id"]?.string ?? ""
        title = json["title"]?.string ?? ""
        nickname = json["nickname"]?.string ?? ""
        cwd = json["cwd"]?.string ?? ""
        start = sessionDate(json["start"])
        last = sessionDate(json["last"])
        let efforts = (json["model_effort"]?.array ?? []).compactMap(SessionModelShare.init(json:))
        let plain = (json["models"]?.array ?? []).compactMap(SessionModelShare.init(json:))
        models = (efforts.isEmpty ? plain : efforts).sorted { $0.tokens > $1.tokens }
        var seen = Set<String>()
        viaModels = (json["via"]?.array ?? []).compactMap { $0["model"]?.string }.filter { !$0.isEmpty && seen.insert($0).inserted }
        inputTokens = json["input"]?.int ?? 0
        outputTokens = json["output"]?.int ?? 0
        cacheReadTokens = json["cache_read"]?.int ?? 0
        cacheWriteTokens = json["cache_write"]?.int ?? 0
        cost = json["cost"]?.double ?? 0
        unpriced = json["unpriced"]?.int ?? 0
        size = Int64(json["size"]?.double ?? 0)
        messages = json["messages"]?.int ?? 0
        files = json["files"]?.int ?? 0
        deletable = json["deletable"]?.bool ?? false
        pending = json["pending"]?.bool ?? false
        gateway = json["gateway"]?.bool ?? false
        readOnly = json["read_only"]?.bool ?? false
        hasTranscript = json["transcript"]?.bool ?? false
        role = json["role"]?.string ?? ""
        path = json["path"]?.string ?? ""
        subagents = (json["subagents"]?.array ?? []).compactMap(SessionSubagent.init(json:))
    }

    /// 列表标题：命名 → Agent 自己的标题 / 第一句话 → 短 ID。
    public var displayTitle: String {
        let title = self.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title.replacingOccurrences(of: "\n", with: " ") }
        if !nickname.isEmpty { return nickname }
        return sessionID.isEmpty ? "（无标题）" : String(sessionID.prefix(12))
    }

    /// 工作目录的最后一段（`~/code/app` → `app`）。
    public var folderName: String {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        guard let last = trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last else { return trimmed }
        return String(last)
    }

    public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }

    /// 用到的模型名（按用量排序，去重）；会话文件里没写时用网关记录的。
    public var modelNames: [String] {
        var seen = Set<String>()
        let names = models.map(\.model) + viaModels
        return names.filter { seen.insert($0).inserted }
    }

    public var primaryModel: String? { modelNames.first }

    /// 本地筛选：标题、目录、模型、ID 里含有关键词（不区分大小写）。
    public func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = ([title, nickname, cwd, sessionID] + modelNames).joined(separator: "\n").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }
}

// MARK: 读取授权

/// magpie 允许读取哪些 Agent 的会话（新装的 magpie 要先选一次，否则一个都不读）。
public struct SessionReads: Hashable, Sendable {
    public struct Agent: Hashable, Identifiable, Sendable {
        public var id: String
        public var name: String
        public var on: Bool

        public init(id: String, name: String, on: Bool) {
            self.id = id
            self.name = name
            self.on = on
        }
    }

    /// 用户已经选过。
    public var asked: Bool
    /// 以后发现的 Agent 也读。
    public var all: Bool
    public var found: [Agent]

    public init(asked: Bool, all: Bool, found: [Agent]) {
        self.asked = asked; self.all = all; self.found = found
    }

    public init(json: WebJSON?) {
        asked = json?["asked"]?.bool ?? true
        all = json?["all"]?.bool ?? false
        found = (json?["found"]?.array ?? []).compactMap { item in
            guard let id = item["agent"]?.string, !id.isEmpty else { return nil }
            let name = item["name"]?.string ?? ""
            return Agent(id: id, name: name.isEmpty ? id : name, on: item["on"]?.bool ?? false)
        }
    }

    /// 找到了会话但不允许读的 Agent。
    public var blocked: [Agent] { found.filter { !$0.on } }
}

// MARK: 管理页数据

/// `GET /api/sessions/manage` 的结果。
public struct SessionsOverview: Hashable, Sendable {
    public var agents: [SessionAgent]
    /// 本次列出的 Agent（没指定或指定的没有会话时，是会话最多的那个）。
    public var agent: String
    public var sessions: [AgentSession]
    public var trashCount: Int
    /// magpie 网关是否在记录对话文本。
    public var recording: Bool
    public var reads: SessionReads

    public init(json: WebJSON) {
        agents = (json["agents"]?.array ?? []).compactMap(SessionAgent.init(json:))
        agent = json["agent"]?.string ?? ""
        sessions = (json["sessions"]?.array ?? []).map(AgentSession.init(json:)).filter { !$0.sessionID.isEmpty }
        trashCount = json["trash"]?.array?.count ?? 0
        recording = json["recording"]?.bool ?? false
        reads = SessionReads(json: json["reads"])
    }

    public var currentAgent: SessionAgent? { agents.first { $0.id == agent } }
}

// MARK: 对话内容

public struct TranscriptPart: Hashable, Identifiable, Sendable {
    public enum Role: String, Sendable { case user, assistant, tool, other }
    public enum Kind: String, Sendable { case text, thinking, toolUse = "tool_use", toolResult = "tool_result", context, image, other }

    public var id: Int
    public var role: Role
    public var kind: Kind
    /// 工具名（工具调用时）。
    public var name: String
    public var text: String
    /// 末尾被截掉的字符数。
    public var cut: Int
    public var model: String

    public init(id: Int, role: Role, kind: Kind, name: String = "", text: String, cut: Int = 0, model: String = "") {
        self.id = id; self.role = role; self.kind = kind; self.name = name; self.text = text; self.cut = cut; self.model = model
    }

    init(index: Int, json: WebJSON) {
        id = index
        role = Role(rawValue: json["role"]?.string ?? "") ?? .other
        kind = Kind(rawValue: json["kind"]?.string ?? "") ?? .other
        name = json["name"]?.string ?? ""
        text = json["text"]?.string ?? ""
        cut = json["cut"]?.int ?? 0
        model = json["model"]?.string ?? ""
    }

    /// 气泡上方的小标题。
    public var label: String {
        switch kind {
        case .thinking: return "思考"
        case .toolUse: return name.isEmpty ? "调用工具" : "调用工具 · \(name)"
        case .toolResult: return name.isEmpty ? "工具结果" : "工具结果 · \(name)"
        case .context: return "上下文"
        case .image: return "图片"
        case .text, .other:
            switch role {
            case .user: return "你"
            case .assistant: return model.isEmpty ? "助手" : "助手 · \(model)"
            case .tool: return "工具"
            case .other: return "其它"
            }
        }
    }

    /// 普通对话（不是思考 / 工具 / 上下文）。
    public var isConversation: Bool { kind == .text && (role == .user || role == .assistant) }
}

/// `GET /api/sessions/transcript` 的结果。
public struct SessionTranscript: Hashable, Sendable {
    public var parts: [TranscriptPart]
    /// 太长，magpie 只给了前面一部分。
    public var cut: Bool

    public init(parts: [TranscriptPart], cut: Bool = false) {
        self.parts = parts; self.cut = cut
    }

    public init(json: WebJSON) {
        parts = (json["parts"]?.array ?? []).enumerated().map { TranscriptPart(index: $0.offset, json: $0.element) }
        cut = json["cut"]?.bool ?? false
    }

    /// 只看对话时隐藏思考、工具和上下文。
    public func visible(showTools: Bool) -> [TranscriptPart] {
        showTools ? parts : parts.filter(\.isConversation)
    }

    /// 用户说了几次话。
    public var turns: Int { parts.filter { $0.role == .user && $0.kind == .text }.count }
}

// MARK: 搜索

public struct SessionSearchHit: Hashable, Sendable {
    public var id: String
    public var role: String
    public var before: String
    public var match: String
    public var after: String

    public var snippet: String { (before + match + after).replacingOccurrences(of: "\n", with: " ") }
}

/// `GET /api/sessions/search` 的结果。
public struct SessionSearchResult: Hashable, Sendable {
    public var hits: [SessionSearchHit]
    public var searched: Int
    public var total: Int
    /// 没搜完（命中太多或超时）。
    public var cut: Bool
    /// 这个 Agent 自己的会话存在数据库里，只搜了 magpie 网关记录的。
    public var unread: Bool

    public init(json: WebJSON) {
        hits = (json["hits"]?.array ?? []).compactMap { hit in
            guard let id = hit["id"]?.string, !id.isEmpty else { return nil }
            return SessionSearchHit(id: id, role: hit["role"]?.string ?? "", before: hit["before"]?.string ?? "",
                                    match: hit["match"]?.string ?? "", after: hit["after"]?.string ?? "")
        }
        searched = json["searched"]?.int ?? 0
        total = json["total"]?.int ?? 0
        cut = json["cut"]?.bool ?? false
        unread = json["unread"]?.bool ?? false
    }

    /// magpie 至少要 2 个字才搜。
    public static func canSearch(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    public func hit(for sessionID: String) -> SessionSearchHit? { hits.first { $0.id == sessionID } }
}

// MARK: 删除 / 导出

/// `POST /api/sessions/delete` 的结果：逐个处理，正在写的会话会被拒绝。
public struct SessionDeleteResult: Hashable, Sendable {
    public struct Refused: Hashable, Sendable {
        public var id: String
        public var error: String
        /// 最近一分钟还在写，Agent 可能正在用它。
        public var active: Bool
    }

    public var deleted: [String]
    public var refused: [Refused]

    public init(json: WebJSON) {
        deleted = json["deleted"]?.strings ?? []
        refused = (json["refused"]?.array ?? []).compactMap { item in
            guard let id = item["id"]?.string else { return nil }
            return Refused(id: id, error: item["error"]?.string ?? "", active: item["active"]?.bool ?? false)
        }
    }

    /// 给用户看的失败原因；全部成功时为 nil。
    public var failureMessage: String? {
        guard let first = refused.first else { return nil }
        if first.active { return "这个会话最近一分钟还在写入，Agent 可能正在使用它。稍后再删。" }
        if first.error.contains("can't delete") { return "magpie 不能删除这个 Agent 的会话。" }
        return first.error.isEmpty ? "主机没有删除这个会话。" : first.error
    }
}

/// `GET /api/sessions/markdown`：整段对话的 Markdown。
public struct SessionMarkdown: Hashable, Sendable {
    public var filename: String
    public var text: String

    public init(filename: String, text: String) {
        self.filename = filename; self.text = text
    }

    /// 从 `Content-Disposition: attachment; filename="magpie-session-claude-xxxx.md"` 取文件名；
    /// 只留字母、数字和 - _ .，取不到时按 magpie 的规则拼一个。
    public static func filename(contentDisposition: String?, agent: String, id: String) -> String {
        if let header = contentDisposition, let range = header.range(of: "filename=") {
            var name = String(header[range.upperBound...])
            if let semicolon = name.firstIndex(of: ";") { name = String(name[..<semicolon]) }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            name = String(name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-_.".unicodeScalars.contains($0) })
            if !name.isEmpty && name != ".md" && !name.hasPrefix(".") { return name.hasSuffix(".md") ? name : name + ".md" }
        }
        let safe = String((agent + "-" + String(id.prefix(12))).map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "-" })
        return "magpie-session-\(safe).md"
    }
}

// MARK: 列表排序与显示

public enum SessionSort: String, CaseIterable, Identifiable, Sendable {
    case recent, size, cost, messages

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .recent: "最近使用"
        case .size: "占用空间"
        case .cost: "花费"
        case .messages: "消息数"
        }
    }

    public func sorted(_ sessions: [AgentSession]) -> [AgentSession] {
        switch self {
        case .recent: sessions.sorted { ($0.last ?? .distantPast) > ($1.last ?? .distantPast) }
        case .size: sessions.sorted { $0.size > $1.size }
        case .cost: sessions.sorted { $0.cost > $1.cost }
        case .messages: sessions.sorted { $0.messages > $1.messages }
        }
    }
}

public enum SessionFormat {
    /// 文件大小：`812 B`、`12.4 KB`、`3.1 MB`。
    public static func size(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value < 1024 { return "\(bytes) B" }
        if value < 1024 * 1024 { return UsageFormat.trimmed(value / 1024) + " KB" }
        if value < 1024 * 1024 * 1024 { return UsageFormat.trimmed(value / 1024 / 1024) + " MB" }
        return UsageFormat.trimmed(value / 1024 / 1024 / 1024) + " GB"
    }

    /// 列表里的时间：今天 `14:05`，昨天 `昨天 14:05`，今年 `11-01 14:05`，更早 `2025-11-01`。
    public static func time(_ date: Date?, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        guard let date else { return "—" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            formatter.dateFormat = "HH:mm"
            return "昨天 " + formatter.string(from: date)
        }
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MM-dd HH:mm" : "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// 详情页的完整时间。
    public static func fullTime(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// 列表第二行：`gpt-5 · 42 条消息 · 1.2 MB`（缺的部分省略）。
    public static func summary(_ session: AgentSession) -> String {
        var parts: [String] = []
        if let model = session.primaryModel {
            parts.append(session.modelNames.count > 1 ? "\(model) 等 \(session.modelNames.count) 个模型" : model)
        }
        if session.pending {
            parts.append("统计中")
        } else if session.messages > 0 {
            parts.append("\(session.messages) 条消息")
        }
        if session.size > 0 { parts.append(size(session.size)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: 请求体

extension WebRequests {
    /// `POST /api/sessions/delete`。
    public static func sessionsDelete(agent: String, ids: [String]) -> WebJSON {
        ["agent": .string(agent), "ids": .strings(ids)]
    }

    /// `POST /api/sessions/reads`：只改列出的 Agent，其它保持原样。
    public static func sessionReads(_ agents: [String: Bool]) -> WebJSON {
        ["agents": .object(agents.mapValues(WebJSON.bool))]
    }
}

// MARK: 接口

extension WebClient {
    static func sessionQuery(agent: String, id: String) -> [URLQueryItem] {
        [URLQueryItem(name: "agent", value: agent), URLQueryItem(name: "id", value: id)]
    }

    /// 有会话的 Agent 与 `agent` 的全部会话；`agent` 为空时由主机挑会话最多的。
    public func sessionsOverview(agent: String? = nil) async throws -> SessionsOverview {
        let query = agent.flatMap { $0.isEmpty ? nil : [URLQueryItem(name: "agent", value: $0)] } ?? []
        return SessionsOverview(json: try await get("/api/sessions/manage", query: query))
    }

    /// 会话的对话内容；`sub` 为子会话 ID。
    public func sessionTranscript(agent: String, id: String, sub: String? = nil) async throws -> SessionTranscript {
        var query = Self.sessionQuery(agent: agent, id: id)
        if let sub, !sub.isEmpty { query.append(URLQueryItem(name: "sub", value: sub)) }
        return SessionTranscript(json: try await get("/api/sessions/transcript", query: query))
    }

    public func searchSessions(agent: String, query text: String) async throws -> SessionSearchResult {
        SessionSearchResult(json: try await get("/api/sessions/search", query: [
            URLQueryItem(name: "agent", value: agent), URLQueryItem(name: "q", value: text),
        ]))
    }

    public func deleteSessions(agent: String, ids: [String]) async throws -> SessionDeleteResult {
        SessionDeleteResult(json: try await post("/api/sessions/delete", WebRequests.sessionsDelete(agent: agent, ids: ids)))
    }

    public func setSessionReads(_ agents: [String: Bool]) async throws -> SessionReads {
        SessionReads(json: try await post("/api/sessions/reads", WebRequests.sessionReads(agents)))
    }

    /// 把会话存成 Markdown 放进 Mac 的「下载」文件夹，返回主机上的路径（`~/Downloads/…`）。
    public func exportSessionOnHost(agent: String, id: String) async throws -> String {
        var request = try makeRequest("/api/sessions/export", method: "POST", query: Self.sessionQuery(agent: agent, id: id))
        request.httpBody = Data()
        return try await send(request)["path"]?.string ?? ""
    }

    /// 取回整段对话的 Markdown（分享到 iPhone 上的其它 App）。
    public func sessionMarkdown(agent: String, id: String) async throws -> SessionMarkdown {
        var request = try makeRequest("/api/sessions/markdown", query: Self.sessionQuery(agent: agent, id: id))
        request.setValue("text/markdown, application/json;q=0.5", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MagpieError.from(error)
        }
        guard let http = response as? HTTPURLResponse else { throw MagpieError.unreachable(.other) }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"), body: data)
        }
        let name = SessionMarkdown.filename(contentDisposition: http.value(forHTTPHeaderField: "Content-Disposition"), agent: agent, id: id)
        return SessionMarkdown(filename: name, text: String(decoding: data, as: UTF8.self))
    }
}
