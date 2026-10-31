import SwiftUI
import Charts
import MagpieRemoteCore

/// 「用量」页：时间段切换、总花费 / 请求 / 词元、按模型 / Agent / 供应商 / 账号 / 密钥分组、当前并发，以及请求记录入口。
struct UsageView: View {
    @Environment(AppModel.self) private var model
    @State private var period: UsagePeriod = .today
    @State private var summary: UsageAccess<UsageSummary>?
    @State private var error: MagpieError?
    @State private var concurrency: UsageAccess<ConcurrencySnapshot>?
    @State private var dimension: UsageDimension = .model

    private struct LoadKey: Equatable {
        var connection: ConnectionState
        var period: UsagePeriod
    }

    var body: some View {
        ConnectedContent {
            List {
                Section {
                    UsagePeriodPicker(period: $period)
                        .accessibilityIdentifier("usage.period")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                if let error {
                    Section { ErrorStateView(error: error) { Task { await reload() } } }
                } else if let summary {
                    switch summary {
                    case .held:
                        Section { UsageHeldKeyNote() }
                        requestsLink(held: true)
                    case .available(let value):
                        UsageSummarySection(period: period, summary: value)
                        requestsLink(held: false)
                        if case .available(let snapshot) = concurrency {
                            ConcurrencySection(snapshot: snapshot)
                        }
                        UsageBreakdownSection(summary: value, dimension: $dimension)
                    }
                } else {
                    Section { ProgressView().frame(maxWidth: .infinity) }
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await reload(); await reloadConcurrency() }
            .navigationDestination(for: UsageRequestsRoute.self) { route in
                UsageRequestsView(period: $period, held: route.held)
            }
        }
        .task(id: LoadKey(connection: model.connection, period: period)) { await reload() }
        .task(id: model.connection) {
            // 并发是「此刻」的数据：页面在前台时每 5 秒刷新一次（接口很轻）。
            while !Task.isCancelled {
                await reloadConcurrency()
                if concurrency?.isHeld == true { break }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func requestsLink(held: Bool) -> some View {
        Section {
            NavigationLink(value: UsageRequestsRoute(held: held)) {
                Label(held ? "查看这把密钥的请求记录" : "请求记录", systemImage: "list.bullet.rectangle")
            }
            .accessibilityIdentifier("usage.requests.open")
        } footer: {
            Text("逐条查看每次请求的模型、耗时、词元与花费，可只看失败或重试过的。")
        }
    }

    private func reload() async {
        guard case .connected = model.connection else { summary = nil; error = nil; return }
        do {
            let result = try await model.loadUsageSummary(period)
            guard !Task.isCancelled else { return }
            summary = result
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            let mapped = MagpieError.from(error)
            if mapped != .cancelled { self.error = mapped }
        }
    }

    private func reloadConcurrency() async {
        guard case .connected = model.connection else { concurrency = nil; return }
        if let result = try? await model.loadConcurrency() { concurrency = result }
    }
}

struct UsageRequestsRoute: Hashable {
    var held: Bool
}

struct UsagePeriodPicker: View {
    @Binding var period: UsagePeriod

    var body: some View {
        Picker("时间段", selection: $period) {
            ForEach(UsagePeriod.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}

/// 受限密钥（有预算 / 模型 / 账号限制）的说明。
struct UsageHeldKeyNote: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("这是一把受限的网关密钥").font(.headline)
                Text("它设置了预算、模型或账号限制，主机不向它提供整体用量和并发情况，只能查看它自己发出的请求记录。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("usage.heldNote")
    }
}

// MARK: - 汇总

private struct UsageSummarySection: View {
    let period: UsagePeriod
    let summary: UsageSummary

    private var totals: UsageTotals { summary.totals }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("总花费").font(.subheadline).foregroundStyle(.secondary)
                Text(UsageFormat.cost(totals.cost))
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold).monospacedDigit())
                if totals.unpriced > 0 {
                    Text("另有 \(UsageFormat.count(totals.unpriced)) 次请求没有价格，未计入花费")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("usage.totalCost")

            HStack(spacing: 0) {
                stat("请求", UsageFormat.count(totals.calls))
                stat("失败", UsageFormat.count(totals.errors), tint: totals.errors > 0 ? .red : nil)
                stat("词元", UsageFormat.tokens(totals.tokens))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("usage.counts")

            if summary.series.contains(where: { $0.totals.calls > 0 }) {
                Chart(Array(summary.series.enumerated()), id: \.offset) { item in
                    BarMark(x: .value("时间", item.offset), y: .value("请求", item.element.totals.calls))
                        .foregroundStyle(Color.accentColor.gradient)
                }
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 90)
                .accessibilityLabel("每\(summary.bucket == "hour" ? "小时" : "天")请求数")
            }

            DisclosureGroup("词元明细") {
                LabeledContent("输入", value: UsageFormat.tokens(totals.input))
                LabeledContent("输出", value: UsageFormat.tokens(totals.output))
                if totals.cacheRead > 0 || totals.cacheWrite > 0 {
                    LabeledContent("缓存读取", value: UsageFormat.tokens(totals.cacheRead))
                    LabeledContent("缓存写入", value: UsageFormat.tokens(totals.cacheWrite))
                }
                if totals.reasoning > 0 { LabeledContent("推理（含在输出内）", value: UsageFormat.tokens(totals.reasoning)) }
                if let ttft = totals.meanTTFTms { LabeledContent("平均首字耗时", value: UsageFormat.duration(ms: ttft)) }
                if let speed = totals.tokensPerSecond { LabeledContent("平均输出速度", value: String(format: "%.0f 词元/秒", speed)) }
                if totals.retried > 0 { LabeledContent("重试后成功", value: "\(UsageFormat.count(totals.retried)) 次") }
            }
            .accessibilityIdentifier("usage.tokens")
        } header: {
            Text(period.heading)
        }
    }

    private func stat(_ title: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(tint ?? .primary)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 分组

private struct UsageBreakdownSection: View {
    let summary: UsageSummary
    @Binding var dimension: UsageDimension
    @State private var showAll = false

    var body: some View {
        let items = summary.breakdown(dimension)
        Section {
            Picker("分组", selection: $dimension) {
                ForEach(UsageDimension.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("usage.dimension")

            if items.isEmpty {
                Text(dimension == .account ? "这段时间没有走订阅账号的请求" : "这段时间没有请求")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(showAll ? items : Array(items.prefix(8))) { item in
                    BreakdownRow(item: item)
                }
                if items.count > 8 {
                    Button(showAll ? "收起" : "显示全部 \(items.count) 项") { showAll.toggle() }
                }
            }
        } header: {
            Text("分组")
        }
    }
}

private struct BreakdownRow: View {
    let item: UsageBreakdownItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.body).lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(UsageFormat.cost(item.totals.cost)).font(.body.monospacedDigit())
                    Text("\(UsageFormat.count(item.totals.calls)) 次 · \(UsageFormat.tokens(item.totals.tokens)) 词元")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: min(max(item.share, 0), 1))
                .tint(item.totals.errors > 0 && item.totals.errors == item.totals.calls ? .red : .accentColor)
            if item.totals.errors > 0 {
                Text("失败 \(UsageFormat.count(item.totals.errors)) 次").font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 并发

private struct ConcurrencySection: View {
    let snapshot: ConcurrencySnapshot

    var body: some View {
        Section {
            HStack(spacing: 0) {
                stat("进行中", snapshot.requests)
                stat("排队", snapshot.waiting, tint: snapshot.waiting > 0 ? .orange : nil)
                stat("等工具", snapshot.tools)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("usage.concurrency")

            ForEach(snapshot.lanes) { lane in
                LabeledContent {
                    Text(lane.waiting > 0 ? "\(lane.busy)/\(lane.limit) · 排队 \(lane.waiting)" : "\(lane.busy)/\(lane.limit)")
                        .monospacedDigit()
                        .foregroundStyle(lane.limit > 0 && lane.busy >= lane.limit ? .orange : .secondary)
                } label: {
                    Text(lane.keyId.map { "\(lane.provider) · 密钥 \($0.prefix(6))" } ?? lane.provider)
                }
            }
            ForEach(snapshot.active) { active in
                VStack(alignment: .leading, spacing: 2) {
                    Text(active.model ?? "等待分配模型").font(.subheadline)
                    Text("\(active.agent) · \(active.phaseTitle) · \(UsageFormat.duration(ms: active.ms))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("当前并发")
        } footer: {
            if snapshot.isIdle { Text("现在没有进行中的请求。") }
            else if snapshot.lanes.isEmpty { Text("没有设置并发上限。") }
        }
    }

    private func stat(_ title: String, _ value: Int, tint: Color? = nil) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(tint ?? .primary)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
