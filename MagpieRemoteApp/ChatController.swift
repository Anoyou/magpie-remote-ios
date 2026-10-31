import Foundation
import Observation
import MagpieRemoteCore

/// 「对话」页的状态：本地对话列表、当前对话、模型目录、正在进行的流式回答。
/// 对话只保存在这台 iPhone 上（`ChatStore`），每个对话记住自己选的模型。
@MainActor
@Observable
final class ChatController {
    private static let lastModelKey = "chat.lastModel"

    let store: ChatStore
    @ObservationIgnored private let defaults: UserDefaults?

    private(set) var sessions: [ChatSessionSummary] = []
    private(set) var session: ChatSession
    private(set) var catalog: ModelCatalog?
    private(set) var catalogError: MagpieError?
    private(set) var loadingModels = false
    /// 正在流式输出的那条回答。
    private(set) var streamingEntryID: UUID?
    /// 存盘失败等页面级提示。
    var notice: String?

    var draft = ""
    var pendingImages: [ChatAttachment] = []

    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var catalogHostID: UUID?

    init(store: ChatStore, defaults: UserDefaults?) {
        self.store = store
        self.defaults = defaults
        self.session = ChatSession(model: defaults?.string(forKey: Self.lastModelKey))
        self.sessions = store.summaries()
    }

    // MARK: 状态

    var isStreaming: Bool { streamingEntryID != nil }
    var selectedModel: GatewayModel? { catalog?.model(id: session.model) }
    var canAttachImages: Bool { selectedModel?.supportsImages == true }
    /// 带了图片但当前模型不支持图片。
    var imagesBlocked: Bool { !pendingImages.isEmpty && !canAttachImages }

    var canSend: Bool {
        guard !isStreaming, session.model != nil, !imagesBlocked else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty
    }

    /// 选择器上显示的当前模型名（目录还没加载时显示 id）。
    var selectedModelTitle: String {
        if let selectedModel { return selectedModel.title }
        if let id = session.model { return id }
        return "选择模型"
    }

    // MARK: 模型

    func loadModels(app: AppModel, force: Bool = false) async {
        guard let host = app.activeHost else { return }
        if !force, catalogHostID == host.id, catalog != nil { return }
        loadingModels = true
        defer { loadingModels = false }
        do {
            let catalog = try await app.chatModels()
            guard app.activeHost?.id == host.id else { return }
            self.catalog = catalog
            catalogError = nil
            catalogHostID = host.id
            // 新对话（或选的模型这台主机上没有）自动选一个；已有消息的对话保留它原来的模型。
            if session.model == nil || (session.isEmpty && catalog.model(id: session.model) == nil) {
                session.model = catalog.defaultModel(preferring: defaults?.string(forKey: Self.lastModelKey))?.id
            }
        } catch {
            let error = MagpieError.from(error)
            if error == .cancelled { return }
            catalogError = error
        }
    }

    func selectModel(_ id: String) {
        session.model = id
        defaults?.set(id, forKey: Self.lastModelKey)
        if catalog?.model(id: id)?.supportsImages != true { pendingImages.removeAll() }
        persist()
    }

    // MARK: 发送 / 停止

    func send(app: AppModel) {
        guard canSend, let model = session.model else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        let includeImages = canAttachImages
        draft = ""
        pendingImages = []
        notice = nil

        session.entries.append(ChatEntry(role: .user, text: text, images: images))
        let request = ChatCompletionRequest(model: model, entries: session.entries, includeImages: includeImages)
        let reply = ChatEntry(role: .assistant, text: "")
        session.entries.append(reply)
        session.autoTitle()
        session.updatedAt = Date()
        persist()

        streamingEntryID = reply.id
        let stream = app.chatStream(request, sessionID: session.id)
        let sessionID = session.id
        streamTask = Task { [weak self] in
            await self?.consume(stream, entryID: reply.id, sessionID: sessionID)
        }
    }

    private func consume(_ stream: AsyncThrowingStream<ChatStreamEvent, any Error>, entryID: UUID, sessionID: UUID) async {
        var reply = ChatReply()
        do {
            for try await event in stream {
                reply.apply(event)
                let snapshot = reply
                update(entryID, in: sessionID) { entry in
                    entry.text = snapshot.text
                    entry.reasoning = snapshot.reasoning
                    entry.answeredBy = snapshot.answeredBy
                }
            }
            if Task.isCancelled {
                update(entryID, in: sessionID) { $0.stopped = true }
            }
        } catch {
            let error = MagpieError.from(error)
            let cancelled = error == .cancelled || Task.isCancelled
            update(entryID, in: sessionID) { entry in
                if cancelled {
                    entry.stopped = true
                } else {
                    entry.errorMessage = error.title + "：" + error.message
                }
            }
        }
        if streamingEntryID == entryID {
            streamingEntryID = nil
            streamTask = nil
        }
        if session.id == sessionID {
            session.updatedAt = Date()
            persist()
        }
    }

    /// 点「停止」：断开连接，保留已收到的部分。
    func stop() {
        guard let task = streamTask else { return }
        task.cancel()
        if let id = streamingEntryID {
            update(id, in: session.id) { $0.stopped = true }
            streamingEntryID = nil
        }
        streamTask = nil
        persist()
    }

    private func update(_ entryID: UUID, in sessionID: UUID, _ change: (inout ChatEntry) -> Void) {
        guard session.id == sessionID, let index = session.entries.firstIndex(where: { $0.id == entryID }) else { return }
        change(&session.entries[index])
    }

    // MARK: 对话列表

    func newChat() {
        stop()
        draft = ""
        pendingImages = []
        notice = nil
        let model = session.model ?? defaults?.string(forKey: Self.lastModelKey)
        session = ChatSession(model: model)
        refreshList()
    }

    func open(_ id: UUID) {
        guard id != session.id else { return }
        stop()
        do {
            session = try store.load(id)
            draft = ""
            pendingImages = []
            notice = nil
        } catch {
            notice = "这个对话读不出来了，可能文件已损坏。"
            refreshList()
        }
    }

    func delete(_ id: UUID) {
        let isCurrent = id == session.id
        if isCurrent { stop() }
        do {
            try store.delete(id)
        } catch {
            notice = "删除失败：\(error.localizedDescription)"
        }
        if isCurrent {
            session.entries = []
            newChat()
        } else {
            refreshList()
        }
    }

    func rename(_ id: UUID, to title: String) {
        if id == session.id {
            session.rename(title)
            persist()
            return
        }
        do {
            try store.rename(id, to: title)
        } catch {
            notice = "重命名失败：\(error.localizedDescription)"
        }
        refreshList()
    }

    func refreshList() {
        sessions = store.summaries()
    }

    private func persist() {
        do {
            try store.save(session)
        } catch {
            notice = "对话没能保存到本机：\(error.localizedDescription)"
        }
        refreshList()
    }
}
