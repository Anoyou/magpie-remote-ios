import SwiftUI
import Charts
import MagpieRemoteCore

/// 「概览」的四格：词元（可切换含不含缓存）、缓存读取（命中率）、推理、请求（失败 / 重试后成功 / 没有价格），
/// 与 magpie 网页 renderUsage 的 tile 一致。
struct UsageOverviewTiles: View {
    let totals: UsageTotals
    @Binding var withCache: Bool

    private var tokens: Int { totals.inOut + (withCache ? totals.cacheRead + totals.cacheWrite : 0) }

    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                tile(UsageFormat.tokens(tokens), title: withCache ? "词元（含缓存）" : "词元",
                     sub: "输入 \(UsageFormat.tokens(totals.input)) · 输出 \(UsageFormat.tokens(totals.output))"
                        + (withCache && totals.cacheRead + totals.cacheWrite > 0 ? " · 缓存 \(UsageFormat.tokens(totals.cacheRead + totals.cacheWrite))" : "")) {
                    Menu {
                        Picker("词元合计", selection: $withCache) {
                            Text("不含缓存（输入与输出）").tag(false)
                            Text("含缓存（缓存读写也算）").tag(true)
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .accessibilityIdentifier("usage.tokens.cache")
                }
                tile(UsageFormat.tokens(totals.cacheRead), title: "缓存读取",
                     sub: [totals.cacheRead > 0 ? totals.cacheHitRate.map { "命中率 \(Int(($0 * 100).rounded()))%" } : nil,
                           totals.cacheWrite > 0 ? "写入 \(UsageFormat.tokens(totals.cacheWrite))" : nil].compactMap { $0 }.joined(separator: " · "))
            }
            GridRow {
                tile(UsageFormat.tokens(totals.reasoning), title: "推理", sub: "含在输出内")
                tile(UsageFormat.count(totals.calls), title: "请求",
                     sub: [totals.errors > 0 ? "失败 \(UsageFormat.count(totals.errors))" : nil,
                           totals.retried > 0 ? "重试后成功 \(UsageFormat.count(totals.retried))" : nil,
                           totals.unpriced > 0 ? "没有价格 \(UsageFormat.count(totals.unpriced))" : nil].compactMap { $0 }.joined(separator: " · "))
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usage.tiles")
    }

    private func tile(_ value: String, title: String, sub: String) -> some View {
        tile(value, title: title, sub: sub) { EmptyView() }
    }

    private func tile<Accessory: View>(_ value: String, title: String, sub: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                accessory()
            }
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            if !sub.isEmpty {
                Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 12))
    }

    /// 分组一行的细节：重试、死循环截断、首字耗时、输出速度、缓存命中（magpie 概览列表的 sub 行）。
    static func details(_ t: UsageTotals) -> String? {
        var parts: [String] = []
        if t.loops > 0 { parts.append("截断死循环 \(t.loops)") }
        if t.retried > 0 { parts.append("重试后成功 \(t.retried)") }
        if let ttft = t.meanTTFTms { parts.append("首字 \(UsageFormat.duration(ms: ttft))") }
        if let speed = UsageSpeed(t) { parts.append(speed.text) }
        if t.cacheRead > 0, let rate = t.cacheHitRate { parts.append("缓存 \(UsageFormat.tokens(t.cacheRead)) · 命中 \(Int((rate * 100).rounded()))%") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 「概览」的时间图：每小时 / 天 / 周一根柱，输出叠在输入上（magpie 概览的 chart）。
struct UsageTokenChart: View {
    let summary: UsageSummary
    let withCache: Bool

    private struct Bar: Identifiable {
        var id: String { "\(index)-\(part)" }
        var index: Int
        var label: String
        var part: String
        var value: Int
    }

    private var bars: [Bar] {
        summary.series.enumerated().flatMap { i, p -> [Bar] in
            let input = p.totals.input + (withCache ? p.totals.cacheRead + p.totals.cacheWrite : 0)
            let label = label(p)
            return [Bar(index: i, label: label, part: "输入", value: input), Bar(index: i, label: label, part: "输出", value: p.totals.output)]
        }
    }

    private func label(_ p: UsagePoint) -> String {
        if summary.bucket == "hour" { return p.label + ":00" }
        guard let date = p.time?.date else { return p.label }
        return date.formatted(.dateTime.month(.defaultDigits).day())
    }

    var body: some View {
        let stride = max(1, summary.series.count / 5)
        Chart(bars) { bar in
            BarMark(x: .value("时间", bar.index), y: .value("词元", bar.value))
                .foregroundStyle(by: .value("类别", bar.part))
        }
        .chartForegroundStyleScale(["输入": Color.accentColor.opacity(0.45), "输出": Color.accentColor])
        .chartXAxis {
            AxisMarks(values: Array(Swift.stride(from: 0, to: summary.series.count, by: stride))) { value in
                AxisValueLabel {
                    if let i = value.as(Int.self), summary.series.indices.contains(i) { Text(label(summary.series[i])) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Int.self) { Text(UsageFormat.tokens(v)) } }
            }
        }
        .chartLegend(position: .top, alignment: .trailing)
        .frame(height: 140)
        .accessibilityLabel("每\(summary.bucket == "hour" ? "小时" : summary.bucket == "week" ? "周" : "天")的输入与输出词元")
        .accessibilityIdentifier("usage.chart")
    }
}
