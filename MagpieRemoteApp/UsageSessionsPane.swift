import SwiftUI
import Charts
import MagpieRemoteCore

/// 「用量 › 会话」：按会话看用量，与 magpie 网页 Usage 页的 Sessions 标签一致——范围、Agent / 模型 / 文件夹筛选、
/// 六个合计（会话、词元、花费、缓存读取、活跃、项目）、每天的图、项目与模型、时段、最费的会话、会话形态、技能、工具，
/// 最后是范围内最近的会话（点开看对话）。跟「Agent 会话记录」（管理、删除会话文件）不是一个页面，底部有入口。
struct UsageSessionsPane: View {
    let service: (any UsageWebServing)?
    let manage: ManageStore

    @AppStorage("usage.sessions.range") private var rangeRaw = SessionRange.month.rawValue
    @AppStorage("usage.sessions.metric") private var metricRaw = SessionMetric.tokens.rawValue
    @State private var filter = SessionFilter()
    @State private var stats: SessionStats?
    @State private var overview: SessionStatsOverview?
    @State private var list: UsageSessionList?
    @State private var error: MagpieError?
    @State private var shown = 50

    private var range: SessionRange { SessionRange(rawValue: rangeRaw) ?? .month }
    private var metric: SessionMetric { SessionMetric(rawValue: metricRaw) ?? .tokens }

    private struct OverviewKey: Equatable {
        var range: SessionRange
        var agent: String?
        var model: String?
        var folder: String?
    }

    var body: some View {
        List {
            Section {
                Picker("范围", selection: $rangeRaw) {
                    ForEach(SessionRange.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("usage.sessions.range")
                if let stats { filterBar(SessionUsageReport(stats: stats, overview: nil, filter: filter)) }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

            if service == nil {
                Section { ContentUnavailableView("会话", systemImage: "bubble.left.and.text.bubble.right", description: Text("这台主机暂时不能读取会话用量。")) }
            } else if let error, stats == nil {
                Section { ErrorStateView(error: error) { Task { await loadAll() } } }
            } else if let stats {
                content(stats)
            } else {
                Section {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("正在读取 Agent 的会话文件…").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $filter.search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索会话")
        .refreshable { await loadAll() }
        .task(id: range) { await loadAll() }
        .task(id: OverviewKey(range: range, agent: filter.agent, model: filter.model, folder: filter.folder)) { await loadOverview() }
    }

    // MARK: 内容

    @ViewBuilder
    private func content(_ stats: SessionStats) -> some View {
        let report = SessionUsageReport(stats: stats, overview: overview, filter: filter)
        let sessions = SessionUsageReport.sessions(list?.sessions ?? [], stats: stats, range: range, filter: filter)
        if !report.hasUsage && sessions.isEmpty {
            Section {
                ContentUnavailableView(filter.isFiltered ? "没有符合条件的会话" : "这段时间没有会话", systemImage: "tray",
                                       description: Text(filter.isFiltered ? "换个筛选条件试试。"
                                                         : "这台 Mac 上 Claude Code、Codex、Hermes、OpenCode、Pi 的会话会出现在这里。"))
            }
            .listRowBackground(Color.clear)
            if range != .all {
                Section { Button("看全部时间") { rangeRaw = SessionRange.all.rawValue } }
            }
        } else {
            Section {
                tiles(report)
            } header: {
                Text("合计")
            }
            .accessibilityIdentifier("usage.sessions.stats")

            if report.days.count >= 2 {
                Section("每天") { dailyChart(report) }
            }
            barsSection("项目", picks: report.folders, selected: filter.folder, id: "usage.sessions.projects") { filter.folder = $0 }
            barsSection("模型", picks: report.models, selected: filter.model, id: "usage.sessions.models") { filter.model = $0 }
            hoursSection(report)
            if let overview {
                SessionTopSection(overview: overview, agents: stats.agents)
                SessionShapeSection(overview: overview)
                skillsSection(overview, agents: stats.agents)
                toolsSection(overview)
            }
            listSection(sessions)
        }
    }

    private func filterBar(_ report: SessionUsageReport) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pickMenu("全部 Agent", "Agent", picks: report.agents, selection: $filter.agent, id: "usage.sessions.agent")
                pickMenu("全部模型", "模型", picks: report.models, selection: $filter.model, id: "usage.sessions.model")
                pickMenu("全部文件夹", "文件夹", picks: report.folders, selection: $filter.folder, id: "usage.sessions.folder")
                if filter.agent != nil || filter.model != nil || filter.folder != nil {
                    Button("清除") { filter.agent = nil; filter.model = nil; filter.folder = nil }
                        .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
    }

    private func pickMenu(_ all: String, _ title: String, picks: [SessionPick], selection: Binding<String?>, id: String) -> some View {
        Menu {
            Button(all) { selection.wrappedValue = nil }
            ForEach(picks) { pick in
                Button {
                    selection.wrappedValue = pick.id
                } label: {
                    let label = pick.tokens > 0 ? "\(pick.name)（\(UsageFormat.tokens(pick.tokens)) 词元）" : pick.name
                    if selection.wrappedValue == pick.id { Label(label, systemImage: "checkmark") } else { Text(label) }
                }
            }
        } label: {
            let name = selection.wrappedValue.map { id in picks.first { $0.id == id }?.name ?? id }
            Label(name.map { "\(title)：\($0)" } ?? all, systemImage: "line.3.horizontal.decrease")
                .font(.subheadline)
                .lineLimit(1)
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier(id)
    }

    private func tiles(_ report: SessionUsageReport) -> some View {
        let lead = report.folders.first
        let spent = report.folders.reduce(0) { $0 + $1.tokens }
        return Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                tile(overview.map { UsageFormat.count($0.count) } ?? "—", "会话",
                     overview.flatMap { $0.count > 0 ? "中位数 \(UsageFormat.tokens($0.median)) · p90 \(UsageFormat.tokens($0.p90))" : nil } ?? "")
                tile(UsageFormat.tokens(report.tokens), "词元", "输入 \(UsageFormat.tokens(report.input)) · 输出 \(UsageFormat.tokens(report.output))")
            }
            GridRow {
                tile(report.cost > 0 ? "≈" + UsageFormat.cost(report.cost) : "—", "花费",
                     report.unpricedModels.isEmpty ? "按实际价格" : "\(report.unpricedModels.count) 个模型没有价格，未计入")
                tile(UsageFormat.tokens(report.cacheRead), "缓存读取",
                     [report.cacheHitRate.map { "命中率 \(Int(($0 * 100).rounded()))%" },
                      report.cacheWrite > 0 ? "写入 \(UsageFormat.tokens(report.cacheWrite))" : nil].compactMap { $0 }.joined(separator: " · "))
            }
            GridRow {
                tile(report.activeSeconds.map(sessionDuration) ?? "—", "活跃",
                     report.activeSeconds == nil ? "不按模型记录" : "共 \(report.activeDays) 天")
                tile(String(report.folders.count), "项目",
                     lead.map { lead in report.folders.count > 1 && spent > 0
                         ? "\(Int((Double(lead.tokens) / Double(spent) * 100).rounded()))% 在 \(lead.name)" : lead.name } ?? "")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func tile(_ value: String, _ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            if !sub.isEmpty { Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 12))
    }

    private func dailyChart(_ report: SessionUsageReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("指标", selection: $metricRaw) {
                ForEach(SessionMetric.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("usage.sessions.metric")
            if metric == .active && report.activeSeconds == nil {
                Text("按模型筛选时没有活跃时长。").font(.footnote).foregroundStyle(.secondary)
            } else {
                let step = max(1, report.days.count / 5)
                Chart(report.days) { day in
                    BarMark(x: .value("日期", day.date), y: .value(metric.title, day.value(metric)))
                        .foregroundStyle(Color.accentColor.gradient)
                }
                .chartXAxis {
                    AxisMarks(values: report.days.enumerated().filter { $0.offset % step == 0 }.map(\.element.date)) { value in
                        AxisValueLabel { if let d = value.as(String.self) { Text(String(d.suffix(5))) } }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel { if let v = value.as(Double.self) { Text(format(v)) } }
                    }
                }
                .frame(height: 140)
            }
        }
    }

    private func format(_ v: Double) -> String {
        switch metric {
        case .tokens, .output: UsageFormat.tokens(Int(v))
        case .cost: UsageFormat.cost(v)
        case .active: sessionDuration(Int(v))
        case .messages, .sessions: UsageFormat.count(Int(v))
        }
    }

    @ViewBuilder
    private func barsSection(_ title: String, picks: [SessionPick], selected: String?, id: String, choose: @escaping (String?) -> Void) -> some View {
        if !picks.isEmpty {
            let most = picks.first?.tokens ?? 0
            Section(title) {
                ForEach(picks.prefix(8)) { pick in
                    Button {
                        choose(selected == pick.id ? nil : pick.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(pick.name).font(.subheadline).lineLimit(1)
                                if selected == pick.id { Image(systemName: "checkmark").font(.caption) }
                                Spacer()
                                Text(UsageFormat.tokens(pick.tokens)).font(.subheadline.monospacedDigit())
                            }
                            ProgressView(value: most > 0 ? Double(pick.tokens) / Double(most) : 0)
                            if pick.cost > 0 { Text("≈" + UsageFormat.cost(pick.cost)).font(.caption2).foregroundStyle(.secondary) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .accessibilityIdentifier(id)
        }
    }

    @ViewBuilder
    private func hoursSection(_ report: SessionUsageReport) -> some View {
        Section {
            if let hours = report.hours, hours.flatMap({ $0 }).contains(where: { $0 > 0 }) {
                let level = UsageHeatmap.levels(hours.flatMap { $0 }.map(Double.init))
                let names = ["一", "二", "三", "四", "五", "六", "日"]
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0..<7, id: \.self) { w in
                        HStack(spacing: 2) {
                            Text(names[w]).font(.caption2).foregroundStyle(.secondary).frame(width: 14)
                            ForEach(0..<24, id: \.self) { h in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(UsageHeatmapSection.shade(level(Double(hours[w][h]))))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 10)
                            }
                        }
                    }
                    HStack(spacing: 0) {
                        Text("").frame(width: 16)
                        ForEach([0, 6, 12, 18], id: \.self) { h in
                            Text("\(h)").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if let best = report.busiestHour {
                    Text("最忙：周\(names[best.weekday]) \(String(format: "%02d:00", best.hour))").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Text(report.hours == nil ? "活跃时长不按模型记录。" : "这段时间没有活跃时长。").font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("时段")
        } footer: {
            Text("按本机时区（\(TimeZone.current.identifier)）。活跃 = 一条消息到下一条之间、每段不超过五分钟的时间。")
        }
        .accessibilityIdentifier("usage.sessions.hours")
    }

    @ViewBuilder
    private func skillsSection(_ overview: SessionStatsOverview, agents: [String: String]) -> some View {
        Section {
            if overview.skills.isEmpty {
                Text("这段时间没有调用技能。").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(overview.skills) { skill in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(skill.name).font(.subheadline)
                        Spacer()
                        Text("\(skill.calls) 次").font(.subheadline.monospacedDigit())
                    }
                    let who = skill.agents.sorted { $0.value > $1.value }.map { "\(agents[$0.key] ?? $0.key) \($0.value)" }
                    Text((["\(skill.sessions) 个会话", skill.last.isEmpty ? nil : "最近 \(skill.last)"].compactMap { $0 } + who).joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        } header: {
            Text("技能")
        } footer: {
            if overview.skillCount > 0 { Text("共调用 \(overview.skillCalls) 次，用到 \(overview.skillCount) 个技能。") }
        }
    }

    @ViewBuilder
    private func toolsSection(_ overview: SessionStatsOverview) -> some View {
        Section {
            if overview.toolCalls == 0 {
                Text("这段时间没有工具调用。").font(.footnote).foregroundStyle(.secondary)
            } else {
                let most = overview.toolCategories.first?.calls ?? 1
                ForEach(overview.toolCategories) { c in
                    HStack {
                        Text(c.name == "Other" ? "其它" : c.name).font(.subheadline).frame(width: 90, alignment: .leading)
                        ProgressView(value: Double(c.calls) / Double(max(1, most)))
                        Text("\(c.calls)").font(.caption.monospacedDigit()).frame(width: 48, alignment: .trailing)
                    }
                }
                DisclosureGroup("调用最多的工具") {
                    ForEach(overview.tools) { tool in
                        LabeledContent(tool.name, value: "\(tool.calls) 次 · \(tool.sessions) 个会话")
                    }
                }
            }
        } header: {
            Text("工具")
        } footer: {
            if overview.toolCalls > 0 { Text("\(overview.toolSessions) 个会话共调用工具 \(overview.toolCalls) 次。") }
        }
    }

    @ViewBuilder
    private func listSection(_ sessions: [UsageSessionItem]) -> some View {
        Section {
            ForEach(Array(sessions.prefix(shown).enumerated()), id: \.element.id) { index, item in
                NavigationLink {
                    sessionDetail(item)
                } label: {
                    UsageSessionRow(item: item)
                }
                .accessibilityIdentifier("usage.sessions.item.\(index)")
            }
            if sessions.count > shown {
                Button("再显示 \(min(50, sessions.count - shown)) 个") { shown += 50 }
            }
            if let sessionsService = AgentSessionsServices.make(from: manage.service) {
                NavigationLink {
                    AgentSessionsView(service: sessionsService)
                } label: {
                    Label("全部会话记录", systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("usage.sessions.all")
            }
        } header: {
            Text("最近的会话")
        } footer: {
            let dirs = list?.dirs.joined(separator: " · ") ?? ""
            Text("合计算 Agent 自己的会话与带会话 id 的网关请求 · \(sessions.count) 个会话" + (dirs.isEmpty ? "" : " · \(dirs)"))
        }
    }

    @ViewBuilder
    private func sessionDetail(_ item: UsageSessionItem) -> some View {
        if let sessionsService = AgentSessionsServices.make(from: manage.service) {
            AgentSessionDetailView(store: AgentSessionsStore(service: sessionsService), session: item.session)
        } else {
            UsageSessionInfo(item: item)
        }
    }

    // MARK: 加载

    private func loadAll() async {
        guard let service else { return }
        let range = self.range
        do {
            async let s = service.sessionStats(range)
            async let l = service.sessions()
            let (newStats, newList) = try await (s, l)
            guard !Task.isCancelled, range == self.range else { return }
            stats = newStats
            list = newList
            error = nil
            shown = 50
        } catch {
            let mapped = MagpieError.from(error)
            if mapped != .cancelled { self.error = mapped }
        }
        await loadOverview()
    }

    private func loadOverview() async {
        guard let service else { return }
        let range = self.range, filter = self.filter
        do {
            let result = try await service.sessionOverview(range, filter: filter)
            guard !Task.isCancelled, range == self.range, filter.agent == self.filter.agent, filter.model == self.filter.model,
                  filter.folder == self.filter.folder else { return }
            overview = result
        } catch {
            // 读不到概要时，合计里的会话数等显示「—」，其它照常。
        }
    }
}

/// 列表里的一个会话。
private struct UsageSessionRow: View {
    let item: UsageSessionItem
    private var s: AgentSession { item.session }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(s.title.isEmpty ? "（没有提示）" : s.displayTitle).font(.subheadline.weight(.medium)).lineLimit(2)
                Text([s.cwd.isEmpty ? nil : s.folderName, item.agentName, s.primaryModel,
                      s.last.map { $0.formatted(.relative(presentation: .named)) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                let tokens = s.inputTokens + s.outputTokens
                Text(tokens > 0 ? UsageFormat.tokens(tokens) : "—").font(.subheadline.monospacedDigit())
                Text(s.cost > 0 ? "≈" + UsageFormat.cost(s.cost) : "—").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 读不了对话时的会话信息（时间、目录、id、继续的命令、文件）。
private struct UsageSessionInfo: View {
    let item: UsageSessionItem

    var body: some View {
        List {
            let s = item.session
            if let start = s.start, let last = s.last {
                LabeledContent("时间", value: "\(start.formatted(date: .abbreviated, time: .shortened)) – \(last.formatted(date: .omitted, time: .shortened))")
            }
            if !s.cwd.isEmpty { LabeledContent("文件夹", value: s.cwd) }
            LabeledContent("会话 ID") { Text(s.sessionID).textSelection(.enabled) }
            if !item.resume.isEmpty { LabeledContent("继续") { Text(item.resume).font(.caption.monospaced()).textSelection(.enabled) } }
            LabeledContent("词元", value: "输入 \(UsageFormat.tokens(s.inputTokens)) · 输出 \(UsageFormat.tokens(s.outputTokens))")
            if !s.path.isEmpty { LabeledContent("文件", value: s.path) }
        }
        .navigationTitle(item.session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 最费的会话：按词元 / 花费 / 活跃时长（magpie renderSessTop）。
private struct SessionTopSection: View {
    let overview: SessionStatsOverview
    let agents: [String: String]
    @AppStorage("usage.sessions.top") private var by = "tokens"

    var body: some View {
        Section {
            Picker("按", selection: $by) {
                Text("词元").tag("tokens")
                Text("花费").tag("cost")
                Text("活跃").tag("active")
            }
            .pickerStyle(.segmented)
            let list = overview.top[by] ?? []
            if list.isEmpty { Text("这段时间没有会话。").font(.footnote).foregroundStyle(.secondary) }
            ForEach(list) { s in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(s.title.isEmpty ? "（没有提示）" : s.title).font(.subheadline).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(value(s)).font(.subheadline.monospacedDigit())
                    }
                    Text([s.cwd.isEmpty ? (s.gateway ? "网关会话" : nil) : SessionUsageReport.baseName(s.cwd), agents[s.agent] ?? s.agent,
                          s.models.first, s.last.map { $0.formatted(.relative(presentation: .named)) }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Text("\(s.prompts) 次提问 · \(s.replies) 次回复 · \(s.toolCalls) 次工具调用")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("最费的会话")
        }
        .accessibilityIdentifier("usage.sessions.top")
    }

    private func value(_ s: SessionSummary) -> String {
        switch by {
        case "cost": s.cost > 0 ? "≈" + UsageFormat.cost(s.cost) : "—"
        case "active": sessionDuration(s.active)
        default: UsageFormat.tokens(s.inOut)
        }
    }
}

/// 会话形态：多少会话落在各个消息数 / 时长 / 每次提问的工具调用数区间（magpie renderSessShape）。
private struct SessionShapeSection: View {
    let overview: SessionStatsOverview
    @AppStorage("usage.sessions.shape") private var by = "messages"

    var body: some View {
        Section {
            Picker("按", selection: $by) {
                Text("消息").tag("messages")
                Text("时长").tag("minutes")
                Text("工具调用").tag("autonomy")
            }
            .pickerStyle(.segmented)
            if let shape = overview.shape[by], shape.total > 0 {
                let labels = shape.labels(unit: by == "minutes" ? " 分" : "")
                Chart(Array(zip(labels, shape.counts).enumerated()), id: \.offset) { item in
                    BarMark(x: .value("区间", item.element.0), y: .value("会话", item.element.1))
                        .foregroundStyle(Color.accentColor.gradient)
                }
                .frame(height: 120)
            } else {
                Text("这段时间没有会话。").font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("会话形态")
        } footer: {
            Text(by == "messages" ? "横轴：一个会话的消息数；高度：会话数。"
                 : by == "minutes" ? "横轴：一个会话活跃的分钟数；高度：会话数。" : "横轴：每次提问后 Agent 自己调用工具的次数；高度：会话数。")
        }
    }
}
