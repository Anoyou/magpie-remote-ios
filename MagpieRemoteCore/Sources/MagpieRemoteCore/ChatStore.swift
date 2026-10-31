import Foundation

/// 对话列表里的一行（不含消息内容，列表页不必读出图片）。
public struct ChatSessionSummary: Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var model: String?
    public var updatedAt: Date
    public var messageCount: Int

    public init(_ session: ChatSession) {
        id = session.id
        title = session.title
        model = session.model
        updatedAt = session.updatedAt
        messageCount = session.entries.count
    }
}

/// 把对话保存在本机：一个对话一个 JSON 文件（`<id>.json`），默认在 Application Support/Chats 下。
/// 只在本机，不经过主机、不同步。写入是原子的（先写临时文件再替换）。
public struct ChatStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// App 默认位置：Application Support/Chats。
    public static func applicationSupport() -> ChatStore {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return ChatStore(directory: base.appendingPathComponent("Chats", isDirectory: true))
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    /// 全部对话，最近更新的在前。读不出的文件跳过（不让一个坏文件拖垮整个列表）。
    public func list() -> [ChatSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = Self.makeDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(ChatSession.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id.uuidString < $1.id.uuidString }
    }

    public func summaries() -> [ChatSessionSummary] { list().map(ChatSessionSummary.init) }

    public func load(_ id: UUID) throws -> ChatSession {
        try Self.makeDecoder().decode(ChatSession.self, from: Data(contentsOf: url(for: id)))
    }

    /// 保存；空对话不存盘（若之前存过则删掉）。
    public func save(_ session: ChatSession) throws {
        if session.isEmpty {
            try delete(session.id)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.makeEncoder().encode(session).write(to: url(for: session.id), options: [.atomic])
    }

    public func delete(_ id: UUID) throws {
        let file = url(for: id)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }

    /// 改名；返回改名后的对话。
    @discardableResult
    public func rename(_ id: UUID, to title: String) throws -> ChatSession {
        var session = try load(id)
        session.rename(title)
        try save(session)
        return session
    }
}
