import SwiftUI
import Charts
import MagpieRemoteCore

/// 「用量 › 上下文」：magpie 网页 Usage 页的 Context 标签（assets/context.js）的原生版——
/// 「为你调优」（按你的真实调用重放出的最省词元的设置），「经过 magpie」各 Agent 的上下文评分卡
/// （评分、标签、典型提示、起步、增长、缓存命中、窗口、提示里装了什么），以及各会话的上下文用量与最近一次请求的内容。
struct UsageContextPane: View {
    let service: (any UsageWebServing)?
    let tune: (any HostToolsServing)?

    @AppStorage("usage.context.days") private var days = 7
    @State private var report: ContextReport?
    @State private var tuneState: TuneState?
    @State private var error: MagpieError?
    @State private var agentFilter: String?
    @State private var open: String?

    var body: some View {
        List {
            Section {
                Picker("范围", selection: $days) {
                    ForEach(ContextReport.dayOptions, id: \.self) { Text(ContextReport.dayTitle($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("usage.context.range")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

            tuneSection

            if service == nil {
                Section { ContentUnavailableView("上下文", systemImage: "square.stack.3d.up", description: Text("这台主机暂时不能读取上下文。")) }
            } else if let error, report == nil {
                Section { ErrorStateView(error: error) { Task { await load() } } }
            } else if let report {
                agentsSection(report)
                sessionsSection(report)
            } else {
                Section {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("正在读路由历史…").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
        .task(id: days) { await load() }
    }

    // MARK: 为你调优

    @ViewBuilder private var tuneSection: some View {
        if let tune {
            Section {
                if let tuneState {
                    let shown = tuneState.agents.filter { !$0.advice.isEmpty }
                    if shown.isEmpty {
                        Text("这段时间的调用不够多，还调不出来。").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(shown) { agent in
                            LabeledContent(TuneState.agentName(agent.agent), value: "\(agent.advice.count) 条建议 · \(agent.calls) 次调用")
                        }
                    }
                } else {
                    Text("正在从你的会话里算…").font(.footnote).foregroundStyle(.secondary)
                }
                NavigationLink {
                    HostTuneView(service: tune)
                } label: {
                    Label("查看并应用建议", systemImage: "dial.medium")
                }
                .accessibilityIdentifier("usage.context.tune")
            } header: {
                Text("为你调优")
            } footer: {
                Text("用这段时间你自己的调用，从 Agent 的会话文件里一项一项重放：怎么设置最省词元。按供应商收费的方式算，缓存读取按十分之一算。")
            }
        }
    }

    // MARK: 经过 magpie

    @ViewBuilder
    private func agentsSection(_ report: ContextReport) -> some View {
        Section {
            if report.agents.isEmpty {
                ContentUnavailableView("还没有读到提示", systemImage: "text.magnifyingglass",
                                       description: Text("Agent 经过 magpie 发的请求会出现在这里。"))
            }
            ForEach(report.agents) { agent in
                ContextAgentCard(agent: agent)
                    .accessibilityIdentifier("usage.context.agent.\(agent.agent)")
            }
        } header: {
            Text("经过 magpie")
        } footer: {
            Text("各 Agent 的提示里装了什么，按 magpie 网关读到的算；评分和标签取自这段时间的请求。")
        }
    }

    @ViewBuilder
    private func sessionsSection(_ report: ContextReport) -> some View {
        let agents = report.sessionAgents
        let shown = report.sessions.filter { agentFilter == nil || $0.agent == agentFilter }
        Section {
            if agents.count > 1 {
                Picker("Agent", selection: $agentFilter) {
                    Text("全部").tag(String?.none)
                    ForEach(agents, id: \.self) { Text(ContextAgentCard.name($0)).tag(String?.some($0)) }
                }
                .pickerStyle(.segmented)
            }
            if shown.isEmpty { Text("这段时间没有会话。").font(.footnote).foregroundStyle(.secondary) }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, session in
                ContextSessionRow(session: session, open: open == session.id) {
                    open = open == session.id ? nil : session.id
                }
                .accessibilityIdentifier("usage.context.session.\(index)")
            }
        } header: {
            Text("会话")
        } footer: {
            Text("每个会话最大的一次提示占窗口多少；点开看最近一次请求装了什么。")
        }
    }

    // MARK: 加载

    private func load() async {
        let days = self.days
        if let tune {
            Task { if let state = try? await tune.tune(days: days), days == self.days { tuneState = state } }
        }
        guard let service else { return }
        do {
            let result = try await service.context(days: days)
            guard !Task.isCancelled, days == self.days else { return }
            report = result
            error = nil
            if let agentFilter, !result.sessionAgents.contains(agentFilter) { self.agentFilter = nil }
        } catch {
            let mapped = MagpieError.from(error)
            if mapped != .cancelled { self.error = mapped }
        }
    }
}

/// 一个 Agent 的上下文卡片（context.js agentCard）。
private struct ContextAgentCard: View {
    let agent: ContextAgent

    static func name(_ id: String) -> String {
        switch id {
        case "scripts": "脚本"
        case "claude": "Claude Code"
        case "claude-desktop": "Claude Desktop"
        case "codex": "Codex"
        default: id.isEmpty ? "你的 Agent" : id
        }
    }

    private var gradeColor: Color {
        switch agent.grade {
        case .great: .green
        case .good: .teal
        case .fair: .orange
        case .poor: .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.name(agent.agent)).font(.headline)
                    Text(([agent.clients.isEmpty ? nil : agent.clients.prefix(3).joined(separator: ", ") + (agent.clients.count > 3 ? " +\(agent.clients.count - 3)" : ""),
                           "\(agent.requests) 次请求", "\(agent.sessions) 个会话"] as [String?]).compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(spacing: 2) {
                    Gauge(value: Double(agent.score), in: 0...100) {
                        EmptyView()
                    } currentValueLabel: {
                        Text("\(agent.score)").font(.caption.weight(.bold))
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(gradeColor)
                    .scaleEffect(0.8)
                    Text(agent.grade.title).font(.caption2.weight(.semibold)).foregroundStyle(gradeColor)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("评分 \(agent.score)，\(agent.grade.title)")
            }

            ForEach(agent.scores) { score in
                HStack(spacing: 8) {
                    Text(score.title).font(.caption).frame(width: 52, alignment: .leading)
                    ProgressView(value: min(1, max(0, score.ratio)))
                        .tint(score.ratio >= 0.8 ? .green : score.ratio >= 0.5 ? .orange : .red)
                    Text("\(Int(score.points))/\(Int(score.most))").font(.caption2.monospacedDigit()).frame(width: 40, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityHint(score.note)
            }

            if !agent.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(agent.tags) { tag in
                            Text(tag.title)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(tone(tag.tone).opacity(0.15), in: .capsule)
                                .foregroundStyle(tone(tag.tone))
                                .accessibilityHint(tag.detail)
                        }
                    }
                }
                ForEach(agent.tags) { tag in
                    Text("· " + tag.detail).font(.caption2).foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    fact("典型提示", ContextFormat.tokens(agent.median))
                    fact("最大", ContextFormat.tokens(agent.p90))
                    fact("起步", ContextFormat.tokens(agent.baseline))
                }
                GridRow {
                    fact("每次增长", agent.growth > 0 ? "+" + ContextFormat.tokens(agent.growth) : "—")
                    fact("缓存命中", agent.showsCache ? ContextFormat.percent(agent.cache) : "—")
                    fact("窗口", agent.window > 0 ? ContextFormat.tokens(agent.window) : "—")
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("提示里装了什么").font(.caption).foregroundStyle(.secondary)
                ContextShareBar(shares: agent.visibleShares.map { ($0.kind, $0.share) })
                FlowLegend(items: agent.visibleShares.map { ($0.kind, "\($0.kind.title) \(ContextFormat.percent($0.share))") })
            }

            if !agent.models.isEmpty {
                Text(agent.models.map { $0.split(separator: "/").last.map(String.init) ?? $0 }.joined(separator: " · "))
                    .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private func tone(_ tone: String) -> Color {
        switch tone {
        case "good": .green
        case "warn": .orange
        default: .blue
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
        }
    }
}

/// 各类内容的颜色（context.css 的 k-* 色）。
enum ContextPalette {
    static func color(_ kind: ContextPartKind?) -> Color {
        switch kind {
        case .system: .indigo
        case .tools: .orange
        case .skills: .pink
        case .memory: .purple
        case .files: .teal
        case .results: .yellow
        case .chat: .blue
        case nil: .gray
        }
    }
}

/// 横向的比例条。
private struct ContextShareBar: View {
    let shares: [(ContextPartKind, Double)]

    var body: some View {
        GeometryReader { geo in
            let total = max(0.0001, shares.reduce(0) { $0 + $1.1 })
            HStack(spacing: 1) {
                ForEach(Array(shares.enumerated()), id: \.offset) { _, item in
                    Rectangle().fill(ContextPalette.color(item.0))
                        .frame(width: max(2, geo.size.width * item.1 / total - 1))
                }
            }
        }
        .frame(height: 10)
        .clipShape(.capsule)
        .accessibilityHidden(true)
    }
}

/// 图例（小圆点 + 名字），放不下就换行。
private struct FlowLegend: View {
    let items: [(ContextPartKind, String)]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { content }
            VStack(alignment: .leading, spacing: 2) { content }
        }
    }

    @ViewBuilder private var content: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            HStack(spacing: 4) {
                Circle().fill(ContextPalette.color(item.0)).frame(width: 7, height: 7)
                Text(item.1).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// 一个会话：标题、模型、最大提示占窗口、每次请求的提示大小折线、请求与压缩次数、时间；点开是最近一次请求的上下文卡片。
private struct ContextSessionRow: View {
    let session: ContextSession
    let open: Bool
    let toggle: () -> Void

    private var health: ContextHealth { ContextHealth(fill: session.peakFill ?? 0) }
    private var healthColor: Color {
        switch health {
        case .ok: .green
        case .warn: .orange
        case .bad: .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.displayTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(session.model.split(separator: "/").last.map(String.init) ?? session.model)
                            .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        Text(([ContextAgentCard.name(session.agent), "\(session.requests) 次请求",
                               session.compacts > 0 ? "压缩 \(session.compacts) 次" : nil,
                               session.last.map { $0.formatted(.relative(presentation: .named)) }] as [String?])
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if session.points.count > 1 {
                        Chart(Array(session.points.enumerated()), id: \.offset) { item in
                            LineMark(x: .value("请求", item.offset), y: .value("词元", item.element.tokens))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(healthColor)
                        }
                        .chartXAxis(.hidden)
                        .chartYAxis(.hidden)
                        .chartYScale(domain: 0...max(1, session.window > 0 ? session.window : session.peak))
                        .frame(width: 70, height: 28)
                        .accessibilityHidden(true)
                    }
                    Text(session.peakFill.map(ContextFormat.percent) ?? ContextFormat.tokens(session.peak))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(healthColor)
                        .frame(minWidth: 40, alignment: .trailing)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(session.displayTitle)，最大提示 \(ContextFormat.tokens(session.peak))"
                                + (session.window > 0 ? "，窗口 \(ContextFormat.tokens(session.window))" : ""))

            if open {
                if let prompt = session.latest {
                    ContextPromptCard(prompt: prompt, cacheShare: session.latestCacheShare)
                } else {
                    Text("最近一次请求的内容已经不在 magpie 的内存里了。").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// 一次请求的上下文卡片（context.js ctxCard）：窗口用了多少、缓存读了多少、按内容的比例条，以及各类里占得最多的几项。
private struct ContextPromptCard: View {
    let prompt: ContextPrompt
    let cacheShare: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let fill = prompt.fill {
                HStack {
                    Text("窗口").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(ContextFormat.tokens(prompt.tokens)) / \(ContextFormat.tokens(prompt.window)) · \(ContextFormat.percent(fill)) · \(ContextHealth(fill: fill).title)")
                        .font(.caption.monospacedDigit())
                }
                ProgressView(value: fill)
                    .tint(ContextHealth(fill: fill) == .ok ? .green : ContextHealth(fill: fill) == .warn ? .orange : .red)
            } else {
                LabeledContent("提示", value: ContextFormat.tokens(prompt.tokens)).font(.caption)
            }
            if let cacheShare {
                Text("其中 \(ContextFormat.percent(cacheShare)) 从供应商缓存读取").font(.caption2).foregroundStyle(.secondary)
            }
            if !prompt.counted {
                Text("按请求正文估算（还没有供应商数的词元）").font(.caption2).foregroundStyle(.secondary)
            }
            if prompt.held {
                Text("请求引用了之前的回复，那几轮在供应商那里").font(.caption2).foregroundStyle(.secondary)
            }
            ContextShareBar(shares: prompt.parts.compactMap { part in part.known.map { ($0, Double(part.tokens)) } })
            ForEach(prompt.parts) { part in
                DisclosureGroup {
                    ForEach(part.items) { item in
                        HStack(spacing: 6) {
                            Text(item.title).font(.caption).lineLimit(1).truncationMode(.middle)
                            if let tag = item.tagTitle {
                                Text(tag).font(.caption2).padding(.horizontal, 5).background(Color.secondary.opacity(0.15), in: .capsule)
                            }
                            if item.n > 0 && item.tag != "turns" && item.tag != "more" {
                                Text("×\(item.n)").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(ContextFormat.tokens(item.tokens)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(ContextPalette.color(part.known)).frame(width: 8, height: 8)
                        Text(part.title).font(.subheadline)
                        Spacer()
                        Text(ContextFormat.tokens(part.tokens)).font(.subheadline.monospacedDigit())
                        if prompt.tokens > 0 {
                            Text(ContextFormat.percent(Double(part.tokens) / Double(prompt.tokens)))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
                        }
                    }
                }
                .accessibilityHint(part.known?.note ?? "")
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usage.context.card")
    }
}
