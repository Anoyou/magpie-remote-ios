import SwiftUI
import MagpieRemoteCore

/// 「用量 › 请求」（请求记录）：合计、趋势图与排名、最近一年的热力图，再按时间倒序列出每一次请求，滚到底自动加载下一页
/// （每页 100 条）。筛选与 magpie 网页 Requests 一致：只看失败 / 重试过、Agent、用途、供应商、模型、账号、密钥、电脑、来源，可搜索、可导出 CSV。
/// 既是「用量」页的一个标签（embedded），也能从「概览」里单独推入（标题「请求记录」）。
struct UsageRequestsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ManageStore.self) private var manage
    @Binding var period: UsagePeriod
    let held: Bool
    var embedded = false

    @State private var failedOnly = false
    @State private var retriedOnly = false
    @State private var modelFilter: UsageOption?
    @State private var agentFilter: UsageOption?
    @State private var keyFilter: UsageOption?
    @State private var providerFilter: UsageOption?
    @State private var accountFilter: UsageOption?
    @State private var purposeFilter: UsageOption?
    @State private var computerFilter: UsageOption?
    @State private var viaFilter: UsageOption?
    @State private var search = ""

    @State private var pager = UsageRequestPager(query: UsageRequestQuery())
    @State private var loading = false
    @State private var error: MagpieError?
    /// 筛选菜单的可选项：取自该时间段未筛选时的第一页，避免筛选后选项变少。
    @State private var options = Options()
    /// 当前条件下的第一页：合计、趋势图与排名都取自它。
    @State private var dashboard: UsageRequestPage?
    @State private var selected: UsageRequestRow?
    @State private var heatmap: UsageHeatmap?
    @State private var exporting = false
    @State private var exportFile: ExportFile?
    @State private var exportError: MagpieError?

    private struct Options: Equatable {
        var period: UsagePeriod?
        var models: [UsageOption] = []
        var agents: [UsageOption] = []
        var keys: [UsageOption] = []
        var providers: [UsageOption] = []
        var accounts: [UsageOption] = []
        var purposes: [UsageOption] = []
        var computers: [UsageOption] = []
        var vias: [UsageOption] = []
    }

    private struct ExportFile: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private var web: (any UsageWebServing)? { UsageWebServices.make(from: manage.service) }

    private var query: UsageRequestQuery {
        UsageRequestQuery(period: period, failedOnly: failedOnly, retriedOnly: retriedOnly,
                          model: modelFilter?.id, agent: agentFilter?.id, callerKey: keyFilter?.id,
                          provider: providerFilter?.id, account: accountFilter?.id, purpose: purposeFilter?.id,
                          computer: computerFilter?.id, via: viaFilter?.id, search: search)
    }

    private struct HeatKey: Equatable {
        var query: UsageRequestQuery
        var web: String
    }

    var body: some View {
        List {
            Section {
                UsagePeriodPicker(period: $period)
                    .accessibilityIdentifier("usage.requests.period")
                filterBar
                // 合计条数紧跟在筛选下面：改了筛选马上看得到结果有多少条（下面还有合计、趋势和热力图，列表在最后）。
                if pager.loadedOnce {
                    Text(totalText)
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier("usage.requests.total")
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

            if held {
                Section { UsageHeldKeyNote() }
            }

            if let dashboard, dashboard.total > 0, pager.loadedOnce {
                UsageLedgerDashboard(page: dashboard, failedOnly: $failedOnly, retriedOnly: $retriedOnly) { split, share in
                    pick(split, share)
                }
            }

            if let heatmap, !heatmap.isEmpty {
                UsageHeatmapSection(heatmap: heatmap)
            }

            if let error, pager.rows.isEmpty {
                Section { ErrorStateView(error: error) { Task { await reload(debounce: false) } } }
            } else if pager.loadedOnce && pager.rows.isEmpty {
                Section {
                    ContentUnavailableView(query.isFiltered ? "没有符合条件的请求" : "这段时间没有请求",
                                           systemImage: "tray",
                                           description: Text(query.isFiltered ? "换个筛选条件试试。" : "换个时间段看看。"))
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(Array(pager.rows.enumerated()), id: \.element.id) { index, row in
                        Button { selected = row } label: { UsageRequestRowView(row: row) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("usage.request.\(index)")
                            .onAppear {
                                if index >= pager.rows.count - 10 { Task { await loadMore() } }
                            }
                    }
                } header: {
                    if pager.loadedOnce {
                        Text("请求列表")
                    }
                } footer: {
                    if loading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if let error {
                        Button("加载失败：\(error.title)，点此重试") { Task { await loadMore() } }
                    } else if pager.loadedOnce && !pager.hasMore && pager.rows.count > 20 {
                        Text("已经到底了").frame(maxWidth: .infinity)
                    } else if pager.loadedOnce {
                        Text("包括经过网关的请求与从 Agent 会话文件读到的调用；被本机拒绝的请求不计入合计。")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .modifier(RequestsTitle(embedded: embedded))
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索模型、供应商、会话")
        .toolbar {
            if web != nil {
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        Task { await export() }
                    } label: {
                        Label(exporting ? "正在导出…" : "导出 CSV", systemImage: "square.and.arrow.up")
                    }
                    .disabled(exporting || pager.total == 0)
                    .accessibilityIdentifier("usage.requests.export")
                }
            }
        }
        .refreshable { await reload(debounce: false); await loadHeatmap() }
        .task(id: query) { await reload(debounce: !search.isEmpty) }
        .task(id: HeatKey(query: query.firstPage, web: manage.configurationKey)) { await loadHeatmap() }
        .sheet(item: $selected) { row in
            UsageRequestDetailView(row: row, web: web)
        }
        .sheet(item: $exportFile) { file in
            SessionShareSheet(items: [file.url])
        }
        .alert("导出失败", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(exportError?.title ?? "")
        }
    }

    private var totalText: String {
        var parts = ["共 \(UsageFormat.count(pager.total)) 条"]
        if pager.totals.errors > 0 && !failedOnly { parts.append("失败 \(UsageFormat.count(pager.totals.errors))") }
        if pager.totals.cost > 0 { parts.append(UsageFormat.cost(pager.totals.cost)) }
        return parts.joined(separator: " · ")
    }

    // MARK: 筛选

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("只看失败", systemImage: "exclamationmark.triangle", on: failedOnly, id: "usage.filter.failed") {
                    failedOnly.toggle()
                    if failedOnly { retriedOnly = false }
                }
                chip("重试过", systemImage: "arrow.clockwise", on: retriedOnly, id: "usage.filter.retried") {
                    retriedOnly.toggle()
                    if retriedOnly { failedOnly = false }
                }
                if !options.computers.isEmpty {
                    optionMenu("电脑", options: options.computers, selection: $computerFilter, id: "usage.filter.computer")
                }
                optionMenu("Agent", options: options.agents, selection: $agentFilter, id: "usage.filter.agent")
                if !options.purposes.isEmpty {
                    optionMenu("用途", options: options.purposes, selection: $purposeFilter, id: "usage.filter.purpose")
                }
                optionMenu("供应商", options: options.providers, selection: $providerFilter, id: "usage.filter.provider")
                optionMenu("模型", options: options.models, selection: $modelFilter, id: "usage.filter.model")
                if !options.accounts.isEmpty {
                    optionMenu("账号", options: options.accounts, selection: $accountFilter, id: "usage.filter.account")
                }
                if !held {
                    optionMenu("密钥", options: options.keys, selection: $keyFilter, id: "usage.filter.key")
                }
                if options.vias.count > 1 {
                    optionMenu("来源", options: options.vias, selection: $viaFilter, id: "usage.filter.via")
                }
                if query.isFiltered {
                    Button("清除") {
                        failedOnly = false; retriedOnly = false
                        modelFilter = nil; agentFilter = nil; keyFilter = nil; providerFilter = nil; accountFilter = nil
                        purposeFilter = nil; computerFilter = nil; viaFilter = nil; search = ""
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("usage.filter.clear")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func chip(_ title: String, systemImage: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        if on {
            Button(action: action) { Label(title, systemImage: systemImage).font(.subheadline) }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier(id)
                .accessibilityAddTraits(.isSelected)
        } else {
            Button(action: action) { Label(title, systemImage: systemImage).font(.subheadline) }
                .buttonStyle(.glass)
                .accessibilityIdentifier(id)
        }
    }

    private func optionMenu(_ title: String, options: [UsageOption], selection: Binding<UsageOption?>, id: String) -> some View {
        Menu {
            Button("全部") { selection.wrappedValue = nil }
            ForEach(options) { option in
                Button {
                    selection.wrappedValue = option
                } label: {
                    if selection.wrappedValue?.id == option.id { Label(option.name, systemImage: "checkmark") } else { Text(option.name) }
                }
            }
        } label: {
            Label(selection.wrappedValue.map { "\(title)：\($0.name)" } ?? title, systemImage: "line.3.horizontal.decrease")
                .font(.subheadline)
                .lineLimit(1)
        }
        .buttonStyle(.glass)
        .disabled(options.isEmpty && selection.wrappedValue == nil)
        .accessibilityIdentifier(id)
    }

    /// 点排名里的一项：只看它的请求；再点一次放开（magpie drawLedRank 的点击）。
    private func pick(_ split: UsageTrendSplit, _ share: UsageShare) {
        let option = UsageOption(id: share.id, name: share.displayName)
        func toggle(_ binding: Binding<UsageOption?>) {
            binding.wrappedValue = binding.wrappedValue?.id == option.id ? nil : option
        }
        switch split {
        case .model: toggle($modelFilter)
        case .provider: toggle($providerFilter)
        case .agent: toggle($agentFilter)
        case .callerKey: toggle($keyFilter)
        case .modelAt:
            guard let cut = share.id.firstIndex(of: "/") else { return }
            let provider = String(share.id[..<cut]), modelID = String(share.id[share.id.index(after: cut)...])
            if providerFilter?.id == provider && modelFilter?.id == modelID {
                providerFilter = nil; modelFilter = nil
            } else {
                providerFilter = UsageOption(id: provider, name: options.providers.first { $0.id == provider }?.name ?? provider)
                modelFilter = UsageOption(id: modelID, name: modelID)
            }
        }
    }

    // MARK: 加载

    private func reload(debounce: Bool) async {
        if debounce {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
        }
        let first = query.firstPage
        pager = UsageRequestPager(query: first)
        error = nil
        await fetch(first)
    }

    private func loadMore() async {
        guard !loading, pager.loadedOnce, let next = pager.nextQuery else { return }
        error = nil
        await fetch(next)
    }

    private func fetch(_ request: UsageRequestQuery) async {
        guard case .connected = model.connection else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await model.loadUsageRequests(request)
            // 期间条件变了：丢掉过期的回复。
            guard pager.query == request.firstPage else { return }
            pager.apply(page, requestedOffset: request.offset)
            if request.offset == 0 { dashboard = page }
            if request.offset == 0 && !request.isFiltered && options.period != request.period {
                options = Self.options(from: page, period: request.period)
            }
        } catch {
            guard pager.query == request.firstPage else { return }
            let mapped = MagpieError.from(error)
            if mapped != .cancelled { self.error = mapped }
        }
    }

    private static func options(from page: UsageRequestPage, period: UsagePeriod) -> Options {
        var vias: [UsageOption] = []
        if page.through.calls > 0 { vias.append(UsageOption(id: "gateway", name: "经网关")) }
        if page.direct.calls > 0 { vias.append(UsageOption(id: "log", name: "会话文件")) }
        if page.reported.calls > 0 { vias.append(UsageOption(id: "reported", name: "客户端上报")) }
        return Options(period: period, models: page.models, agents: page.agents, keys: page.callerKeys,
                       providers: page.providers, accounts: page.accounts,
                       purposes: page.purposes.map { UsageOption(id: $0, name: UsagePurpose.title($0)) },
                       computers: page.computers.map { UsageOption(id: $0.id, name: $0.displayName) },
                       vias: vias)
    }

    private func loadHeatmap() async {
        guard let web, case .connected = model.connection else { heatmap = nil; return }
        do {
            let result = try await web.heatmap(query.firstPage)
            guard !Task.isCancelled else { return }
            heatmap = result
        } catch {
            // 热力图只是补充：读不到（旧版 magpie、没填 Web 密钥）就不显示。
            if !Task.isCancelled { heatmap = nil }
        }
    }

    private func export() async {
        guard let web else { return }
        exporting = true
        defer { exporting = false }
        do {
            let csv = try await web.requestsCSV(query.firstPage)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(csv.filename)
            try Data(csv.text.utf8).write(to: url, options: .atomic)
            exportFile = ExportFile(url: url)
        } catch {
            let mapped = MagpieError.from(error)
            if mapped != .cancelled { exportError = mapped }
        }
    }
}

/// 单独推入时标题是「请求记录」；作为「用量」的标签时沿用「用量」。
private struct RequestsTitle: ViewModifier {
    let embedded: Bool

    func body(content: Content) -> some View {
        if embedded {
            content
        } else {
            content
                .navigationTitle("请求记录")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// 调用用途（usage.Record.Purpose）的中文名；不认识的原样显示。
enum UsagePurpose {
    static func title(_ id: String) -> String {
        switch id {
        case "chat": "对话"
        case "title": "起标题"
        case "subagent": "子 Agent"
        case "compact": "压缩上下文"
        case "summary": "总结"
        case "approval": "权限检查"
        case "search": "搜索"
        case "embedding", "embeddings": "向量"
        case "image": "图片"
        default: id
        }
    }
}

// MARK: - 行

struct UsageRequestRowView: View {
    let row: UsageRequestRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.failed ? "xmark.octagon.fill" : "checkmark.circle.fill")
                .foregroundStyle(row.failed ? .red : .green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.model.isEmpty ? "未知模型" : row.model).font(.subheadline.weight(.medium)).lineLimit(1)
                    if row.failed { badge("失败", .red) }
                    if row.retried { badge("重试 \(row.tries - 1) 次", .orange) }
                    if row.swapped { badge("换了模型", .orange) }
                    if row.isFromSessionFile { badge("会话文件", .secondary) }
                }
                Text([UsageFormat.time(row.time), row.agentTitle, row.providerTitle].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let error = row.error, row.failed {
                    Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text(row.priced || row.cost > 0 ? UsageFormat.cost(row.cost) : "—").font(.subheadline.monospacedDigit())
                Text(row.tokens > 0 ? "\(UsageFormat.tokens(row.tokens)) 词元" : UsageFormat.duration(ms: row.ms))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if let speed = row.outputSpeed {
                    Text("\(Int(speed.rounded())) 词元/秒").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.15), in: .capsule)
            .foregroundStyle(color)
    }
}

// MARK: - 详情

struct UsageRequestDetailView: View {
    let row: UsageRequestRow
    var web: (any UsageWebServing)?
    @Environment(\.dismiss) private var dismiss
    @State private var content: UsageRequestContent?
    @State private var contentError: MagpieError?

    var body: some View {
        NavigationStack {
            List {
                Section("概况") {
                    LabeledContent("时间", value: UsageFormat.fullTime(row.time))
                    LabeledContent("状态") {
                        Text(UsageFormat.status(row)).foregroundStyle(row.failed ? .red : .secondary)
                    }
                    LabeledContent("耗时", value: (row.isFromSessionFile ? "≈" : "") + UsageFormat.duration(ms: row.ms))
                    if let ttft = row.ttftMs { LabeledContent("首字耗时", value: UsageFormat.duration(ms: ttft)) }
                    if let speed = row.outputSpeed { LabeledContent("输出速度", value: "\(Int(speed.rounded())) 词元/秒") }
                    LabeledContent("花费", value: row.priced || row.cost > 0 ? UsageFormat.cost(row.cost) : "没有价格")
                    if let kind = row.kind { LabeledContent("用途", value: UsagePurpose.title(kind)) }
                }
                if row.failed || row.retried {
                    Section("错误与重试") {
                        if let error = row.error { Text(error).font(.callout).textSelection(.enabled) }
                        if let type = row.errorType { LabeledContent("错误类型", value: type) }
                        if row.tries > 0 { LabeledContent("尝试次数", value: "\(row.tries)") }
                    }
                }
                Section("模型") {
                    LabeledContent("实际模型", value: row.model.isEmpty ? "—" : row.model)
                    if let requested = row.requestedIfDifferent { LabeledContent("请求的模型", value: requested) }
                    if let served = row.served, served != row.model { LabeledContent("回复里的模型", value: served) }
                    if let provider = row.providerTitle { LabeledContent("供应商", value: provider) }
                    if let upstream = row.upstream { LabeledContent("上游供应商", value: upstream) }
                    if let account = row.providerAccount { LabeledContent("账号", value: account) }
                    if let access = row.access { LabeledContent("方式", value: access == "subscription" ? "订阅" : access == "api" ? "API 密钥" : access) }
                    if let effort = row.effort { LabeledContent("推理强度", value: effort) }
                    if let pricing = row.pricingModel { LabeledContent("按哪个模型的 API 价格算", value: pricing) }
                }
                Section("词元") {
                    LabeledContent("输入", value: UsageFormat.count(row.input))
                    LabeledContent("输出", value: UsageFormat.count(row.output))
                    if row.cacheRead > 0 { LabeledContent("缓存读取", value: UsageFormat.count(row.cacheRead)) }
                    if row.cacheWrite > 0 {
                        LabeledContent("缓存写入", value: UsageFormat.count(row.cacheWrite)
                                       + (row.cacheWrite1h > 0 ? "（其中保留一小时 \(UsageFormat.count(min(row.cacheWrite1h, row.cacheWrite)))）" : ""))
                    }
                    if row.reasoning > 0 { LabeledContent("推理", value: UsageFormat.count(row.reasoning)) }
                    if row.cacheUnknown { Text("这家供应商不报告缓存。").font(.footnote).foregroundStyle(.secondary) }
                }
                let timing = row.timingBreakdown
                if !timing.isEmpty {
                    Section("首字之前") {
                        ForEach(Array(timing.enumerated()), id: \.offset) { _, item in
                            LabeledContent(item.title, value: UsageFormat.duration(ms: item.ms))
                        }
                    }
                }
                Section("来源") {
                    LabeledContent("Agent", value: row.agentTitle)
                    if let client = row.client { LabeledContent("客户端", value: client) }
                    if let computer = row.computerName ?? row.computer { LabeledContent("电脑", value: computer) }
                    LabeledContent("网关密钥", value: row.callerKeyTitle ?? "未用网关密钥（本机）")
                    if let session = row.session { LabeledContent("会话", value: session) }
                    if let endpoint = row.endpoint { LabeledContent("接口", value: endpoint) }
                    if let proto = row.protocolText { LabeledContent("协议", value: proto) }
                    if let rid = row.requestID { LabeledContent("请求 ID", value: rid) }
                    if let stop = row.stop { LabeledContent("上游停止原因", value: stop) }
                    if let provider = row.sessionProvider { LabeledContent("记录的供应商 ID", value: provider) }
                    if let account = row.sessionAccount { LabeledContent("会话账号", value: account) }
                    if row.isFromSessionFile && row.sessionAccount != nil && row.sessionOfficialLogin { LabeledContent("登录方式", value: "官方登录") }
                    if row.isFromSessionFile {
                        Text("读自 Agent 的会话文件。只有本地元数据能认出账号时才显示账号，不推测供应商。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                contentSection
            }
            .navigationTitle("请求详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("usage.detail.done")
                }
            }
            .task { await loadContent() }
        }
    }

    /// 说了什么：magpie 从 Agent 的会话文件里读出来（它不留副本）。
    @ViewBuilder private var contentSection: some View {
        if row.computer != nil {
            Section("内容") {
                Text("说了什么留在 \(row.computerName ?? row.computer ?? "那台电脑") 上：同步只带用量。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } else if web != nil {
            if let content {
                if content.found {
                    Section("输入") {
                        if content.input.isEmpty { Text("这里什么也没说").foregroundStyle(.secondary) }
                        ForEach(content.input) { RequestContentBubble(part: $0) }
                    }
                    Section {
                        if content.output.isEmpty { Text("这里什么也没说").foregroundStyle(.secondary) }
                        ForEach(content.output) { RequestContentBubble(part: $0) }
                    } header: {
                        Text("输出")
                    } footer: {
                        Text((content.cut ? "内容比这里显示的多。" : "") + "读自 Agent 的会话文件；magpie 不留副本。")
                    }
                    .accessibilityIdentifier("usage.detail.content")
                } else {
                    Section("内容") { Text(content.whyText).font(.footnote).foregroundStyle(.secondary) }
                }
            } else if let contentError {
                Section("内容") { Text("读不到内容：\(contentError.title)").font(.footnote).foregroundStyle(.secondary) }
            } else {
                Section("内容") { ProgressView().frame(maxWidth: .infinity) }
            }
        }
    }

    private func loadContent() async {
        guard let web, row.computer == nil, content == nil else { return }
        do {
            content = try await web.requestContent(row)
        } catch {
            let mapped = MagpieError.from(error)
            if mapped != .cancelled { contentError = mapped }
        }
    }
}

/// 请求内容的一段（对话、思考、工具调用 / 结果）。
private struct RequestContentBubble: View {
    let part: TranscriptPart
    @State private var expanded = false

    private var collapsible: Bool { !part.isConversation && part.text.count > 240 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(part.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(part.role == .user ? Color.accentColor : .secondary)
            Text(part.text.isEmpty ? "（空）" : part.text)
                .font(part.isConversation ? .callout : .caption.monospaced())
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
    }
}
