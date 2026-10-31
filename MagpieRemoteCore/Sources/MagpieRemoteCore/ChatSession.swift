import Foundation

/// 消息里附带的一张图片（已在 App 里缩小并转成 JPEG）。存盘时 `data` 编码为 base64。
public struct ChatAttachment: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var mediaType: String
    public var data: Data

    public init(id: UUID = UUID(), mediaType: String = "image/jpeg", data: Data) {
        self.id = id
        self.mediaType = mediaType
        self.data = data
    }

    /// OpenAI `image_url` 用的 data URL。
    public var dataURL: String { "data:\(mediaType);base64,\(data.base64EncodedString())" }
}

/// 实际回答的成员（来自响应头 `X-Magpie-Provider` / `X-Magpie-Model`，没有时取流里的 `model`）。
public struct ChatAnswerer: Codable, Hashable, Sendable {
    public var provider: String?
    public var model: String?

    public init(provider: String?, model: String?) {
        self.provider = provider
        self.model = model
    }

    /// 给用户看的一行，例如 `anthropic/claude-sonnet-4-6`。
    public var displayText: String? {
        switch (provider?.chatNonEmpty, model?.chatNonEmpty) {
        case let (_, model?) where model.contains("/"): model
        case let (provider?, model?): "\(provider)/\(model)"
        case let (nil, model?): model
        case let (provider?, nil): provider
        case (nil, nil): nil
        }
    }
}

/// 对话里的一条消息。
public struct ChatEntry: Codable, Hashable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable { case system, user, assistant }

    public var id: UUID
    public var role: Role
    public var text: String
    /// 模型的思考过程（`reasoning_content`），可能为空。
    public var reasoning: String
    public var images: [ChatAttachment]
    public var createdAt: Date
    public var answeredBy: ChatAnswerer?
    /// 这条回答出错时的中文说明（已收到的部分仍保留在 `text`）。
    public var errorMessage: String?
    /// 用户点了「停止」。
    public var stopped: Bool

    public init(id: UUID = UUID(), role: Role, text: String, reasoning: String = "", images: [ChatAttachment] = [],
                createdAt: Date = Date(), answeredBy: ChatAnswerer? = nil, errorMessage: String? = nil, stopped: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.images = images
        self.createdAt = createdAt
        self.answeredBy = answeredBy
        self.errorMessage = errorMessage
        self.stopped = stopped
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, reasoning, images, createdAt, answeredBy, errorMessage, stopped
    }

    /// 旧文件缺字段时用默认值，保证以后加字段不会读不出旧对话。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try c.decodeIfPresent(Role.self, forKey: .role) ?? .user
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning) ?? ""
        images = try c.decodeIfPresent([ChatAttachment].self, forKey: .images) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        answeredBy = try c.decodeIfPresent(ChatAnswerer.self, forKey: .answeredBy)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        stopped = try c.decodeIfPresent(Bool.self, forKey: .stopped) ?? false
    }
}

/// 一次对话（本地保存为一个 JSON 文件）。每个对话记住自己选的模型。
public struct ChatSession: Codable, Hashable, Identifiable, Sendable {
    public static let defaultTitle = "新对话"

    public var id: UUID
    public var title: String
    /// 用户是否手动改过标题（改过就不再按第一条消息自动命名）。
    public var titleIsCustom: Bool
    public var model: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var entries: [ChatEntry]

    public init(id: UUID = UUID(), title: String = ChatSession.defaultTitle, titleIsCustom: Bool = false, model: String? = nil,
                createdAt: Date = Date(), updatedAt: Date? = nil, entries: [ChatEntry] = []) {
        self.id = id
        self.title = title
        self.titleIsCustom = titleIsCustom
        self.model = model
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, titleIsCustom, model, createdAt, updatedAt, entries
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? Self.defaultTitle
        titleIsCustom = try c.decodeIfPresent(Bool.self, forKey: .titleIsCustom) ?? false
        model = try c.decodeIfPresent(String.self, forKey: .model)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        entries = try c.decodeIfPresent([ChatEntry].self, forKey: .entries) ?? []
    }

    /// 没有任何消息的对话不存盘。
    public var isEmpty: Bool { entries.isEmpty }

    /// 按第一条用户消息自动取标题（最多 20 个字符）；用户改过标题则不动。
    public mutating func autoTitle() {
        guard !titleIsCustom else { return }
        guard let first = entries.first(where: { $0.role == .user }) else { return }
        let line = first.text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if line.isEmpty {
            title = first.images.isEmpty ? Self.defaultTitle : "图片"
        } else {
            title = line.count > 20 ? String(line.prefix(20)) + "…" : line
        }
    }

    public mutating func rename(_ newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            titleIsCustom = false
            title = Self.defaultTitle
            autoTitle()
        } else {
            title = trimmed
            titleIsCustom = true
        }
    }
}

fileprivate extension String {
    var chatNonEmpty: String? { isEmpty ? nil : self }
}
