import SwiftUI
import Charts
import MagpieRemoteCore

/// 请求记录的仪表盘：五个合计（词元、请求、花费、缓存命中率、输出速度），再是按指标、按维度拆开的趋势图与排名
/// （magpie 网页 renderLedgerDash / drawLedTrend / drawLedRank）。点排名里的一项只看它的请求。
struct UsageLedgerDashboard: View {
    let page: UsageRequestPage
    @Binding var failedOnly: Bool
    @Binding var retriedOnly: Bool
    let pick: (UsageTrendSplit, UsageShare) -> Void

    @AppStorage("usage.requests.metric") private var metricRaw = UsageTrendMetric.tokens.rawValue
    @AppStorage("usage.requests.line") private var lineChart = false
    @State private var split: UsageTrendSplit = .model
    @State private var showAllRanks = false

    private var metric: UsageTrendMetric { UsageTrendMetric(rawValue: metricRaw) ?? .tokens }
    private var totals: UsageTotals { page.totals }
    private var splits: [UsageTrendSplit] { UsageTrendSplit.allCases.filter { $0 != .callerKey || !page.callerKeys.isEmpty } }

    var body: some View {
        Section {
            kpis
        } header: {
            Text("合计")
        }
        .accessibilityIdentifier("usage.requests.dash")

        Section {
            Picker("指标", selection: $metricRaw) {
                ForEach(UsageTrendMetric.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("usage.requests.metric")

            HStack {
                Menu {
                    Picker("拆开", selection: $split) {
                        ForEach(splits) { Text($0.title).tag($0) }
                    }
                } label: {
                    Label("按\(split.title)", systemImage: "square.stack.3d.up")
                        .font(.subheadline)
                }
                .accessibilityIdentifier("usage.requests.split")
                Spacer()
                Picker("样式", selection: $lineChart) {
                    Image(systemName: "chart.bar.fill").accessibilityLabel("柱状图").tag(false)
                    Image(systemName: "chart.xyaxis.line").accessibilityLabel("折线图").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 96)
            }

            let trend = UsageTrend(page: page, metric: metric, split: split)
            if trend.isEmpty {
                Text("这段时间没有可以画的数据").font(.footnote).foregroundStyle(.secondary)
            } else {
                UsageTrendChart(trend: trend, metric: metric, line: lineChart, bucket: page.bucket)
            }

            let ranked = page.ranking(split, metric: metric)
            ForEach(Array((showAllRanks ? ranked : Array(ranked.prefix(UsageTrend.shown))).enumerated()), id: \.element.id) { index, share in
                Button { pick(split, share) } label: {
                    RankRow(share: share, metric: metric, color: UsageTrendChart.color(index), maxValue: ranked.first.map { metric.rankValue($0.totals) } ?? 0)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("usage.requests.rank.\(index)")
            }
            if ranked.count > UsageTrend.shown {
                Button(showAllRanks ? "收起" : "显示全部 \(ranked.count) 项") { showAllRanks.toggle() }
            }
        } header: {
            Text("趋势")
        } footer: {
            Text("点排名里的一项，只看它的请求；再点一次恢复。")
        }
        .accessibilityIdentifier("usage.requests.trend")
    }

    private var kpis: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                kpi("词元", UsageFormat.tokens(totals.tokens),
                    "输入 \(UsageFormat.tokens(totals.input)) · 输出 \(UsageFormat.tokens(totals.output)) · 缓存 \(UsageFormat.tokens(totals.cacheRead + totals.cacheWrite))")
                VStack(alignment: .leading, spacing: 4) {
                    Text("请求").font(.caption).foregroundStyle(.secondary)
                    Text(UsageFormat.count(totals.calls)).font(.title3.weight(.semibold).monospacedDigit())
                    if totals.errors > 0 {
                        Button("失败 \(UsageFormat.count(totals.errors)) · 成功率 \(String(format: "%.1f", (page.successRate ?? 0) * 100))%") {
                            failedOnly.toggle(); if failedOnly { retriedOnly = false }
                        }
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .buttonStyle(.borderless)
                    } else {
                        Text("没有失败").font(.caption2).foregroundStyle(.secondary)
                    }
                    if totals.retried > 0 {
                        Button("重试后成功 \(UsageFormat.count(totals.retried))") {
                            retriedOnly.toggle(); if retriedOnly { failedOnly = false }
                        }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 12))
            }
            GridRow {
                kpi("花费", totals.cost > 0 ? "≈" + UsageFormat.cost(totals.cost) : "—",
                    totals.unpriced > 0 ? "\(UsageFormat.count(totals.unpriced)) 次没有已知价格，未计入" : "按实际价格")
                VStack(alignment: .leading, spacing: 4) {
                    Text("缓存命中率").font(.caption).foregroundStyle(.secondary)
                    Text(totals.cacheHitRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
                        .font(.title3.weight(.semibold).monospacedDigit())
                    ProgressView(value: min(1, max(0, totals.cacheHitRate ?? 0)))
                    if totals.cacheUnknownCalls > 0 {
                        Text("\(UsageFormat.count(totals.cacheUnknownCalls)) 次请求不计：供应商不报告缓存").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 12))
            }
            GridRow {
                let speed = UsageSpeed(totals)
                kpi("输出速度", speed?.text ?? "—",
                    [speed?.otherText, totals.meanTTFTms.map { "平均首字 \(UsageFormat.duration(ms: $0)) · \(UsageFormat.count(totals.timed)) 次计时" } ?? "没有计时的流式回复"]
                        .compactMap { $0 }.joined(separator: "\n"))
                    .gridCellColumns(2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func kpi(_ title: String, _ value: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 12))
    }
}

private struct RankRow: View {
    let share: UsageShare
    let metric: UsageTrendMetric
    let color: Color
    let maxValue: Double

    private var value: Double { metric.rankValue(share.totals) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(share.displayName).font(.subheadline).lineLimit(1)
                Spacer(minLength: 6)
                Text(UsageTrendChart.format(metric, value)).font(.subheadline.monospacedDigit())
            }
            ProgressView(value: maxValue > 0 ? min(1, value / maxValue) : 0).tint(color)
            Text(subtitle).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = ["\(UsageFormat.count(share.totals.calls)) 次", "\(UsageFormat.tokens(share.totals.tokens)) 词元"]
        if share.totals.cost > 0 { parts.append(UsageFormat.cost(share.totals.cost)) }
        if share.totals.errors > 0 { parts.append("失败 \(share.totals.errors)") }
        if let speed = UsageSpeed(share.totals), metric != .speed { parts.append(speed.text) }
        return parts.joined(separator: " · ")
    }
}

/// 趋势图：柱状（各层叠起来）或折线（各层一条线）。
struct UsageTrendChart: View {
    let trend: UsageTrend
    let metric: UsageTrendMetric
    let line: Bool
    let bucket: String

    private struct Point: Identifiable {
        var id: String { "\(layer)-\(index)" }
        var index: Int
        var layer: String
        var value: Double
    }

    static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .yellow]
    static func color(_ index: Int) -> Color { index < palette.count ? palette[index] : .gray }

    static func format(_ metric: UsageTrendMetric, _ value: Double) -> String {
        switch metric {
        case .tokens: UsageFormat.tokens(Int(value.rounded()))
        case .cost: UsageFormat.cost(value)
        case .calls: UsageFormat.count(Int(value.rounded()))
        case .speed: value > 0 ? "\(Int(value.rounded())) 词元/秒" : "—"
        }
    }

    private var points: [Point] {
        trend.layers.flatMap { layer in
            layer.values.enumerated().map { Point(index: $0.offset, layer: layer.name, value: $0.element) }
        }
    }

    private var domain: [String] { trend.layers.map(\.name) }
    private var range: [Color] { trend.layers.enumerated().map { $0.element.isOther ? .gray : Self.color($0.offset) } }

    private func label(_ i: Int) -> String {
        guard trend.labels.indices.contains(i) else { return "" }
        if bucket == "hour" { return trend.labels[i] + ":00" }
        if let date = trend.times[i] { return date.formatted(.dateTime.month(.defaultDigits).day()) }
        return trend.labels[i]
    }

    var body: some View {
        let step = max(1, trend.labels.count / 5)
        Chart(points) { p in
            if line {
                LineMark(x: .value("时间", p.index), y: .value(metric.title, p.value))
                    .foregroundStyle(by: .value("项", p.layer))
                    .interpolationMethod(.monotone)
            } else {
                BarMark(x: .value("时间", p.index), y: .value(metric.title, p.value))
                    .foregroundStyle(by: .value("项", p.layer))
            }
        }
        .chartForegroundStyleScale(domain: domain, range: range)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: Array(stride(from: 0, to: trend.labels.count, by: step))) { value in
                AxisValueLabel { if let i = value.as(Int.self) { Text(label(i)) } }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Double.self) { Text(Self.format(metric, v)) } }
            }
        }
        .frame(height: 160)
        .accessibilityLabel("请求记录的\(metric.title)趋势")
    }
}

/// 最近 53 周的热力图（每天一格，周一在上），可按词元 / 请求 / 花费看；点一格看那天的数字（magpie drawLedHeat）。
struct UsageHeatmapSection: View {
    let heatmap: UsageHeatmap
    @AppStorage("usage.requests.heatMetric") private var metric = "tokens"
    @State private var picked: UsageHeatmap.Day?

    private func value(_ day: UsageHeatmap.Day) -> Double {
        switch metric {
        case "calls": Double(day.calls)
        case "cost": day.cost
        default: Double(day.tokens)
        }
    }

    var body: some View {
        let weeks = heatmap.weeks()
        let level = UsageHeatmap.levels(heatmap.days.map(value))
        Section {
            Picker("热力图指标", selection: $metric) {
                Text("词元").tag("tokens")
                Text("请求").tag("calls")
                Text("花费").tag("cost")
            }
            .pickerStyle(.segmented)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 3) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        VStack(spacing: 3) {
                            ForEach(0..<7, id: \.self) { i in
                                cell(week[i], level: level)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .defaultScrollAnchor(.trailing)

            HStack(spacing: 4) {
                if let picked {
                    Text(caption(picked)).font(.caption).monospacedDigit()
                } else {
                    Text("点一格看那天").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("少").font(.caption2).foregroundStyle(.secondary)
                ForEach(0...4, id: \.self) { l in
                    RoundedRectangle(cornerRadius: 2).fill(Self.shade(l)).frame(width: 10, height: 10)
                }
                Text("多").font(.caption2).foregroundStyle(.secondary)
            }
        } header: {
            Text("最近一年")
        } footer: {
            Text("每天一格，周一在上；是上面筛选留下的请求，不管选的时间段。")
        }
        .accessibilityIdentifier("usage.heatmap")
    }

    @ViewBuilder
    private func cell(_ day: UsageHeatmap.Day?, level: (Double) -> Int) -> some View {
        if let day {
            RoundedRectangle(cornerRadius: 2)
                .fill(Self.shade(level(value(day))))
                .frame(width: 11, height: 11)
                .overlay {
                    if picked?.date == day.date { RoundedRectangle(cornerRadius: 2).stroke(Color.primary, lineWidth: 1) }
                }
                .onTapGesture { picked = picked?.date == day.date ? nil : day }
                .accessibilityLabel(caption(day))
        } else {
            Color.clear.frame(width: 11, height: 11)
        }
    }

    static func shade(_ level: Int) -> Color {
        level <= 0 ? Color.secondary.opacity(0.12) : Color.green.opacity(0.25 + 0.75 * Double(level) / 4)
    }

    private func caption(_ day: UsageHeatmap.Day) -> String {
        guard day.calls > 0 else { return "\(day.date) · 没有请求" }
        var parts = [day.date, "\(UsageFormat.tokens(day.tokens)) 词元", "\(UsageFormat.count(day.calls)) 次"]
        if day.cost > 0 { parts.append("≈" + UsageFormat.cost(day.cost)) }
        return parts.joined(separator: " · ")
    }
}
