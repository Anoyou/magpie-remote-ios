import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - 请求

/// `POST /v1/chat/completions` 的请求体（只含 App 用到的字段）。
public struct ChatCompletionRequest: Encodable, Equatable, Sendable {
    public struct StreamOptions: Encodable, Equatable, Sendable {
        public var includeUsage: Bool
        enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
    }

    public struct Message: Encodable, Equatable, Sendable {
        public var role: String
        public var content: Content
    }

    /// 纯文字时是字符串；带图片时是 parts 数组。
    public enum Content: Encodable, Equatable, Sendable {
        case text(String)
        case parts([Part])

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text): try container.encode(text)
            case .parts(let parts): try container.encode(parts)
            }
        }
    }

    public enum Part: Encodable, Equatable, Sendable {
        case text(String)
        case imageURL(String, detail: String)

        private enum CodingKeys: String, CodingKey { case type, text, imageURL = "image_url" }
        private enum ImageKeys: String, CodingKey { case url, detail }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .imageURL(let url, let detail):
                try container.encode("image_url", forKey: .type)
                var image = container.nestedContainer(keyedBy: ImageKeys.self, forKey: .imageURL)
                try image.encode(url, forKey: .url)
                try image.encode(detail, forKey: .detail)
            }
        }
    }

    public var model: String
    public var stream: Bool
    public var streamOptions: StreamOptions?
    public var messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model, stream, streamOptions = "stream_options", messages
    }

    /// 由本地对话记录拼请求。
    /// - 出错且没有内容的回答、空消息不发；
    /// - `includeImages == false`（当前模型不支持图片）时历史里的图片不发，只发文字。
    public init(model: String, entries: [ChatEntry], system: String? = nil, includeImages: Bool = true, stream: Bool = true) {
        self.model = model
        self.stream = stream
        self.streamOptions = stream ? StreamOptions(includeUsage: true) : nil
        var messages: [Message] = []
        if let system, !system.isEmpty { messages.append(Message(role: "system", content: .text(system))) }
        for entry in entries {
            let images = includeImages && entry.role == .user ? entry.images : []
            if images.isEmpty {
                guard !entry.text.isEmpty else { continue }
                messages.append(Message(role: entry.role.rawValue, content: .text(entry.text)))
            } else {
                var parts: [Part] = []
                if !entry.text.isEmpty { parts.append(.text(entry.text)) }
                parts += images.map { .imageURL($0.dataURL, detail: "auto") }
                messages.append(Message(role: entry.role.rawValue, content: .parts(parts)))
            }
        }
        self.messages = messages
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

// MARK: - 流式事件

/// 用量（流最后的 `usage` 块）。
public struct ChatUsage: Equatable, Sendable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int
    public var cachedTokens: Int?
    public var reasoningTokens: Int?
}

/// 解码后的一段流式输出。
public enum ChatStreamEvent: Equatable, Sendable {
    /// 实际回答的成员：先是响应头（第一个事件，可能都为 nil），再是流里第一个块的 `model`。
    case served(ChatAnswerer)
    case content(String)
    case reasoning(String)
    case finished(reason: String)
    case usage(ChatUsage)
    /// `data: [DONE]`，或 EOF 前已经见过 `finish_reason`。
    case done
}

/// 把 SSE 事件逐个解成 `ChatStreamEvent`。
///
/// 规则（spec/gateway.md §4）：`: keepalive` 注释行由 `SSEParser` 跳过；`data: [DONE]` 结束；
/// 流中途出错是 `data: {"error":{…}}` 且之后没有 `[DONE]`；有的供应商不发 `[DONE]`，
/// 见过 `finish_reason` 后 EOF 也算完整。看不懂的块（如工具调用）忽略。
public struct ChatStreamDecoder: Sendable {
    public private(set) var sawFinish = false
    public private(set) var sawDone = false
    /// 流里第一个块的 `model`（响应头缺失时用来显示「由谁回答」）。
    public private(set) var chunkModel: String?

    public init() {}

    public mutating func decode(_ event: SSEEvent) throws -> [ChatStreamEvent] {
        if event.isDone {
            sawDone = true
            return [.done]
        }
        guard let data = event.data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        if let error = object["error"], !(error is NSNull) {
            let message: String?
            if let error = error as? [String: Any] { message = error["message"] as? String } else { message = error as? String }
            throw ChatErrors.midStream(message: message)
        }

        var out: [ChatStreamEvent] = []
        if chunkModel == nil, let model = object["model"] as? String, !model.isEmpty {
            chunkModel = model
            out.append(.served(ChatAnswerer(provider: nil, model: model)))
        }
        if let choices = object["choices"] as? [[String: Any]] {
            for choice in choices where (choice["index"] as? Int ?? 0) == 0 {
                if let delta = choice["delta"] as? [String: Any] {
                    if let reasoning = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String), !reasoning.isEmpty {
                        out.append(.reasoning(reasoning))
                    }
                    if let content = delta["content"] as? String, !content.isEmpty { out.append(.content(content)) }
                }
                if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
                    sawFinish = true
                    out.append(.finished(reason: reason))
                }
            }
        }
        if let usage = object["usage"] as? [String: Any] {
            let prompt = usage["prompt_tokens"] as? Int ?? 0
            let completion = usage["completion_tokens"] as? Int ?? 0
            out.append(.usage(ChatUsage(promptTokens: prompt,
                                        completionTokens: completion,
                                        totalTokens: usage["total_tokens"] as? Int ?? prompt + completion,
                                        cachedTokens: (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int,
                                        reasoningTokens: (usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int)))
        }
        return out
    }

    /// 流读完（EOF）。没见过 `[DONE]` 也没见过 `finish_reason` 说明被截断。
    public func finish() throws -> [ChatStreamEvent] {
        if sawDone { return [] }
        if sawFinish { return [.done] }
        throw ChatErrors.cutOff
    }

    /// 便于测试：一次解完整段 SSE 文本（EOF 规则同上）。
    public static func decodeAll(_ text: String) throws -> [ChatStreamEvent] {
        var parser = SSEParser()
        var decoder = ChatStreamDecoder()
        var out: [ChatStreamEvent] = []
        for event in parser.feed(chunk: text) {
            out += try decoder.decode(event)
            if decoder.sawDone { return out }
        }
        return out + (try decoder.finish())
    }
}

/// 一次回答累计下来的结果（UI 和测试共用）。
public struct ChatReply: Equatable, Sendable {
    public var text = ""
    public var reasoning = ""
    public var answeredBy: ChatAnswerer?
    public var finishReason: String?
    public var usage: ChatUsage?
    public var isComplete = false

    public init() {}

    public mutating func apply(_ event: ChatStreamEvent) {
        switch event {
        case .served(let answerer):
            // 先到的响应头优先；流里块的 `model` 只补缺。
            answeredBy = ChatAnswerer(provider: answeredBy?.provider ?? answerer.provider,
                                      model: answeredBy?.model ?? answerer.model)
        case .content(let text): self.text += text
        case .reasoning(let text): reasoning += text
        case .finished(let reason): finishReason = reason
        case .usage(let usage): self.usage = usage
        case .done: isComplete = true
        }
    }
}

// MARK: - 错误

/// 对话相关的中文错误。在 `MagpieError.from(status:body:model:)` 之前先认出对话特有的几种情况。
public enum ChatErrors {
    public static let readOnlyMessage = "这把网关密钥是只读的：只能查看额度和用量，不能用来对话。请在「主机」设置里换一把有完整权限的网关密钥。"

    public static func map(status: Int, body: Data?, model: String?) -> MagpieError {
        let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let error = object?["error"] as? [String: Any]
        let code = error?["code"] as? String
        let detail = body.flatMap(MagpieError.errorMessage(from:))
        let text = (detail ?? "").lowercased()
        switch status {
        case 403:
            if code == "gateway_key_read_only" || text.contains("read-only") { return .http(status: 403, message: readOnlyMessage) }
            if text.contains("may not use") || code == "model_not_allowed" { return .modelNotAllowed(model: model) }
            // 未共享（纯文本）、经代理未共享、不在允许列表：都按「未开启局域网共享」提示。
            if error == nil || text.contains("shared") || text.contains("allow list") || text.contains("proxy") {
                return .lanSharingOff(detail: detail)
            }
            return MagpieError.from(status: status, body: body, model: model)
        case 404 where error != nil:
            // JSON 404 是「没有这个模型」，不是主机太旧（主机太旧时是纯文本 404）。
            let name = model.map { "「\($0)」" } ?? ""
            return .http(status: 404, message: "主机上没有模型\(name)，请重新选择模型。")
        case 413:
            return .http(status: 413, message: "这条消息太大了（图片太多或太大），请减少图片后再试。")
        case 429:
            if text.contains("too many failed") { return .http(status: 429, message: "密钥错误次数太多，主机暂时拒绝了请求，请稍后再试。") }
            return .http(status: 429, message: "这把网关密钥已达到用量上限或请求太频繁，请稍后再试。")
        case 503 where text.contains("limit"):
            return .http(status: 503, message: "这把网关密钥设置了用量上限，但主机上的「密钥限额」插件没有开启，请在 magpie 里开启后再试。")
        default:
            return MagpieError.from(status: status, body: body, model: model)
        }
    }

    /// 流里途中出现的 `{"error":…}`。
    public static func midStream(message: String?) -> MagpieError {
        let detail = message.flatMap { $0.isEmpty ? nil : $0 }.map { "（\($0)）" } ?? ""
        return .http(status: 502, message: "模型回答到一半出错了\(detail)，已保留收到的部分，可以重新发送。")
    }

    /// 连接在回答结束前断开。
    public static let cutOff = MagpieError.http(status: 502, message: "连接在回答结束前断开了，已保留收到的部分，可以重新发送。")
}

// MARK: - 客户端

extension GatewayClient {
    /// `GET /v1/models`，整理成模型选择器用的目录。
    public func chatModels() async throws -> ModelCatalog {
        let request = try makeRequest("/v1/models")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MagpieError.from(error)
        }
        guard let http = response as? HTTPURLResponse else { throw MagpieError.unreachable(.other) }
        guard (200..<300).contains(http.statusCode) else { throw ChatErrors.map(status: http.statusCode, body: data, model: nil) }
        return try ModelCatalog.decode(data)
    }

    /// 拼 `POST /v1/chat/completions` 请求（流式）。
    public func makeChatRequest(_ body: ChatCompletionRequest, sessionID: UUID? = nil) throws -> URLRequest {
        var request = try makeRequest("/v1/chat/completions", method: "POST", body: try body.encoded())
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID { request.setValue(sessionID.uuidString.lowercased(), forHTTPHeaderField: "X-Magpie-Session") }
        // 流式回答两段数据之间可能隔很久（模型在思考）；这里是空闲超时，不是总时长。
        request.timeoutInterval = max(timeout, 300)
        return request
    }

    /// 流式对话。第一个事件总是 `.served`（响应头里实际回答的成员）；之后逐段输出；以 `.done` 正常结束，
    /// 出错时抛 `MagpieError`（中文）。取消读取（例如点「停止」）会断开连接。
    public func chatStream(_ body: ChatCompletionRequest, sessionID: UUID? = nil) -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        let session = self.session
        let model = body.model
        let built = Result { try makeChatRequest(body, sessionID: sessionID) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try built.get()
                    #if canImport(Darwin)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw MagpieError.unreachable(.other) }
                    try await ChatStreamDecoder.pump(bytes, response: http, model: model, into: continuation)
                    #else
                    let (data, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse else { throw MagpieError.unreachable(.other) }
                    try await ChatStreamDecoder.pump(ChatStreamDecoder.byteSequence(data), response: http, model: model, into: continuation)
                    #endif
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: MagpieError.from(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension ChatStreamDecoder {
    /// 实际回答的成员（响应头 `X-Magpie-Provider` / `X-Magpie-Model`）。
    public static func answerer(from response: HTTPURLResponse) -> ChatAnswerer {
        ChatAnswerer(provider: response.value(forHTTPHeaderField: "X-Magpie-Provider"),
                     model: response.value(forHTTPHeaderField: "X-Magpie-Model"))
    }

    /// 把一段字节（整段 Data）变成异步字节序列，便于测试与非 Apple 平台。
    public static func byteSequence(_ data: Data) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            for byte in data { continuation.yield(byte) }
            continuation.finish()
        }
    }

    /// 读一个 HTTP 流式回答：非 2xx 读出响应体转成中文错误抛出；否则先输出 `.served`，再按行解析 SSE，
    /// 见到 `[DONE]` 即停；EOF 时按「见过 finish_reason 也算完整」的规则收尾。
    public static func pump<Bytes: AsyncSequence>(_ bytes: Bytes, response: HTTPURLResponse, model: String?,
                                                  into continuation: AsyncThrowingStream<ChatStreamEvent, any Error>.Continuation) async throws
        where Bytes.Element == UInt8 {
        guard (200..<300).contains(response.statusCode) else {
            var body = Data()
            for try await byte in bytes { body.append(byte); if body.count > 64_000 { break } }
            throw ChatErrors.map(status: response.statusCode, body: body, model: model)
        }
        continuation.yield(.served(answerer(from: response)))
        var parser = SSEParser()
        var decoder = ChatStreamDecoder()
        func emit(_ text: String) throws -> Bool {
            for event in parser.feed(chunk: text) {
                for decoded in try decoder.decode(event) { continuation.yield(decoded) }
                if decoder.sawDone { return true }
            }
            return false
        }
        // 不用 `bytes.lines`：它会吞掉空行，而空行正是 SSE 的事件分隔符。按字节攒到换行再整行交给解析器。
        var line = Data()
        var finished = false
        for try await byte in bytes {
            line.append(byte)
            if byte == 0x0A {
                finished = try emit(String(decoding: line, as: UTF8.self))
                line.removeAll(keepingCapacity: true)
                if finished { break }
            }
        }
        if !finished, !line.isEmpty { finished = try emit(String(decoding: line, as: UTF8.self) + "\n") }
        try Task.checkCancellation()
        if !finished {
            for event in try decoder.finish() { continuation.yield(event) }
        }
    }
}
