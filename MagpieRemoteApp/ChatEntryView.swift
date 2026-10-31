import SwiftUI
import UIKit
import MagpieRemoteCore

/// 一条消息：用户的在右侧，模型的回答在左侧（Markdown 渲染、思考过程、由谁回答、复制）。
struct ChatEntryView: View {
    let entry: ChatEntry
    let isStreaming: Bool
    @State private var copied = false

    var body: some View {
        if entry.role == .user {
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    if !entry.images.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(entry.images) { AttachmentThumbnail(attachment: $0, size: 96) }
                        }
                    }
                    if !entry.text.isEmpty {
                        Text(entry.text)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .glassEffect(Glass.regular.tint(Color.accentColor.opacity(0.35)), in: .rect(cornerRadius: 18, style: .continuous))
                    }
                }
            }
            .contextMenu { copyButton }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat.message.user")
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    if !entry.reasoning.isEmpty {
                        DisclosureGroup("思考过程") {
                            Text(entry.reasoning)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.footnote)
                        .accessibilityIdentifier("chat.reasoning")
                    }
                    if !entry.text.isEmpty {
                        MarkdownText(text: entry.text)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("chat.message.assistant")
                    } else if isStreaming {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(entry.reasoning.isEmpty ? "正在等待回答…" : "正在思考…").foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("chat.waiting")
                    }
                    if let error = entry.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("chat.error")
                    }
                    footer
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
                Spacer(minLength: 24)
            }
            .contextMenu { copyButton }
        }
    }

    @ViewBuilder
    private var footer: some View {
        let answered = entry.answeredBy?.displayText
        if answered != nil || entry.stopped || (!isStreaming && !entry.text.isEmpty) {
            HStack(spacing: 10) {
                if let answered {
                    Text("由 \(answered) 回答")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("chat.answeredBy")
                }
                if entry.stopped {
                    Text("已停止").accessibilityIdentifier("chat.stopped")
                }
                Spacer(minLength: 0)
                if !isStreaming, !entry.text.isEmpty {
                    Button {
                        copy()
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(copied ? "已复制" : "复制")
                    .accessibilityIdentifier("chat.copy")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var copyButton: some View {
        Button("复制", systemImage: "doc.on.doc") { copy() }
            .disabled(entry.text.isEmpty)
    }

    private func copy() {
        UIPasteboard.general.string = entry.text
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// 回答的 Markdown 渲染：行内语法（粗体、斜体、代码、链接），保留换行。
struct MarkdownText: View {
    let text: String

    var body: some View {
        Text(Self.attributed(text))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false,
                                                              interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// 图片缩略图。
struct AttachmentThumbnail: View {
    let attachment: ChatAttachment
    let size: CGFloat

    var body: some View {
        Group {
            if let image = UIImage(data: attachment.data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("图片")
    }
}

/// 发图前的处理：缩到最长边 1568 像素以内，转成 JPEG（质量 0.8）。在后台线程做。
enum ChatImageProcessing {
    nonisolated static func preparedJPEG(from data: Data) async -> Data? {
        await Task.detached(priority: .userInitiated) { jpeg(from: data) }.value
    }

    nonisolated static func jpeg(from data: Data, maxDimension: CGFloat = 1568) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxDimension / longest)
        let target = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: 0.8)
    }
}
