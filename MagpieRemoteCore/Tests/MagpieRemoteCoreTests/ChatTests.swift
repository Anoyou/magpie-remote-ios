import XCTest
@testable import MagpieRemoteCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 对话：模型目录、请求拼装、流式解码、错误映射、本地保存。
/// fixture 在 Tests/MagpieRemoteCoreTests/Fixtures/chat（网关契约示例 + 真实 magpie v0.1.2438 抓包，见该目录 README）。
enum ChatFixture {
    /// 作为测试资源打包（Package.swift `.copy("Fixtures")`）。
    static var directory: URL {
        get throws { try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures/chat", isDirectory: true) }
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func text(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }
}

final class ChatModelCatalogTests: XCTestCase {
    func testGatewayFixtureSplitsGroupsAndProviders() throws {
        let catalog = try ModelCatalog.decode(ChatFixture.data("models.json"))
        XCTAssertEqual(catalog.models.count, 5)
        XCTAssertEqual(catalog.routingGroups.map(\.id), ["group/coding", "auto/gpt-5.5"])
        XCTAssertEqual(catalog.providers.map(\.id), ["anthropic", "codex", "deepseek"])
        XCTAssertEqual(catalog.providers.map(\.name), ["Anthropic", "Codex", "DeepSeek"])
        XCTAssertEqual(catalog.providers.first?.models.first?.title, "Claude Sonnet 4.6")

        let sonnet = try XCTUnwrap(catalog.model(id: "anthropic/claude-sonnet-4-6"))
        XCTAssertTrue(sonnet.supportsImages)
        XCTAssertFalse(sonnet.isRoutingGroup)
        XCTAssertTrue(try XCTUnwrap(catalog.model(id: "group/coding")).supportsImages)
        XCTAssertFalse(try XCTUnwrap(catalog.model(id: "deepseek/deepseek-chat")).supportsImages)
        XCTAssertEqual(catalog.defaultModel(preferring: nil)?.id, "group/coding")
        XCTAssertEqual(catalog.defaultModel(preferring: "deepseek/deepseek-chat")?.id, "deepseek/deepseek-chat")
        XCTAssertEqual(catalog.defaultModel(preferring: "gone/model")?.id, "group/coding")
    }

    func testLiveCatalogWithoutModalitiesIsTextOnly() throws {
        let catalog = try ModelCatalog.decode(ChatFixture.data("live-v1-models.json"))
        XCTAssertEqual(catalog.routingGroups.map(\.id), ["group/fast"])
        XCTAssertEqual(catalog.routingGroups.first?.title, "fast")
        XCTAssertEqual(catalog.providers.map(\.name), ["Mock"])
        XCTAssertEqual(catalog.providers.first?.models.map(\.id), ["mock/mock-gpt-1", "mock/mock-gpt-mini"])
        XCTAssertFalse(catalog.models.contains(where: \.supportsImages))
    }

    func testEmptyAndMinimalCatalogs() throws {
        XCTAssertTrue(try ModelCatalog.decode(ChatFixture.data("models-empty.json")).isEmpty)
        let minimal = try ModelCatalog.decode(Data(#"{"data":[{"id":"bare"},{"id":"x/y","modalities":{}}]}"#.utf8))
        XCTAssertEqual(minimal.models.map(\.title), ["bare", "y"])
        XCTAssertEqual(minimal.providers.map(\.name), ["其它", "x"])
        XCTAssertThrowsError(try ModelCatalog.decode(Data("not json".utf8))) { error in
            guard case .decoding = error as? MagpieError else { return XCTFail("应为 decoding，实际 \(error)") }
        }
    }
}

final class ChatRequestTests: XCTestCase {
    func testTextRequestShape() throws {
        let entries = [
            ChatEntry(role: .user, text: "你好"),
            ChatEntry(role: .assistant, text: "", errorMessage: "出错"),   // 出错且没内容：不发
            ChatEntry(role: .assistant, text: "在的"),
            ChatEntry(role: .user, text: "再见"),
        ]
        let body = try ChatCompletionRequest(model: "group/fast", entries: entries).encoded()
        XCTAssertEqual(String(decoding: body, as: UTF8.self),
                       #"{"messages":[{"content":"你好","role":"user"},{"content":"在的","role":"assistant"},{"content":"再见","role":"user"}],"model":"group/fast","stream":true,"stream_options":{"include_usage":true}}"#)
    }

    func testImageRequestMatchesGatewayFixture() throws {
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: ChatFixture.data("chat-request-image.json")) as? [String: Any])
        let jpeg = try XCTUnwrap(Data(base64Encoded: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJ"))
        let request = ChatCompletionRequest(model: "group/coding",
                                            entries: [ChatEntry(role: .user, text: "What is in this picture?", images: [ChatAttachment(data: jpeg)])],
                                            system: "You are a helpful assistant.")
        let ours = try XCTUnwrap(JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any])
        XCTAssertEqual(ours["model"] as? String, fixture["model"] as? String)
        XCTAssertEqual(ours["stream"] as? Bool, true)
        XCTAssertEqual(NSDictionary(dictionary: ours["stream_options"] as? [String: Any] ?? [:]),
                       NSDictionary(dictionary: fixture["stream_options"] as? [String: Any] ?? [:]))
        XCTAssertEqual(NSArray(array: ours["messages"] as? [Any] ?? []), NSArray(array: fixture["messages"] as? [Any] ?? []))
    }

    func testImagesDroppedForTextOnlyModel() throws {
        let entries = [ChatEntry(role: .user, text: "看图", images: [ChatAttachment(data: Data([1, 2, 3]))]),
                       ChatEntry(role: .user, text: "", images: [ChatAttachment(data: Data([4]))])]
        let request = ChatCompletionRequest(model: "deepseek/deepseek-chat", entries: entries, includeImages: false)
        XCTAssertEqual(request.messages, [.init(role: "user", content: .text("看图"))])
        let withImages = ChatCompletionRequest(model: "group/coding", entries: entries)
        XCTAssertEqual(withImages.messages.last, .init(role: "user", content: .parts([.imageURL("data:image/jpeg;base64,BA==", detail: "auto")])))
    }

    func testChatRequestHeaders() throws {
        let client = GatewayClient(baseURL: URL(string: "http://100.64.0.1:3425")!, key: "sk-magpie-key-EXAMPLE")
        let session = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let request = try client.makeChatRequest(ChatCompletionRequest(model: "m", entries: [ChatEntry(role: .user, text: "hi")]), sessionID: session)
        XCTAssertEqual(request.url?.absoluteString, "http://100.64.0.1:3425/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-magpie-key-EXAMPLE")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Magpie-Session"), "6f9619ff-8b86-d011-b42d-00c04fc964ff")
        XCTAssertGreaterThanOrEqual(request.timeoutInterval, 300)
    }
}

final class ChatStreamDecoderTests: XCTestCase {
    private func reply(_ events: [ChatStreamEvent]) -> ChatReply {
        var reply = ChatReply()
        events.forEach { reply.apply($0) }
        return reply
    }

    func testTranslatedStreamWithReasoningKeepaliveAndUsage() throws {
        let events = try ChatStreamDecoder.decodeAll(ChatFixture.text("chat-completions-stream.sse"))
        let result = reply(events)
        XCTAssertEqual(result.text, "A tabby cat asleep on a laptop keyboard.")
        XCTAssertEqual(result.reasoning, "The user asks what is in the image. It shows a cat.")
        XCTAssertEqual(result.finishReason, "stop")
        XCTAssertEqual(result.usage, ChatUsage(promptTokens: 1312, completionTokens: 48, totalTokens: 1360, cachedTokens: 1024, reasoningTokens: 21))
        XCTAssertEqual(result.answeredBy?.model, "claude-sonnet-4-6")
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(events.last, .done)
    }

    func testLiveStreamsDecode() throws {
        for name in ["live-v1-chat-completions-stream.sse", "live-v1-chat-completions-group-stream.sse", "chat-completions-stream-passthrough.sse"] {
            let result = reply(try ChatStreamDecoder.decodeAll(ChatFixture.text(name)))
            XCTAssertTrue(result.isComplete, name)
            XCTAssertEqual(result.finishReason, "stop", name)
            XCTAssertEqual(result.usage?.totalTokens, 19, name)
            XCTAssertFalse(result.text.isEmpty, name)
        }
        XCTAssertEqual(reply(try ChatStreamDecoder.decodeAll(ChatFixture.text("live-v1-chat-completions-stream.sse"))).text,
                       "Hello from the mock upstream. ")
    }

    func testDeltasArriveIncrementally() throws {
        var parser = SSEParser()
        var decoder = ChatStreamDecoder()
        var contents: [String] = []
        let text = try ChatFixture.text("live-v1-chat-completions-group-stream.sse")
        // 一次只喂 7 个字节，模拟网络分片。
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            let piece = String(decoding: bytes[index..<min(index + 7, bytes.count)], as: UTF8.self)
            index += 7
            for event in parser.feed(chunk: piece) {
                for decoded in try decoder.decode(event) { if case .content(let c) = decoded { contents.append(c) } }
            }
        }
        XCTAssertEqual(contents, ["Hello ", "from ", "the ", "mock ", "upstream. "])
        XCTAssertTrue(decoder.sawDone)
    }

    func testMidStreamErrorKeepsPartialAndMapsToChinese() throws {
        var parser = SSEParser()
        var decoder = ChatStreamDecoder()
        var partial = ChatReply()
        var thrown: MagpieError?
        do {
            for event in parser.feed(chunk: try ChatFixture.text("chat-completions-stream-error.sse")) {
                for decoded in try decoder.decode(event) { partial.apply(decoded) }
            }
        } catch {
            thrown = error as? MagpieError
        }
        XCTAssertEqual(partial.text, "Partial answer")
        guard case .http(502, let message)? = thrown else { return XCTFail("应为 502 中文错误，实际 \(String(describing: thrown))") }
        XCTAssertTrue(message?.contains("回答到一半出错") ?? false)
        XCTAssertTrue(message?.contains("upstream closed the stream") ?? false)
    }

    func testToolCallsIgnoredAndEOFRules() throws {
        let tool = reply(try ChatStreamDecoder.decodeAll(ChatFixture.text("chat-completions-stream-toolcall.sse")))
        XCTAssertEqual(tool.text, "")
        XCTAssertEqual(tool.finishReason, "tool_calls")

        // 没有 [DONE]，但见过 finish_reason：算完整。
        let noDone = #"data: {"choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}]}"# + "\n\n" +
            #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"# + "\n\n"
        XCTAssertEqual(try ChatStreamDecoder.decodeAll(noDone).last, .done)

        // 既没有 [DONE] 也没有 finish_reason：被截断。
        let cut = #"data: {"choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}]}"# + "\n\n"
        XCTAssertThrowsError(try ChatStreamDecoder.decodeAll(cut)) { XCTAssertEqual($0 as? MagpieError, ChatErrors.cutOff) }

        // `"error": null` 不是错误；看不懂的 data 忽略。
        XCTAssertEqual(try ChatStreamDecoder.decodeAll("data: {\"error\":null}\n\ndata: oops\n\ndata: [DONE]\n\n"), [.done])
    }

    func testHeaderAnswererWinsOverChunkModel() {
        var result = ChatReply()
        result.apply(.served(ChatAnswerer(provider: "mock", model: "mock/mock-gpt-1")))
        result.apply(.served(ChatAnswerer(provider: nil, model: "mock-gpt-1")))
        XCTAssertEqual(result.answeredBy?.displayText, "mock/mock-gpt-1")
        XCTAssertEqual(ChatAnswerer(provider: "anthropic", model: "claude").displayText, "anthropic/claude")
        XCTAssertEqual(ChatAnswerer(provider: nil, model: nil).displayText, nil)
    }
}

final class ChatErrorTests: XCTestCase {
    func testChatErrorMapping() throws {
        XCTAssertEqual(ChatErrors.map(status: 401, body: try ChatFixture.data("error-invalid-key-401.json"), model: "m"), .invalidKey)
        XCTAssertEqual(ChatErrors.map(status: 403, body: try ChatFixture.data("error-model-not-allowed-403.json"), model: "deepseek/deepseek-chat"),
                       .modelNotAllowed(model: "deepseek/deepseek-chat"))
        XCTAssertEqual(ChatErrors.map(status: 403, body: try ChatFixture.data("live-err-held-chat-model-not-allowed.json"), model: "mock/mock-gpt-mini"),
                       .modelNotAllowed(model: "mock/mock-gpt-mini"))
        for name in ["error-not-shared-403.txt", "error-not-shared-proxied-403.txt"] {
            guard case .lanSharingOff = ChatErrors.map(status: 403, body: try ChatFixture.data(name), model: nil) else {
                return XCTFail("\(name) 应为未开启局域网共享")
            }
        }
        XCTAssertEqual(ChatErrors.map(status: 403, body: try ChatFixture.data("live-err-readonly-chat.json"), model: "m"),
                       .http(status: 403, message: ChatErrors.readOnlyMessage))
        for (name, model) in [("error-unknown-model-404.json", "anthropic/claude-sonet-4-6"), ("live-err-model-unknown.json", "nosuch/model")] {
            guard case .http(404, let message) = ChatErrors.map(status: 404, body: try ChatFixture.data(name), model: model) else {
                return XCTFail("\(name)：未知模型应为 404 中文提示")
            }
            XCTAssertTrue(message?.contains("没有模型「\(model)」") ?? false, name)
        }
        // 纯文本 404 仍按「主机版本不兼容」。
        guard case .incompatibleHost = ChatErrors.map(status: 404, body: Data("404 page not found".utf8), model: nil) else {
            return XCTFail("纯文本 404 应为版本不兼容")
        }
        guard case .http(429, let limit) = ChatErrors.map(status: 429, body: Data(#"{"error":{"message":"magpie gateway key \"x\" has used 10 of its 5 tokens"}}"#.utf8), model: nil) else {
            return XCTFail("429 应为中文用量提示")
        }
        XCTAssertTrue(limit?.contains("用量上限") ?? false)
    }
}

final class ChatClientTests: XCTestCase {
    private var session: URLSession!
    private let base = URL(string: "http://100.64.0.1:3425")!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
    }

    private var client: GatewayClient { GatewayClient(baseURL: base, key: "sk-magpie-key-EXAMPLE", session: session) }

    func testModelsRequest() async throws {
        let body = try ChatFixture.data("models.json")
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], body) }
        let catalog = try await client.chatModels()
        XCTAssertEqual(catalog.models.count, 5)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/v1/models")
    }

    func testModelsErrorIsMapped() async throws {
        let body = try ChatFixture.data("live-err-readonly-chat.json")
        StubURLProtocol.handler = { _ in (403, ["Content-Type": "application/json"], body) }
        do {
            _ = try await client.chatModels()
            XCTFail("应失败")
        } catch {
            XCTAssertEqual(error as? MagpieError, .http(status: 403, message: ChatErrors.readOnlyMessage))
        }
    }

    /// 用 fixture 字节直接驱动流解析（不经网络；Apple 平台上 URLSession.bytes 配合 URLProtocol 桩会卡住）。
    private func pump(_ fixture: String, status: Int = 200, headers: [String: String] = [:], model: String) async throws -> [ChatStreamEvent] {
        let data = try ChatFixture.data(fixture)
        let response = HTTPURLResponse(url: base.appendingPathComponent("v1/chat/completions"), statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        let stream = AsyncThrowingStream<ChatStreamEvent, any Error> { continuation in
            Task {
                do {
                    try await ChatStreamDecoder.pump(ChatStreamDecoder.byteSequence(data), response: response, model: model, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        var events: [ChatStreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    func testStreamYieldsServedHeadersThenDeltas() async throws {
        // 真实 magpie（v0.1.2438）对路由组的回答带这两个响应头。
        let events = try await pump("live-v1-chat-completions-group-stream.sse",
                                    headers: ["Content-Type": "text/event-stream", "X-Magpie-Provider": "mock", "X-Magpie-Model": "mock/mock-gpt-1"],
                                    model: "group/fast")
        XCTAssertEqual(events.first, .served(ChatAnswerer(provider: "mock", model: "mock/mock-gpt-1")))
        var reply = ChatReply()
        events.forEach { reply.apply($0) }
        XCTAssertEqual(reply.answeredBy?.displayText, "mock/mock-gpt-1")
        XCTAssertEqual(reply.text, "Hello from the mock upstream. ")
        XCTAssertTrue(reply.isComplete)
    }

    func testStreamHTTPErrorBeforeFirstByte() async throws {
        do {
            _ = try await pump("error-model-not-allowed-403.json", status: 403, model: "deepseek/deepseek-chat")
            XCTFail("应失败")
        } catch {
            XCTAssertEqual(error as? MagpieError, .modelNotAllowed(model: "deepseek/deepseek-chat"))
        }
    }

    func testStreamMidStreamError() async throws {
        let data = try ChatFixture.data("chat-completions-stream-error.sse")
        let response = HTTPURLResponse(url: base, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        var reply = ChatReply()
        let stream = AsyncThrowingStream<ChatStreamEvent, any Error> { continuation in
            Task {
                do {
                    try await ChatStreamDecoder.pump(ChatStreamDecoder.byteSequence(data), response: response, model: "m", into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        do {
            for try await event in stream { reply.apply(event) }
            XCTFail("应失败")
        } catch {
            guard case .http(502, _)? = error as? MagpieError else { return XCTFail("应为 502，实际 \(error)") }
        }
        XCTAssertEqual(reply.text, "Partial answer")
        XCTAssertEqual(reply.answeredBy?.model, "claude-sonnet-4-6")
    }

    #if !canImport(Darwin)
    /// 走完整的 chatStream（非 Apple 平台整段读取，可用 URLProtocol 桩）。
    func testChatStreamOverStubbedSession() async throws {
        let body = try ChatFixture.data("live-v1-chat-completions-stream.sse")
        StubURLProtocol.handler = { _ in (200, ["X-Magpie-Provider": "mock", "X-Magpie-Model": "mock/mock-gpt-1"], body) }
        var reply = ChatReply()
        for try await event in client.chatStream(ChatCompletionRequest(model: "mock/mock-gpt-1", entries: [ChatEntry(role: .user, text: "hi")])) {
            reply.apply(event)
        }
        XCTAssertEqual(reply.text, "Hello from the mock upstream. ")
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")
    }

    func testUnreachableHost() async {
        StubURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        do {
            for try await _ in client.chatStream(ChatCompletionRequest(model: "m", entries: [ChatEntry(role: .user, text: "x")])) {}
            XCTFail("应失败")
        } catch {
            XCTAssertEqual(error as? MagpieError, .unreachable(.refused))
        }
    }
    #endif
}

final class ChatStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("chatstore-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testSaveListLoadRenameDelete() throws {
        let store = ChatStore(directory: directory)
        XCTAssertEqual(store.list(), [])

        let firstLine = "第一行很长很长很长很长很长很长很长很长很长很长的标题"
        var older = ChatSession(model: "group/fast", createdAt: Date(timeIntervalSince1970: 1_000))
        older.entries = [ChatEntry(role: .user, text: firstLine + "\n第二行", createdAt: Date(timeIntervalSince1970: 1_000)),
                         ChatEntry(role: .assistant, text: "**好的**", createdAt: Date(timeIntervalSince1970: 1_001),
                                   answeredBy: ChatAnswerer(provider: "mock", model: "mock/mock-gpt-1"))]
        older.autoTitle()
        let autoTitle = String(firstLine.prefix(20)) + "…"
        XCTAssertEqual(older.title, autoTitle)
        try store.save(older)

        var newer = ChatSession(model: "anthropic/claude-sonnet-4-6", createdAt: Date(timeIntervalSince1970: 2_000))
        newer.entries = [ChatEntry(role: .user, text: "", images: [ChatAttachment(data: Data([0xFF, 0xD8]))], createdAt: Date(timeIntervalSince1970: 2_000))]
        newer.autoTitle()
        XCTAssertEqual(newer.title, "图片")
        try store.save(newer)

        // 空对话不存盘。
        try store.save(ChatSession())

        let listed = store.list()
        XCTAssertEqual(listed.map(\.id), [newer.id, older.id])
        XCTAssertEqual(try store.load(older.id), older)
        XCTAssertEqual(try store.load(newer.id).entries.first?.images.first?.data, Data([0xFF, 0xD8]))
        XCTAssertEqual(store.summaries().map(\.messageCount), [1, 2])

        let renamed = try store.rename(older.id, to: "  我的对话  ")
        XCTAssertEqual(renamed.title, "我的对话")
        XCTAssertTrue(renamed.titleIsCustom)
        var reloaded = try store.load(older.id)
        reloaded.autoTitle()
        XCTAssertEqual(reloaded.title, "我的对话", "改过名后不再自动命名")
        XCTAssertEqual(try store.rename(older.id, to: " ").title, autoTitle, "清空名字恢复自动命名")

        try store.delete(older.id)
        XCTAssertEqual(store.list().map(\.id), [newer.id])
        try store.delete(older.id) // 再删一次不报错

        // 保存成空对话等于删除。
        newer.entries = []
        try store.save(newer)
        XCTAssertEqual(store.list(), [])
    }

    func testCorruptFileIsSkippedAndOldFormatDecodes() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: directory.appendingPathComponent("broken.json"))
        let id = UUID()
        let minimal = #"{"id":"\#(id.uuidString)","entries":[{"role":"user","text":"旧格式"}]}"#
        try Data(minimal.utf8).write(to: directory.appendingPathComponent(id.uuidString.lowercased() + ".json"))
        let listed = ChatStore(directory: directory).list()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.title, ChatSession.defaultTitle)
        XCTAssertEqual(listed.first?.entries.first?.text, "旧格式")
        XCTAssertEqual(listed.first?.entries.first?.images, [])
    }
}
