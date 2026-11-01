import SwiftUI
import MagpieRemoteCore

/// 「会话记录 › 回收站」，照官方网页会话页的 Trash：在这里删除的会话进入 magpie 回收站，可以「恢复」，
/// 或「彻底删除」（无法恢复，先确认），也可以「清空回收站」。
struct SessionTrashView: View {
    let store: AgentSessionsStore
    @State private var pendingPurge: TrashedSession?
    @State private var asksEmpty = false

    var body: some View {
        List {
            Section {
                if store.trash.isEmpty {
                    Text("回收站是空的").foregroundStyle(.secondary)
                        .accessibilityIdentifier("trash.empty")
                }
                ForEach(store.trash) { item in
                    HStack(alignment: .top, spacing: 10) {
                        BrandIcon(item.icon.isEmpty ? OfficialIcon.agent(item.agent) : item.icon, size: 16)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.displayTitle).lineLimit(2)
                            Text([item.name, item.cwd.isEmpty ? nil : item.cwd, item.deleted.map { "删除于 " + SessionFormat.time($0) }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Button("恢复") { Task { await store.restore(item) } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(store.busy)
                            .accessibilityIdentifier("trash.restore.\(item.sessionID)")
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("彻底删除", role: .destructive) { pendingPurge = item }
                    }
                    .contextMenu {
                        Button { Task { await store.restore(item) } } label: { Label("恢复", systemImage: "arrow.uturn.backward") }
                        Button(role: .destructive) { pendingPurge = item } label: { Label("彻底删除", systemImage: "trash") }
                    }
                    .accessibilityIdentifier("trash.row.\(item.sessionID)")
                }
            } footer: {
                Text("在此删除的会话进入 magpie 回收站，可随时恢复。")
            }
            if !store.trash.isEmpty {
                Section {
                    Button("清空回收站", role: .destructive) { asksEmpty = true }
                        .disabled(store.busy)
                        .accessibilityIdentifier("trash.emptyAll")
                }
            }
        }
        .navigationTitle("回收站")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.load() }
        .confirmationDialog("彻底删除这个会话？", isPresented: Binding(get: { pendingPurge != nil }, set: { if !$0 { pendingPurge = nil } }),
                            titleVisibility: .visible, presenting: pendingPurge) { item in
            Button("彻底删除", role: .destructive) { Task { await store.purge([item]) } }
                .accessibilityIdentifier("trash.purge.confirm")
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("其文件将被彻底删除，无法恢复。")
        }
        .confirmationDialog("清空 magpie 的回收站？", isPresented: $asksEmpty, titleVisibility: .visible) {
            Button("清空回收站", role: .destructive) { Task { await store.purge([]) } }
                .accessibilityIdentifier("trash.emptyAll.confirm")
            Button("取消", role: .cancel) {}
        } message: {
            Text("回收站中的所有会话将被彻底删除，无法恢复。")
        }
        .sessionAlerts(store: store, id: "trash")
    }
}
