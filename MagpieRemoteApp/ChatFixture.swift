import Foundation
import MagpieRemoteCore

/// fixture 模式下「对话」页的示例数据：假的模型目录与一段假的流式回答，不访问网络。
enum FixtureChat {
    static let catalog = ModelCatalog(models: [
        GatewayModel(id: "group/example-fast", displayName: "示例路由组", label: "示例路由组 · routing group",
                     ownedBy: "example", inputModalities: ["text", "image"]),
        GatewayModel(id: "example/example-model-1", displayName: "示例模型 1", label: "示例模型 1 · 示例供应商 A",
                     ownedBy: "example", inputModalities: ["text", "image"]),
        GatewayModel(id: "example/example-text", displayName: "示例纯文字模型", label: "示例纯文字模型 · 示例供应商 A",
                     ownedBy: "example", inputModalities: ["text"]),
        GatewayModel(id: "demo/demo-model", displayName: "示例模型 B", label: "示例模型 B · 示例供应商 B",
                     ownedBy: "demo", inputModalities: ["text"]),
    ])

    /// 回答的人：路由组时假装是组里的第一个成员，否则就是所选模型。
    static func answerer(for model: String) -> ChatAnswerer {
        if model.hasPrefix("group/") { return ChatAnswerer(provider: "example", model: "example/example-model-1") }
        let provider = model.split(separator: "/").first.map(String.init)
        return ChatAnswerer(provider: provider, model: model)
    }

    static func stream(for request: ChatCompletionRequest) -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        let lastUser: String = request.messages.last(where: { $0.role == "user" }).map { message in
            switch message.content {
            case .text(let text): return text
            case .parts(let parts):
                let texts = parts.compactMap { part -> String? in if case .text(let text) = part { return text } else { return nil } }
                let images = parts.count - texts.count
                return texts.joined(separator: " ") + (images > 0 ? "（\(images) 张图片）" : "")
            }
        } ?? ""
        let pieces = ["这是", "**示例**", "流式回复", "：已收到", "「\(lastUser)」", "。\n\n", "- 第一点\n", "- 第二点 `code`"]
        let answerer = answerer(for: request.model)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.served(answerer))
                    try await Task.sleep(for: .milliseconds(150))
                    for piece in pieces {
                        continuation.yield(.content(piece))
                        try await Task.sleep(for: .milliseconds(120))
                    }
                    continuation.yield(.finished(reason: "stop"))
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: MagpieError.from(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
