import SwiftUI
import MagpieRemoteCore

/// 请求记录：按时间倒序，滚到底自动加载下一页（每页 100 条），可筛选失败 / 重试过 / 模型 / Agent / 密钥，可搜索。
struct UsageRequestsView: View {
    @Environment(AppModel.self) private var model
    @Binding var period: UsagePeriod
    let held: Bool

    @State private var failedOnly = false
    @State private var retriedOnly = false
    @State private var modelFilter: UsageOption?
    @State private var agentFilter: UsageOption?
    @State private var keyFilter: UsageOption?
    @State private var search = ""

    @State private var pager = UsageRequestPager(query: UsageRequestQuery())
    @State private var loading = false
    @State private var error: MagpieError?
    /// 筛选菜单的可选项：取自该时间段未筛选时的第一页，避免筛选后选项变少。
    @State private var options = Options()
    @State private var selected: UsageRequestRow?

    private struct Options: Equatable {
        var period: UsagePeriod?
        var models: [UsageOption] = []
        var agents: [UsageOption] = []
        var keys: [UsageOption] = []
    }

    private var query: UsageRequestQuery {
        UsageRequestQuery(period: period, failedOnly: failedOnly, retriedOnly: retriedOnly,
                          model: modelFilter?.id, agent: agentFilter?.id, callerKey: keyFilter?.id, search: search)
    }

    var body: some View {
        List {
            Section {
                UsagePeriodPicker(period: $period)
                    .accessibilityIdentifier("usage.requests.period")
                filterBar
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

            if held {
                Section { UsageHeldKeyNote() }
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
                        Text(totalText)
                            .accessibilityIdentifier("usage.requests.total")
                    }
                } footer: {
                    if loading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if let error {
                        Button("加载失败：\(error.title)，点此重试") { Task { await loadMore() } }
                    } else if pager.loadedOnce && !pager.hasMore && pager.rows.count > 20 {
                        Text("已经到底了").frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("请求记录")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索模型、供应商、会话")
        .refreshable { await reload(debounce: false) }
        .task(id: query) { await reload(debounce: !search.isEmpty) }
        .sheet(item: $selected) { row in
            UsageRequestDetailView(row: row)
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
                chip("只看失败", systemImage: "exclamationmark.triangle", on: failedOnly, id: "usage.filter.failed") { failedOnly.toggle() }
                chip("重试过", systemImage: "arrow.clockwise", on: retriedOnly, id: "usage.filter.retried") { retriedOnly.toggle() }
                optionMenu("模型", options: options.models, selection: $modelFilter, id: "usage.filter.model")
                optionMenu("Agent", options: options.agents, selection: $agentFilter, id: "usage.filter.agent")
                if !held {
                    optionMenu("密钥", options: options.keys, selection: $keyFilter, id: "usage.filter.key")
                }
                if query.isFiltered {
                    Button("清除") {
                        failedOnly = false; retriedOnly = false
                        modelFilter = nil; agentFilter = nil; keyFilter = nil; search = ""
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
            if request.offset == 0 && !request.isFiltered && options.period != request.period {
                options = Options(period: request.period, models: page.models, agents: page.agents, keys: page.callerKeys)
            }
        } catch {
            guard pager.query == request.firstPage else { return }
            let mapped = MagpieError.from(error)
            if mapped != .cancelled { self.error = mapped }
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("概况") {
                    LabeledContent("时间", value: UsageFormat.fullTime(row.time))
                    LabeledContent("状态") {
                        Text(UsageFormat.status(row)).foregroundStyle(row.failed ? .red : .secondary)
                    }
                    LabeledContent("耗时", value: UsageFormat.duration(ms: row.ms))
                    if let ttft = row.ttftMs { LabeledContent("首字耗时", value: UsageFormat.duration(ms: ttft)) }
                    LabeledContent("花费", value: row.priced || row.cost > 0 ? UsageFormat.cost(row.cost) : "没有价格")
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
                    if let provider = row.providerTitle { LabeledContent("供应商", value: provider) }
                    if let account = row.providerAccount { LabeledContent("账号", value: account) }
                    if let access = row.access { LabeledContent("方式", value: access == "subscription" ? "订阅" : access == "api" ? "API 密钥" : access) }
                    if let effort = row.effort { LabeledContent("推理强度", value: effort) }
                }
                Section("词元") {
                    LabeledContent("输入", value: UsageFormat.count(row.input))
                    LabeledContent("输出", value: UsageFormat.count(row.output))
                    if row.cacheRead > 0 { LabeledContent("缓存读取", value: UsageFormat.count(row.cacheRead)) }
                    if row.cacheWrite > 0 { LabeledContent("缓存写入", value: UsageFormat.count(row.cacheWrite)) }
                    if row.reasoning > 0 { LabeledContent("推理", value: UsageFormat.count(row.reasoning)) }
                }
                Section("来源") {
                    LabeledContent("Agent", value: row.agentTitle)
                    LabeledContent("网关密钥", value: row.callerKeyTitle ?? "未用网关密钥（本机）")
                    if let session = row.session { LabeledContent("会话", value: session) }
                    if let endpoint = row.endpoint { LabeledContent("接口", value: endpoint) }
                }
            }
            .navigationTitle("请求详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("usage.detail.done")
                }
            }
        }
    }
}
