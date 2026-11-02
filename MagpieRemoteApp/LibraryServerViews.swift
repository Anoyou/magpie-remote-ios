import SwiftUI
import UIKit
import MagpieRemoteCore

// 资源库 › MCP 服务器（官方 renderServers / serverRow / editServer / foundServerRow / hubPart）。

struct LibraryServersTab: View {
    let store: LibraryStore
    let page: LibrarySnapshot
    @Environment(LibraryPresenter.self) private var presenter
    /// 确认弹窗由页面根上的 LibraryPresenter 弹出（见 LibraryPresenter 的说明）。
    private var confirm: LibraryConfirm? {
        get { presenter.confirm }
        nonmutating set { presenter.confirm = newValue }
    }
    private var all: [LibraryAgent] { page.mcpAgents(hidden: store.hidden) }
    private var sorted: [LibraryServer] { page.servers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }

    var body: some View {
        Group {
            if page.servers.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("资源库里还没有服务器", systemImage: "server.rack")
                    } description: {
                        Text(page.listedFoundServers.isEmpty ? "粘贴 README 里的服务器 JSON，或手动填写。" : "添加一个，或把 Agent 里已有的导入进来（见下方）。")
                    } actions: {
                        Button("＋ 添加服务器") { presenter.show(.server(LibraryServerDraft(server: nil, agents: all.map(\.id)))) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("library.servers.addEmpty")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("library.servers.empty")
                }
            } else {
                Section {
                    ForEach(sorted) { server in
                        LibraryServerRow(store: store, page: page, server: server, all: all)
                    }
                    Button("＋ 添加服务器") { presenter.show(.server(LibraryServerDraft(server: nil, agents: all.map(\.id)))) }
                        .disabled(store.busy)
                        .accessibilityIdentifier("library.servers.add")
                } header: {
                    HStack {
                        Text("资源库中 · \(page.servers.count)")
                        Spacer()
                        if page.servers.count > 1 && !all.isEmpty { bulkMenu }
                    }
                }
                .onAppear { store.checkServersInUse() }
                hubSection
            }

            if !page.listedFoundServers.isEmpty {
                Section {
                    ForEach(page.listedFoundServers) { found in
                        LibraryFoundServerRow(store: store, page: page, found: found, confirm: presenter.confirmBinding)
                    }
                } header: {
                    Text("Agent 中已有")
                } footer: {
                    Text("不在资源库中 — 导入后即可在这里管理")
                }
            }

            LibraryProjectsSection(page: page, kind: .mcp)

            Section {
                Button {
                    presenter.show(.serverMarket)
                } label: {
                    Label("发现", systemImage: "magnifyingglass")
                }
                .accessibilityIdentifier("library.servers.discover")
            } footer: {
                serverAsides
            }
        }
    }

    private var bulkMenu: some View {
        Menu {
            Button {
                Task { await store.run(.serversAgentsAll, LibraryRequests.every(agents: all.map(\.id), on: true)) }
            } label: {
                Label("全部启用", systemImage: "checkmark.circle")
            }
            Button {
                let words = LibraryWords.everyOff(.mcp, count: page.servers.count, agents: all.map(\.name))
                confirm = LibraryConfirm(title: words.title, message: words.message, button: "全部关闭") {
                    await store.run(.serversAgentsAll, LibraryRequests.every(agents: all.map(\.id), on: false))
                }
            } label: {
                Label("全部关闭", systemImage: "circle")
            }
            Button(role: .destructive) {
                let who = Set(page.servers.flatMap(\.agents)).map(page.name(of:)).sorted()
                let words = LibraryWords.removeEvery(.mcp, count: page.servers.count, agents: who)
                confirm = LibraryConfirm(title: words.title, message: words.message, button: "删除全部 \(page.servers.count) 个") {
                    await store.run(.serversRemoveAll, LibraryRequests.names(page.servers.map(\.name)))
                }
            } label: {
                Label("全部删除", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(store.busy)
        .accessibilityLabel("更多操作")
        .accessibilityIdentifier("library.servers.bulk")
    }

    /// MCP 路由（官方 hubPart）：打开后每个 Agent 只拿到 magpie 这一个服务器。
    private var hubSection: some View {
        Section {
            Toggle(isOn: Binding(get: { page.mcpHub }, set: { on in
                Task {
                    await store.run(.serversHub, LibraryRequests.on(on),
                                    done: on ? "各 Agent 现在拿到的是 magpie 这一个 MCP 服务器——重启它们后生效" : "各 Agent 重新拿到每个服务器各自的条目——重启它们后生效")
                }
            })) {
                Text("MCP 路由")
            }
            .disabled(store.busy)
            .accessibilityIdentifier("library.servers.hub")
        } footer: {
            Text(page.mcpHub
                 ? "每个 Agent 只拿到一个服务器 magpie，代替这些服务器。magpie 为所有 Agent 只运行每个服务器一次，把每次调用转给它，工具名为 server__tool。重启 Agent 后生效。"
                 : "让所有服务器都经由 magpie 提供：每个 Agent 只拿到一个服务器 magpie，代替这些服务器；其他应用也只需连接一个地址。")
        }
    }

    @ViewBuilder private var serverAsides: some View {
        let skip = page.shownAgents(hidden: store.hidden).filter { $0.mcp.isEmpty }
        VStack(alignment: .leading, spacing: 6) {
            Text("搜索 MCP 服务器 — GitHub、Postgres、Figma…")
            if !skip.isEmpty { Text("\(skip.map(\.name).joined(separator: "、")) 没有 magpie 可写入的 MCP 配置。") }
            ForEach(page.shownAgents(hidden: store.hidden).filter { ($0.id == "workbuddy" || $0.id == "workbuddy-ai") && !$0.mcp.isEmpty }) { wb in
                if page.servers.contains(where: { $0.agents.contains(wb.id) }) {
                    Text("\(wb.name) 只连接你信任过的服务器：在 \(wb.name) 的 MCP 设置里打开它一次，服务器的命令或地址变了之后要再打开一次。")
                }
            }
        }
    }
}

/// 列表里的一个服务器：名字、状态、命令或地址、Agent。点名字进详情。
private struct LibraryServerRow: View {
    let store: LibraryStore
    let page: LibrarySnapshot
    let server: LibraryServer
    let all: [LibraryAgent]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink {
                LibraryServerDetail(store: store, name: server.name)
            } label: {
                LibraryServerHeader(store: store, page: page, server: server)
            }
            .accessibilityIdentifier("library.server.\(server.name)")
            LibraryChips(agents: page.withGone(all, on: server.agents, hidden: store.hidden),
                         on: store.agents(.serversAgents, server.name, current: server.agents),
                         blocked: { server.blocked(for: $0) }, problems: server.problems,
                         id: "library.server.\(server.name).agents",
                         onChange: { next, every in store.setAgents(.serversAgents, name: server.name, to: next, allChip: every) },
                         onBlocked: { store.say($0, warn: true) })
        }
        .padding(.vertical, 2)
    }
}

struct LibraryServerHeader: View {
    let store: LibraryStore
    let page: LibrarySnapshot
    let server: LibraryServer

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if BrandIcon.isBrand(server.icon) {
                    BrandIcon(server.icon, size: 22)
                } else {
                    Image(systemName: server.isRemote ? "globe" : "terminal").foregroundStyle(.secondary)
                }
            }
            .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(server.name).font(.body.monospaced()).lineLimit(1)
                    if server.signInDead { LibraryTag("登录已失效", warn: true) }
                    else if server.signedIn { LibraryTag("已登录") }
                    if server.local { LibraryTag("只在这台电脑") }
                    if page.mcpHub && server.hub == "direct" { LibraryTag("不经过路由") }
                }
                LibraryHealthText(store: store, server: server)
                Text(server.line).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

/// 服务器的检测状态（官方 healthEl / healthWords）。
struct LibraryHealthText: View {
    let store: LibraryStore
    let server: LibraryServer

    var body: some View {
        if store.checking.contains(server.name) {
            Text("检测中…").font(.caption).foregroundStyle(.secondary)
        } else if let h = store.health[server.name] {
            let words = h.words(transport: server.transport, name: store.name(of:))
            Label(words.short, systemImage: h.isOK ? "checkmark.circle.fill" : h.isUnknown ? "circle.dashed" : "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(h.isOK ? Color.green : h.isUnknown ? Color.secondary : Color.orange)
                .accessibilityHint(words.long)
        } else {
            Text("未检测").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

/// Agent 里已有、不在资源库里的服务器：导入或移除（官方 foundServerRow）。
private struct LibraryFoundServerRow: View {
    let store: LibraryStore
    let page: LibrarySnapshot
    let found: LibraryFoundServer
    @Binding var confirm: LibraryConfirm?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(found.server.name).font(.body.monospaced())
            Text(found.server.line).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            Text(found.server.agents.map(page.name(of:)).joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
            if !found.others.isEmpty {
                Text("\(found.others.map(page.name(of:)).joined(separator: "、")) 中不同").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("导入") {
                    Task { await store.run(.serversImport, LibraryRequests.name(found.server.name), done: "\(found.server.name) 已加入资源库") }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("library.found.\(found.server.name).import")
                Button("移除", role: .destructive) {
                    confirm = LibraryConfirm(title: "移除 \(found.server.name)？", message: LibraryWords.removeFoundServerMessage(found, name: page.name(of:)), button: "移除") {
                        await store.run(.serversRemoveFound, LibraryRequests.name(found.server.name), done: "已移除 \(found.server.name)")
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("library.found.\(found.server.name).remove")
            }
            .disabled(store.busy)
            .font(.footnote)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.found.\(found.server.name)")
    }
}

// MARK: 服务器详情

struct LibraryServerDetail: View {
    let store: LibraryStore
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var editing: LibraryServerDraft?
    @State private var confirm: LibraryConfirm?

    private var page: LibrarySnapshot? { store.page }
    private var server: LibraryServer? { page?.servers.first { $0.name == name } }

    var body: some View {
        ZStack {  // 不用 Group：Group 的修饰符会分给每个分支，换分支时弹窗宿主跟着被换掉
            if let page, let server {
                content(page, server)
            } else {
                ContentUnavailableView("这个服务器已不在资源库中", systemImage: "server.rack")
            }
        }
        .detailHeader(name)
        .toolbar {
            if let server, let page {
                ToolbarItem(placement: .primaryAction) {
                    Button("编辑") { editing = LibraryServerDraft(server: server, agents: page.mcpAgents(hidden: store.hidden).map(\.id)) }
                        .accessibilityIdentifier("library.serverDetail.edit")
                }
            }
        }
        .sheet(item: $editing) { draft in LibraryServerEditor(store: store, draft: draft) }
        .libraryConfirm($confirm)
        .safeAreaInset(edge: .bottom) { LibraryStatusLine(store: store) }
        .libraryAlerts(store: store, id: "library.server")
    }

    private func content(_ page: LibrarySnapshot, _ server: LibraryServer) -> some View {
        let all = page.mcpAgents(hidden: store.hidden)
        let health = store.health[server.name]
        let toolsOffAgents = page.agents.filter { server.agents.contains($0.id) && !$0.toolsOff }
        return List {
            Section {
                LabeledContent("运行方式", value: server.isRemote ? (server.transport == "sse" ? "SSE" : "HTTP") : "命令")
                Text(server.line).font(.footnote.monospaced()).textSelection(.enabled)
                if server.local { LabeledContent("只在这台电脑", value: "同步不会把它带到你的其他电脑") }
                if !server.plugin.isEmpty { LabeledContent("来自插件", value: server.plugin) }
                if server.startupTimeout > 0 { LabeledContent("启动超时", value: "\(server.startupTimeout) 秒") }
            }

            Section {
                LibraryHealthText(store: store, server: server)
                if let health {
                    Text(health.words(transport: server.transport, name: store.name(of:)).long).font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    Task { await store.check([server.name], fresh: true) }
                } label: {
                    Label(health == nil ? "检测" : "重新检测", systemImage: "stethoscope")
                }
                .disabled(store.checking.contains(server.name))
                .accessibilityIdentifier("library.serverDetail.check")
            } header: {
                Text("状态")
            }

            if let health, !health.toolList.isEmpty {
                Section {
                    ForEach(health.toolList) { tool in
                        Toggle(isOn: Binding(get: { !server.disabledTools.contains(tool.name) }, set: { on in
                            var off = server.disabledTools.filter { $0 != tool.name }
                            if !on { off.append(tool.name) }
                            Task { await store.run(.serversTools, LibraryRequests.tools(server.name, off: off), done: on ? "启用 \(tool.name)" : "已关闭 \(tool.name)") }
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.name).font(.footnote.monospaced())
                                if !tool.description.isEmpty { Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                            }
                        }
                        .disabled(store.busy)
                        .accessibilityIdentifier("library.tool.\(tool.name)")
                    }
                    if health.tools > health.toolList.count {
                        Text("另有 \(health.tools - health.toolList.count) 个未显示").font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text(health.tools == 1 ? "1 个工具" : "\(health.tools) 个工具")
                } footer: {
                    if !toolsOffAgents.isEmpty {
                        Text("\(toolsOffAgents.map(\.name).joined(separator: "、")) 不能单独关闭工具：它们仍会拿到这个服务器的全部工具。")
                    }
                }
            }

            Section {
                LibraryChips(agents: page.withGone(all, on: server.agents, hidden: store.hidden),
                             on: store.agents(.serversAgents, server.name, current: server.agents),
                             blocked: { server.blocked(for: $0) }, problems: server.problems,
                             id: "library.serverDetail.agents",
                             onChange: { next, every in store.setAgents(.serversAgents, name: server.name, to: next, allChip: every) },
                             onBlocked: { store.say($0, warn: true) })
                ForEach(server.problems.sorted { $0.key < $1.key }, id: \.key) { item in
                    Text("\(page.name(of: item.key))：\(item.value)").font(.footnote).foregroundStyle(.orange)
                }
            } header: {
                Text("Agent")
            }

            Section {
                let copyable = all.filter { !$0.mcp.isEmpty && server.blocked(for: $0) == nil }
                if !copyable.isEmpty {
                    Menu {
                        ForEach(copyable) { agent in
                            Button(agent.name) { copyConfig(agent) }
                        }
                    } label: {
                        Label("复制配置…", systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("library.serverDetail.copy")
                }
                if server.signedIn || server.signInDead {
                    Button("退出登录") { Task { await store.signOut(server.name) } }
                        .disabled(store.busy)
                }
                Button("从资源库移除", role: .destructive) {
                    let who = server.agents.map(page.name(of:))
                    let projects = page.projects.filter { $0.servers[server.name] != nil }.count
                    confirm = LibraryConfirm(title: "删除 MCP 服务器 \(server.name)？", message: LibraryWords.removeServerMessage(server, agents: who, projects: projects), button: "移除") {
                        if await store.run(.serversRemove, LibraryRequests.name(server.name), done: "\(server.name) 已从资源库及相关 Agent 中移除") { dismiss() }
                    }
                }
                .disabled(store.busy)
                .accessibilityIdentifier("library.serverDetail.remove")
            } footer: {
                if server.isRemote && server.transport == "http" {
                    Text("需要登录（OAuth）的服务器要在 Mac 上的 magpie 里登录一次：登录完成后浏览器会回到 Mac 本机的地址，手机上走不通。可以在「在网页中打开资源库」里操作。")
                }
            }
        }
    }

    private func copyConfig(_ agent: LibraryAgent) {
        Task {
            guard let c = await store.serversConfig(agent: agent.id, names: [name]) else { return }
            UIPasteboard.general.string = c.text
            store.say(c.skipped.isEmpty ? "已复制 \(agent.name) 的 \(c.file)" : "已复制 \(c.file)（\(c.skipped.joined(separator: ", ")) 放不进去）", warn: !c.skipped.isEmpty)
        }
    }
}

// MARK: 编辑服务器

/// 编辑器里的服务器（官方 editServer 的 d）。
struct LibraryServerDraft: Identifiable {
    let id = UUID()
    var old: String
    var server: LibraryServer
    var commandLine: String
    var env: [(key: String, value: String)]
    var headers: [(key: String, value: String)]
    var timeout: String

    init(server: LibraryServer?, agents: [String]) {
        old = server?.name ?? ""
        let s = server ?? .blank(agents: agents)
        self.server = s
        commandLine = s.isRemote ? "" : s.line
        env = s.env.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        headers = s.headers.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        timeout = s.startupTimeout > 0 ? String(s.startupTimeout) : ""
    }

    /// 编辑完的服务器。
    var built: LibraryServer {
        var s = server
        s.name = s.name.trimmingCharacters(in: .whitespaces)
        if s.isRemote {
            s.url = s.url.trimmingCharacters(in: .whitespaces)
            s.headers = Dictionary(headers.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }.map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) }, uniquingKeysWith: { _, b in b })
        } else {
            let words = LibraryShell.words(commandLine)
            s.command = words.first ?? ""
            s.args = Array(words.dropFirst())
            s.env = Dictionary(env.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }.map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) }, uniquingKeysWith: { _, b in b })
        }
        s.startupTimeout = Int(timeout.trimmingCharacters(in: .whitespaces)) ?? 0
        return s
    }

    /// 不能保存的原因。
    var problem: String? {
        let s = built
        if !LibraryShell.validName(s.name) { return "名称只能用字母、数字、- 和 _" }
        if s.isRemote && !(s.url.hasPrefix("http://") || s.url.hasPrefix("https://")) { return "地址要以 http:// 或 https:// 开头" }
        if !s.isRemote && s.command.isEmpty { return "请填写命令" }
        return nil
    }
}

struct LibraryServerEditor: View {
    let store: LibraryStore
    @State var draft: LibraryServerDraft
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var confirm: LibraryConfirm?
    /// 粘贴的 JSON 里有好几个服务器时，除第一个以外的。
    @State private var morePasted: [LibraryServer] = []

    init(store: LibraryStore, draft: LibraryServerDraft) {
        self.store = store
        _draft = State(initialValue: draft)
    }

    private var page: LibrarySnapshot? { store.page }
    private var all: [LibraryAgent] { page?.mcpAgents(hidden: store.hidden) ?? [] }
    private var isNew: Bool { draft.old.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如 github", text: $draft.server.name)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("library.serverEditor.name")
                } header: {
                    Text("名称")
                } footer: {
                    Text("字母、数字、- 和 _ — Agent 用这个名字称呼它")
                }

                Section {
                    Picker("运行方式", selection: $draft.server.transport) {
                        Text("命令").tag("stdio")
                        Text("HTTP").tag("http")
                        Text("SSE").tag("sse")
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("library.serverEditor.transport")
                    if draft.server.isRemote {
                        TextField("https://…", text: $draft.server.url)
                            .font(.footnote.monospaced())
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("library.serverEditor.url")
                    } else {
                        TextField("npx -y @modelcontextprotocol/server-github", text: $draft.commandLine, axis: .vertical)
                            .font(.footnote.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("library.serverEditor.command")
                    }
                } header: {
                    Text("运行方式")
                } footer: {
                    Text(draft.server.isRemote ? "地址" : "命令及参数，就像在终端里输入的那样")
                }

                Section {
                    if draft.server.isRemote {
                        LibraryPairsEditor(pairs: $draft.headers, keyHint: "Authorization", valueHint: "Bearer …", id: "library.serverEditor.headers")
                    } else {
                        LibraryPairsEditor(pairs: $draft.env, keyHint: "GITHUB_TOKEN", valueHint: "值", id: "library.serverEditor.env")
                    }
                } header: {
                    Text(draft.server.isRemote ? "请求头" : "环境变量")
                } footer: {
                    Text("值可以引用环境变量，写作 ${NAME}：每个智能体按自己的语法读取它，令牌不会写进它的设置")
                }

                Section {
                    Toggle("只在这台电脑", isOn: $draft.server.local)
                    if page?.mcpHub == true {
                        Toggle("经过 MCP 路由", isOn: Binding(get: { draft.server.hub != "direct" }, set: { draft.server.hub = $0 ? "" : "direct" }))
                    }
                    let startup = all.filter(\.startup)
                    if !startup.isEmpty && draft.server.transport == "stdio" {
                        TextField("启动超时（秒）", text: $draft.timeout)
                            .keyboardType(.numberPad)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("同步不会把它带到你的其他电脑；其他电脑同步过来时，既不会删掉它，也不会用它们的同名服务器替换它")
                        if page?.mcpHub == true { Text("关掉后，每个 Agent 各自有它的条目，和关掉路由时一样：适合从启动目录读取项目、或保存会话状态的服务器") }
                        let startup = all.filter(\.startup).map(\.name).joined(separator: "、")
                        if !startup.isEmpty && draft.server.transport == "stdio" {
                            Text("\(startup) 等它启动并列出工具的秒数。留空用 \(startup) 自己的 30 秒；你在它的 config.toml 里手写的值会保留")
                        }
                    }
                }

                Section {
                    let built = draft.built
                    LibraryChips(agents: page?.withGone(all, on: draft.server.agents, hidden: store.hidden) ?? all, on: draft.server.agents,
                                 blocked: { built.blocked(for: $0) }, id: "library.serverEditor.agents",
                                 onChange: { next, _ in draft.server.agents = next },
                                 onBlocked: { error = $0 })
                } header: {
                    Text("Agent")
                }

                if isNew {
                    Section {
                        Button {
                            paste()
                        } label: {
                            Label("粘贴 README 里的 JSON", systemImage: "doc.on.clipboard")
                        }
                        .accessibilityIdentifier("library.serverEditor.paste")
                    } footer: {
                        Text(morePasted.isEmpty ? "或直接在此粘贴它的 JSON" : "粘贴的内容里还有 \(morePasted.count) 个服务器，保存时一起添加：\(morePasted.map(\.name).joined(separator: ", "))")
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                        .accessibilityIdentifier("library.serverEditor.error")
                }

                if !isNew {
                    Section {
                        Button("从资源库移除", role: .destructive) {
                            let who = draft.server.agents.map { page?.name(of: $0) ?? $0 }
                            confirm = LibraryConfirm(title: "删除 MCP 服务器 \(draft.old)？", message: LibraryWords.removeServerMessage(draft.server, agents: who, projects: page?.projects.filter { $0.servers[draft.old] != nil }.count ?? 0), button: "移除") {
                                if await store.run(.serversRemove, LibraryRequests.name(draft.old), done: "\(draft.old) 已从资源库及相关 Agent 中移除") { dismiss() }
                            }
                        }
                        .accessibilityIdentifier("library.serverEditor.remove")
                    }
                }
            }
            .detailHeader(isNew ? "新的 MCP 服务器" : draft.old)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "添加" : "保存") { Task { await save() } }
                        .disabled(store.busy)
                        .accessibilityIdentifier("library.serverEditor.save")
                }
            }
            .libraryConfirm($confirm)
            .interactiveDismissDisabled(store.busy)
        }
    }

    private func paste() {
        guard let text = UIPasteboard.general.string, let list = LibraryShell.servers(fromPasted: text), let first = list.first else {
            error = "剪贴板里没有能读出服务器的 JSON"
            return
        }
        var s = first
        s.agents = all.filter { s.blocked(for: $0) == nil }.map(\.id)
        draft = LibraryServerDraft(server: s, agents: s.agents)
        draft.old = ""
        morePasted = Array(list.dropFirst())
        error = nil
        store.say("已根据粘贴内容填写")
    }

    private func save() async {
        if let problem = draft.problem { error = problem; return }
        var server = draft.built
        server.agents = server.agents.filter { id in all.first { $0.id == id }.map { server.blocked(for: $0) == nil } ?? true }
        guard await store.run(.serversSave, LibraryRequests.saveServer(old: draft.old, server), done: "已保存 \(server.name)") else {
            error = store.failure
            store.failure = nil
            return
        }
        for var more in morePasted {
            more.agents = all.filter { more.blocked(for: $0) == nil }.map(\.id)
            guard await store.run(.serversSave, LibraryRequests.saveServer(old: "", more), done: "已保存 \(more.name)") else { break }
        }
        dismiss()
    }
}

// MARK: 发现（MCP 市场）

struct LibraryServerMarket: View {
    let store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var market: LibraryMarket<LibraryMarketServer>?
    @State private var loading = false
    @State private var error: String?
    @State private var adding: LibraryMarketServer?

    var body: some View {
        NavigationStack {
            List {
                if loading && market == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                if let market {
                    Section {
                        ForEach(market.items) { item in
                            Button {
                                adding = item
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    BrandIcon(item.icon, size: 22).frame(width: 26)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(item.title).foregroundStyle(.primary)
                                            if !item.have.isEmpty { LibraryTag("资源库中") }
                                            if !item.unready.isEmpty { LibraryTag("尚未设置", warn: true) }
                                        }
                                        Text(item.description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                        Text([item.runsLabel, item.publisher].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .accessibilityIdentifier("library.market.server.\(item.name)")
                        }
                    } header: {
                        Text(query.isEmpty ? "精选，以及官方 MCP Registry" : (market.items.count == 1 ? "1 个结果" : "\(market.items.count) 个结果"))
                    } footer: {
                        if !market.failed.isEmpty { Text("MCP Registry 这次没有响应（\(market.cause)），下面只是 magpie 精选服务器里匹配的结果。") }
                        else if market.items.isEmpty { Text(query.isEmpty ? "暂无内容。" : "没有与“\(query)”匹配的结果。") }
                    }
                }
            }
            .searchable(text: $query, prompt: "搜索 MCP 服务器 — GitHub、Postgres、Figma…")
            .onSubmit(of: .search) { Task { await search() } }
            .task { await search() }
            .detailHeader("发现")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .sheet(item: $adding) { item in
                LibraryServerMarketAdd(store: store, item: item) { Task { await search() } }
            }
        }
    }

    private func search() async {
        loading = true
        defer { loading = false }
        do {
            market = try await store.marketServers(query)
            error = nil
        } catch {
            self.error = MagpieError.from(error).message
        }
    }
}

/// 加入资源库前填它要的值、选 Agent（官方 serverSheet）。
private struct LibraryServerMarketAdd: View {
    let store: LibraryStore
    let item: LibraryMarketServer
    var added: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var agents: [String] = []
    @State private var error: String?

    private var all: [LibraryAgent] { store.page?.mcpAgents(hidden: store.hidden) ?? [] }
    private var probe: LibraryServer { LibraryServer(json: ["name": .string(item.name), "transport": .string(item.transport.isEmpty ? "stdio" : item.transport), "agents": []]) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(item.description).font(.footnote)
                    if !item.homepage.isEmpty, let url = URL(string: item.homepage) { Link("主页", destination: url) }
                    if !item.unready.isEmpty { Text(item.unready).font(.footnote).foregroundStyle(.orange) }
                    if item.signIn { Text("每个 Agent 首次使用时会在浏览器中请你登录。").font(.footnote).foregroundStyle(.secondary) }
                }
                if !item.inputs.isEmpty {
                    Section {
                        ForEach(item.inputs) { input in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(input.label + (input.required ? "" : "（可选）")).font(.footnote)
                                Group {
                                    if input.secret {
                                        SecureField(input.placeholder, text: binding(input.key))
                                    } else {
                                        TextField(input.placeholder, text: binding(input.key))
                                    }
                                }
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                if !input.description.isEmpty { Text(input.description).font(.caption).foregroundStyle(.secondary) }
                                if input.place == "header" { Text("作为 \(input.key) 请求头发送").font(.caption2).foregroundStyle(.tertiary) }
                                else if input.place == "env" { Text("设为 \(input.key)").font(.caption2).foregroundStyle(.tertiary) }
                            }
                        }
                    }
                }
                Section {
                    LibraryChips(agents: all, on: agents, blocked: { probe.blocked(for: $0) }, id: "library.marketAdd.agents",
                                 onChange: { next, _ in agents = next }, onBlocked: { error = $0 })
                } header: {
                    Text("Agent")
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
                if !item.have.isEmpty {
                    Section { Text("已在资源库中，名为 \(item.have)").foregroundStyle(.secondary) }
                }
            }
            .detailHeader(item.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("加入资源库") { Task { await add() } }
                        .disabled(store.busy || !item.have.isEmpty)
                        .accessibilityIdentifier("library.marketAdd.add")
                }
            }
            .onAppear { agents = all.filter { probe.blocked(for: $0) == nil }.map(\.id) }
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    private func add() async {
        if let missing = item.inputs.first(where: { $0.required && (values[$0.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }) {
            error = "请填写 \(missing.label)"
            return
        }
        guard await store.run(.marketServer, LibraryRequests.marketServer(id: item.id, values: values, agents: agents), done: "\(item.name) 已加入资源库") else {
            error = store.failure
            store.failure = nil
            return
        }
        added()
        dismiss()
    }
}

// MARK: 项目（只读）

/// 「项目中」（官方 renderProjects）：App 只列出来；添加项目要在 Mac 上选文件夹，在网页里做。
struct LibraryProjectsSection: View {
    let page: LibrarySnapshot
    let kind: LibraryTab

    var body: some View {
        let projects = page.projects.filter { kind == .mcp ? !$0.servers.isEmpty : !$0.skills.isEmpty }
        if !projects.isEmpty {
            Section {
                ForEach(projects) { project in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(project.name)
                            if project.missing { LibraryTag("文件夹不见了", warn: true) }
                        }
                        Text(page.tilde(project.dir)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        let items = kind == .mcp ? project.servers : project.skills
                        Text(items.keys.sorted().map { "\($0)（\(items[$0, default: []].map(page.name(of:)).joined(separator: "、"))）" }.joined(separator: "，"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("项目中")
            } footer: {
                Text("添加或修改项目要在 Mac 上选文件夹，请在「在网页中打开资源库」里操作。")
            }
        }
    }
}
