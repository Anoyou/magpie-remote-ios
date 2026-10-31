import SwiftUI
import MagpieRemoteCore

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var sending = false
    @State private var error: MagpieError?

    var body: some View {
        ConnectedContent {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if messages.isEmpty {
                            ContentUnavailableView("开始对话", systemImage: "bubble.left.and.bubble.right",
                                                   description: Text("消息经由你自己的 magpie 网关发送，使用这台主机上配置的模型。"))
                                .padding(.top, 40)
                        }
                        ForEach(messages) { MessageBubble(message: $0) }
                        if let error {
                            Text(error.message).font(.footnote).foregroundStyle(.red)
                                .accessibilityIdentifier("chat.error")
                        }
                    }
                    .padding()
                }
                composer
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("发消息…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .accessibilityIdentifier("chat.composer")
            Button {
                Task { await send() }
            } label: {
                Image(systemName: sending ? "hourglass" : "arrow.up")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("发送")
            .accessibilityIdentifier("chat.send")
        }
        .padding(6)
        .glassCard(cornerRadius: 26)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        error = nil
        messages.append(ChatMessage(role: .user, text: text))
        sending = true
        defer { sending = false }
        do {
            let answer = try await model.reply(to: messages)
            messages.append(ChatMessage(role: .assistant, text: answer))
        } catch {
            self.error = MagpieError.from(error)
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(message.role == .user ? Glass.regular.tint(Color.accentColor.opacity(0.35)) : Glass.regular,
                             in: .rect(cornerRadius: 18, style: .continuous))
            if message.role != .user { Spacer(minLength: 40) }
        }
        .accessibilityIdentifier(message.role == .user ? "chat.message.user" : "chat.message.assistant")
    }
}
