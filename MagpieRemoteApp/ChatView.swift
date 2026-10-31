import SwiftUI
import PhotosUI
import MagpieRemoteCore

/// 「对话」标签页：经由自己的 magpie 网关和模型对话。对话保存在本机。
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var showSessions = false

    var body: some View {
        ConnectedContent {
            ChatScreen()
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button {
                    model.chat.refreshList()
                    showSessions = true
                } label: {
                    Label("对话列表", systemImage: "list.bullet")
                }
                .accessibilityIdentifier("chat.sessions.open")

                Button {
                    model.chat.newChat()
                } label: {
                    Label("新对话", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("chat.new")
            }
        }
        .sheet(isPresented: $showSessions) {
            ChatSessionsView()
        }
    }
}

/// 连上主机之后的对话页面：消息列表 + 输入栏。
private struct ChatScreen: View {
    @Environment(AppModel.self) private var model
    static let bottomID = "chat.bottom"

    var body: some View {
        let chat = model.chat
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if chat.session.entries.isEmpty {
                            ContentUnavailableView("开始对话", systemImage: "bubble.left.and.bubble.right",
                                                   description: Text("消息经由你自己的 magpie 网关发送，使用这台主机上配置的模型。对话只保存在这台 iPhone 上。"))
                                .padding(.top, 40)
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("chat.empty")
                        }
                        ForEach(chat.session.entries) { entry in
                            ChatEntryView(entry: entry, isStreaming: chat.streamingEntryID == entry.id)
                                .id(entry.id)
                        }
                        if let notice = chat.notice {
                            Text(notice).font(.footnote).foregroundStyle(.orange)
                                .accessibilityIdentifier("chat.notice")
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chat.session.entries.last?.text) {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
                .onChange(of: chat.session.entries.count) {
                    withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
                .onChange(of: chat.session.id) {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            ChatComposer()
        }
        .task(id: model.activeHost?.id) {
            await chat.loadModels(app: model)
        }
    }
}

/// 输入栏：模型选择、图片、输入框、发送 / 停止。
private struct ChatComposer: View {
    @Environment(AppModel.self) private var model
    @State private var showModelPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var loadingImages = false

    var body: some View {
        @Bindable var chat = model.chat
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    showModelPicker = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: chat.selectedModel?.isRoutingGroup == true ? "arrow.triangle.branch" : "cpu")
                        Text(chat.selectedModelTitle).lineLimit(1)
                        if chat.canAttachImages {
                            Image(systemName: "photo")
                        }
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("模型：\(chat.selectedModelTitle)\(chat.canAttachImages ? "，支持图片" : "")")
                .accessibilityIdentifier("chat.modelPicker")
                if chat.loadingModels { ProgressView().controlSize(.small) }
                if let error = chat.catalogError {
                    Text(error.title).font(.caption).foregroundStyle(.red).lineLimit(1)
                        .accessibilityIdentifier("chat.models.error")
                }
                Spacer(minLength: 0)
            }

            if !chat.pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chat.pendingImages) { image in
                            AttachmentThumbnail(attachment: image, size: 56)
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        chat.pendingImages.removeAll { $0.id == image.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                    .accessibilityLabel("移除图片")
                                    .offset(x: 6, y: -6)
                                }
                        }
                    }
                    .padding(.top, 6)
                }
            }
            if chat.imagesBlocked {
                Text("当前模型不支持图片：请移除图片，或换一个标有图片图标的模型。")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $photoItems, maxSelectionCount: 4, matching: .images) {
                    Image(systemName: loadingImages ? "hourglass" : "photo.badge.plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .disabled(!chat.canAttachImages || chat.isStreaming || loadingImages)
                .accessibilityLabel(chat.canAttachImages ? "添加图片" : "当前模型不支持图片")
                .accessibilityIdentifier("chat.attach")

                TextField("发消息…", text: $chat.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("chat.composer")

                if chat.isStreaming {
                    Button {
                        chat.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.body.weight(.semibold))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("停止")
                    .accessibilityIdentifier("chat.stop")
                } else {
                    Button {
                        chat.send(app: model)
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.semibold))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .disabled(!chat.canSend)
                    .accessibilityLabel("发送")
                    .accessibilityIdentifier("chat.send")
                }
            }
        }
        .padding(8)
        .glassCard(cornerRadius: 26)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .sheet(isPresented: $showModelPicker) {
            ChatModelPicker()
        }
        .onChange(of: photoItems) {
            let items = photoItems
            guard !items.isEmpty else { return }
            photoItems = []
            loadingImages = true
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let jpeg = await ChatImageProcessing.preparedJPEG(from: data) {
                        model.chat.pendingImages.append(ChatAttachment(mediaType: "image/jpeg", data: jpeg))
                    } else {
                        model.chat.notice = "有一张图片读不出来，已跳过。"
                    }
                }
                loadingImages = false
            }
        }
    }
}
