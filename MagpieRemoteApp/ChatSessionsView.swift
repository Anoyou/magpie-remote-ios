import SwiftUI
import MagpieRemoteCore

/// 本机保存的对话列表：打开、重命名、删除（需确认）、新对话。
struct ChatSessionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: ChatSessionSummary?
    @State private var renaming: ChatSessionSummary?
    @State private var renameText = ""

    var body: some View {
        let chat = model.chat
        NavigationStack {
            List {
                if chat.sessions.isEmpty {
                    ContentUnavailableView("还没有对话", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("发出第一条消息后，对话会保存在这台 iPhone 上。"))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("chat.sessions.empty")
                }
                ForEach(chat.sessions) { summary in
                    HStack(spacing: 8) {
                        Button {
                            chat.open(summary.id)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(summary.title).font(.body).lineLimit(1)
                                    if summary.id == chat.session.id {
                                        Text("当前").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(Color.accentColor.opacity(0.2), in: .capsule)
                                    }
                                }
                                HStack(spacing: 6) {
                                    if let modelID = summary.model { Text(modelID).lineLimit(1).truncationMode(.middle) }
                                    Text(summary.updatedAt, format: .relative(presentation: .named))
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat.session.row")

                        Menu {
                            Button("重命名", systemImage: "pencil") { beginRename(summary) }
                                .accessibilityIdentifier("chat.session.rename")
                            Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = summary }
                                .accessibilityIdentifier("chat.session.delete")
                        } label: {
                            Image(systemName: "ellipsis.circle").font(.title3)
                        }
                        .accessibilityLabel("更多操作")
                        .accessibilityIdentifier("chat.session.menu")
                    }
                    .swipeActions(edge: .trailing) {
                        Button("删除", systemImage: "trash") { pendingDelete = summary }
                            .tint(.red)
                        Button("重命名", systemImage: "pencil") { beginRename(summary) }
                            .tint(.blue)
                    }
                }
            }
            .navigationTitle("对话列表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("chat.sessions.done")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        chat.newChat()
                        dismiss()
                    } label: {
                        Label("新对话", systemImage: "square.and.pencil")
                    }
                    .accessibilityIdentifier("chat.sessions.new")
                }
            }
            .confirmationDialog("删除这个对话？", isPresented: deleteBinding, titleVisibility: .visible, presenting: pendingDelete) { summary in
                Button("删除对话", role: .destructive) {
                    chat.delete(summary.id)
                    pendingDelete = nil
                }
                .accessibilityIdentifier("chat.session.confirmDelete")
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: { summary in
                Text("「\(summary.title)」会从这台 iPhone 上删除，无法恢复。")
            }
            .alert("重命名对话", isPresented: renameBinding, presenting: renaming) { summary in
                TextField("标题", text: $renameText)
                    .accessibilityIdentifier("chat.session.renameField")
                Button("保存") {
                    chat.rename(summary.id, to: renameText)
                    renaming = nil
                }
                .accessibilityIdentifier("chat.session.renameSave")
                Button("取消", role: .cancel) { renaming = nil }
            } message: { _ in
                Text("留空则按第一条消息自动命名。")
            }
            .onAppear { chat.refreshList() }
        }
    }

    private func beginRename(_ summary: ChatSessionSummary) {
        renameText = summary.title
        renaming = summary
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }
}
