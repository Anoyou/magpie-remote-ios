import SwiftUI
import UIKit
import MagpieRemoteCore

/// 「管理 → Agent 会话记录」：magpie 在 Mac 上读到的 Claude Code、Codex 等 Agent 的会话。
/// 按 Agent 分开列出，可以筛选、按对话内容搜索、查看对话、导出 Markdown、移到 magpie 回收站。
struct AgentSessionsView: View {
    @State private var store: AgentSessionsStore
    @State private var pendingDelete: AgentSession?

    init(service: any AgentSessionsServing) {
        _store = State(initialValue: AgentSessionsStore(service: service))
    }

    var body: some View {
        content
            .navigationTitle("会话记录")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $store.query, prompt: store.scope == .titles ? "筛选标题、目录、模型" : "搜索对话内容（至少 2 个字）")
            .searchScopes($store.scope) {
                ForEach(AgentSessionsStore.SearchScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .onSubmit(of: .search) { Task { await store.searchContent() } }
            .task(id: "\(store.scope.rawValue)|\(store.query)|\(store.agent)") {
                guard store.scope == .content else { return }
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await store.searchContent()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("排序", selection: $store.sort) {
                            ForEach(SessionSort.allCases) { sort in
                                Text(sort.title).tag(sort)
                            }
                        }
                    } label: {
                        Label("排序", systemImage: "arrow.up.arrow.down")
                    }
                    .accessibilityIdentifier("sessions.sort")
                }
            }
            .refreshable { await store.load() }
            .task { if store.overview == nil { await store.load() } }
            .confirmationDialog("把这个会话移到 magpie 回收站？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible, presenting: pendingDelete) { session in
                Button("移到回收站", role: .destructive) {
                    Task { await store.delete(session) }
                }
                .accessibilityIdentifier("session.delete.confirm")
                Button("取消", role: .cancel) {}
            } message: { session in
                Text("「\(session.displayTitle)」的文件会移到 Mac 上 magpie 的回收站，Agent 里不再列出它；需要时可以在 Mac 上的 magpie「会话」页恢复。")
            }
            .sessionAlerts(store: store, id: "list")
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .loading:
            ProgressView("正在读取会话记录…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("sessions.loading")
        case .failed(let error):
            ContentUnavailableView {
                Label(error.title, systemImage: "exclamationmark.triangle")
            } description: {
                Text([error.message, error.hint].compactMap { $0 }.joined(separator: "\n"))
            } actions: {
                Button("重试") { Task { await store.load() } }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("sessions.retry")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sessions.error")
        case .ready:
            list
        }
    }

    private var list: some View {
        List {
            if !store.blockedReads.isEmpty {
                ReadsBlockedSection(store: store)
            }

            if store.agents.count > 1 {
                Section {
                    Picker(selection: Binding(get: { store.agent }, set: { id in Task { await store.select(agent: id) } })) {
                        ForEach(store.agents) { agent in
                            Text("\(agent.name)（\(agent.count)）").tag(agent.id)
                        }
                    } label: {
                        Label("Agent", systemImage: "terminal")
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("sessions.agent")
                }
            }

            let sessions = store.visibleSessions
            Section {
                if store.agents.isEmpty && store.blockedReads.isEmpty {
                    emptyRow("magpie 还没有在这台 Mac 上找到 Agent 的会话记录。")
                } else if sessions.isEmpty {
                    if store.searching {
                        HStack { ProgressView(); Text("正在搜索对话内容…").foregroundStyle(.secondary) }
                    } else if !store.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        emptyRow(store.scope == .content && !SessionSearchResult.canSearch(store.query) ? "至少输入 2 个字再搜索对话内容。" : "没有符合的会话。")
                    } else if !store.agents.isEmpty {
                        emptyRow("这个 Agent 没有会话。")
                    }
                }
                ForEach(sessions) { session in
                    NavigationLink {
                        AgentSessionDetailView(store: store, session: session)
                    } label: {
                        SessionRow(session: session, hit: store.hit(for: session))
                    }
                    .accessibilityIdentifier("session.row.\(session.sessionID)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if session.deletable {
                            Button("删除", role: .destructive) { pendingDelete = session }
                                .accessibilityIdentifier("session.swipe.delete")
                        }
                    }
                }
            } header: {
                if let agent = store.currentAgent {
                    HStack(spacing: 6) {
                        BrandIcon(agent.icon, size: 14)
                        Text("\(agent.name) · \(sessions.count) 个会话")
                    }
                }
            } footer: {
                footer
            }
        }
        .accessibilityIdentifier("sessions.list")
    }

    @ViewBuilder
    private var footer: some View {
        if store.scope == .content, let result = store.contentResult, !store.query.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("读了 \(result.searched) / \(result.total) 个会话。")
                if result.cut { Text("命中太多或时间不够，只列出了一部分。") }
                if result.unread { Text("这个 Agent 的会话存在数据库里，只搜索了 magpie 网关记录的对话。") }
            }
        } else if let agent = store.currentAgent, !agent.deletable {
            Text("magpie 不能删除这个 Agent 的会话，只能查看。")
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).accessibilityIdentifier("sessions.empty")
    }
}

/// 新装的 magpie 不读任何 Agent 的会话，要先允许。
private struct ReadsBlockedSection: View {
    let store: AgentSessionsStore
    @State private var confirming = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("magpie 还不能读取这些 Agent 的会话", systemImage: "lock.doc")
                    .font(.headline)
                Text(store.blockedReads.map(\.name).joined(separator: "、"))
                    .font(.subheadline)
                Text("允许后，magpie 会在 Mac 上读取它们的会话文件，用来列出会话和统计用量；也可以在 Mac 上 magpie 的「设置 → 会话」里逐个设置。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("允许读取") { confirming = true }
                .disabled(store.busy)
                .accessibilityIdentifier("sessions.reads.allow")
                .confirmationDialog("允许 magpie 读取这些 Agent 的会话？", isPresented: $confirming, titleVisibility: .visible) {
                    Button("允许读取") { Task { await store.allowReads(store.blockedReads.map(\.id)) } }
                    Button("取消", role: .cancel) {}
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sessions.reads.blocked")
    }
}

private struct SessionRow: View {
    let session: AgentSession
    let hit: SessionSearchHit?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.displayTitle)
                .font(.body)
                .lineLimit(2)
            let summary = SessionFormat.summary(session)
            if !summary.isEmpty {
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 6) {
                if !session.folderName.isEmpty {
                    Label(session.folderName, systemImage: "folder").labelStyle(.titleAndIcon)
                }
                if session.gateway {
                    Label("网关", systemImage: "point.3.connected.trianglepath.dotted")
                }
                Spacer(minLength: 0)
                if session.cost > 0 { Text(UsageFormat.cost(session.cost)) }
                Text(SessionFormat.time(session.last))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if let hit {
                Text("\(hit.before)\(Text(hit.match).bold().foregroundStyle(Color.accentColor))\(hit.after)")
                    .font(.caption)
                    .lineLimit(2)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 8))
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: 详情

/// 一个会话：概况、子会话、对话内容；可以导出或删除。
struct AgentSessionDetailView: View {
    let store: AgentSessionsStore
    let session: AgentSession
    var sub: SessionSubagent?

    @Environment(\.dismiss) private var dismiss
    @State private var transcript: SessionTranscript?
    @State private var loadError: MagpieError?
    @State private var showTools = false
    @State private var confirmingDelete = false
    @State private var shareItem: ShareItem?

    private var title: String { sub?.displayTitle ?? session.displayTitle }

    var body: some View {
        List {
            if sub == nil { infoSection }
            if sub == nil && !session.subagents.isEmpty {
                Section("子会话") {
                    ForEach(session.subagents) { subagent in
                        NavigationLink {
                            AgentSessionDetailView(store: store, session: session, sub: subagent)
                        } label: {
                            LabeledContent(subagent.displayTitle, value: subagent.kind)
                        }
                    }
                }
            }
            transcriptSection
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: $showTools) { Label("显示思考与工具", systemImage: "wrench.and.screwdriver") }
                        .accessibilityIdentifier("session.showTools")
                    if sub == nil {
                        Section {
                            Button { Task { await share() } } label: { Label("分享 Markdown…", systemImage: "square.and.arrow.up") }
                                .accessibilityIdentifier("session.share")
                            Button { Task { await store.exportOnHost(session) } } label: {
                                Label("保存到 Mac 的「下载」", systemImage: "arrow.down.doc")
                            }
                            .accessibilityIdentifier("session.exportHost")
                        }
                        if session.deletable {
                            Section {
                                Button(role: .destructive) { confirmingDelete = true } label: { Label("删除会话", systemImage: "trash") }
                                    .accessibilityIdentifier("session.delete")
                            }
                        }
                    }
                } label: {
                    Label("操作", systemImage: store.busy ? "hourglass" : "ellipsis.circle")
                }
                .accessibilityIdentifier("session.menu")
            }
        }
        .task(id: sub?.id ?? session.id) { await loadTranscript() }
        .refreshable { await loadTranscript() }
        .confirmationDialog("把这个会话移到 magpie 回收站？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("移到回收站", role: .destructive) {
                Task { if await store.delete(session) { dismiss() } }
            }
            .accessibilityIdentifier("session.delete.confirm")
            Button("取消", role: .cancel) {}
        } message: {
            Text("文件会移到 Mac 上 magpie 的回收站，需要时可以在 Mac 上恢复。")
        }
        .sheet(item: $shareItem) { item in
            SessionShareSheet(items: [item.url]).ignoresSafeArea()
        }
        .sessionAlerts(store: store, id: "detail.\(session.id).\(sub?.id ?? "")")
    }

    private var infoSection: some View {
        Section("概况") {
            LabeledContent("Agent", value: store.currentAgent?.name ?? session.agent)
            if !session.cwd.isEmpty { LabeledContent("目录", value: session.cwd) }
            LabeledContent("开始", value: SessionFormat.fullTime(session.start))
            LabeledContent("最近", value: SessionFormat.fullTime(session.last))
            if !session.modelNames.isEmpty {
                LabeledContent("模型", value: session.modelNames.joined(separator: "、"))
            }
            if session.pending {
                LabeledContent("用量", value: "magpie 正在统计…")
            } else {
                if session.totalTokens > 0 { LabeledContent("词元", value: UsageFormat.tokens(session.totalTokens)) }
                if session.cost > 0 || session.unpriced > 0 {
                    LabeledContent("花费", value: UsageFormat.cost(session.cost) + (session.unpriced > 0 ? "（\(session.unpriced) 个模型没有价格）" : ""))
                }
                if session.messages > 0 { LabeledContent("消息", value: "\(session.messages) 条") }
            }
            if session.size > 0 { LabeledContent("大小", value: SessionFormat.size(session.size)) }
            LabeledContent("会话 ID") {
                Text(session.sessionID).font(.caption.monospaced()).textSelection(.enabled)
            }
            if session.gateway {
                Text("这个会话只经过 magpie 网关，这台 Mac 上没有 Agent 自己的文件；对话内容来自 magpie 的记录（需要在 magpie 里打开「记录对话」）。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var transcriptSection: some View {
        if let transcript {
            let parts = transcript.visible(showTools: showTools)
            Section {
                if parts.isEmpty {
                    Text(showTools || transcript.parts.isEmpty ? "没有对话内容。" : "只有思考和工具调用，打开右上角「显示思考与工具」查看。")
                        .foregroundStyle(.secondary)
                }
                ForEach(parts) { part in
                    TranscriptBubble(part: part)
                }
            } header: {
                Text("对话 · \(transcript.turns) 轮")
            } footer: {
                if transcript.cut { Text("对话太长，magpie 只给了前面的部分。完整内容可以导出 Markdown。") }
            }
            .accessibilityIdentifier("session.transcript")
        } else if let loadError {
            Section("对话") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(loadError.title).foregroundStyle(.red)
                    Text(Self.transcriptMessage(loadError)).font(.footnote).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("session.transcript.error")
                Button("重试") { Task { await loadTranscript() } }
            }
        } else {
            Section("对话") {
                HStack { ProgressView(); Text("正在读取对话…").foregroundStyle(.secondary) }
            }
        }
    }

    /// magpie 的英文错误换成中文说明。
    static func transcriptMessage(_ error: MagpieError) -> String {
        if case .webRejected(let message, _) = error {
            if message.contains("can't be shown") { return "magpie 读不出这个 Agent 的对话内容（它把对话存在数据库里，或格式还不支持）。" }
            if message.contains("not allowed to read") { return "magpie 没有被允许读取这个 Agent 的会话。" }
            if message.contains("no such session") { return "主机上找不到这个会话，可能已经被删除。下拉刷新列表。" }
            return message
        }
        return [error.message, error.hint].compactMap { $0 }.joined(separator: "\n")
    }

    private func loadTranscript() async {
        do {
            transcript = try await store.transcript(for: session, sub: sub?.id)
            loadError = nil
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { loadError = error }
        }
    }

    private func share() async {
        if let url = await store.markdownFile(for: session) { shareItem = ShareItem(url: url) }
    }
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct TranscriptBubble: View {
    let part: TranscriptPart
    @State private var expanded = false

    private var collapsible: Bool { !part.isConversation && part.text.count > 240 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(part.label, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(part.role == .user ? Color.accentColor : .secondary)
            Text(part.text.isEmpty ? "（空）" : part.text)
                .font(part.isConversation ? .body : .caption.monospaced())
                .foregroundStyle(part.isConversation ? .primary : .secondary)
                .lineLimit(collapsible && !expanded ? 6 : nil)
                .textSelection(.enabled)
            if part.cut > 0 {
                Text("（后面还有 \(part.cut) 个字没有显示）").font(.caption2).foregroundStyle(.tertiary)
            }
            if collapsible {
                Button(expanded ? "收起" : "展开") { expanded.toggle() }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(part.role == .user && part.isConversation ? Color.accentColor.opacity(0.08) : nil)
    }

    private var symbol: String {
        switch part.kind {
        case .thinking: "brain"
        case .toolUse: "wrench.and.screwdriver"
        case .toolResult: "doc.plaintext"
        case .context: "text.badge.plus"
        case .image: "photo"
        case .text, .other: part.role == .user ? "person" : "sparkles"
        }
    }
}

/// 系统分享面板。
struct SessionShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension View {
    /// 列表和详情页共用一个 store：导航栈里只由最上面的页面弹窗（`id` 区分页面）。
    func sessionAlerts(store: AgentSessionsStore, id: String) -> some View {
        modifier(SessionAlerts(store: store, id: id))
    }
}

private struct SessionAlerts: ViewModifier {
    let store: AgentSessionsStore
    let id: String

    private var active: Bool { store.presenters.last == id }

    func body(content: Content) -> some View {
        content
            .onAppear { store.presenters.removeAll { $0 == id }; store.presenters.append(id) }
            .onDisappear { store.presenters.removeAll { $0 == id } }
            .alert(store.actionError?.title ?? "", isPresented: Binding(get: { active && store.actionError != nil }, set: { if !$0 { store.actionError = nil } })) {
                Button("好") { store.actionError = nil }
            } message: {
                Text(store.actionError.map(AgentSessionDetailView.transcriptMessage) ?? "")
            }
            .alert("已导出", isPresented: Binding(get: { active && store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
                Button("好") { store.notice = nil }
            } message: {
                Text(store.notice ?? "")
            }
    }
}
