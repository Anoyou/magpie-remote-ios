import SwiftUI
import Charts
import MagpieRemoteCore

/// 「额度」页：各订阅 / 套餐 / 余额账号的剩余额度、重置时间与历史曲线；密钥受限时显示它自己的限额。
struct QuotaView: View {
    @Environment(AppModel.self) private var model
    @State private var snapshot: QuotaSnapshot?
    @State private var error: MagpieError?
    @State private var notice: String?
    @State private var throttle = QuotaRefreshThrottle()
    @State private var range: QuotaHistoryRange = .week
    @State private var history: [QuotaHistorySeries]?
    @State private var historyFailed = false
    @State private var refreshingCard: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HostStatusCard()
                ConnectedContent {
                    content
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .refreshable { await refreshAll() }
        .task(id: model.connection) { await reload() }
        .task(id: notice) {
            guard notice != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { notice = nil }
        }
    }

    @ViewBuilder private var content: some View {
        if let error {
            ErrorStateView(error: error) { Task { await reload() } }
        } else if let snapshot {
            VStack(spacing: 16) {
                if let notice { NoticeBanner(text: notice) }
                switch snapshot {
                case .keyHeld(let limit):
                    KeyLimitCard(limit: limit)
                case .cards(let cards) where cards.isEmpty:
                    QuotaEmptyView()
                case .cards(let cards):
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        QuotaGroupsView(cards: cards, now: context.date, refreshingCard: refreshingCard) { card in
                            Task { await refresh(card) }
                        }
                    }
                    QuotaHistorySection(range: $range, history: history, failed: historyFailed, cards: cards)
                        .task(id: range) { await loadHistory() }
                }
            }
        } else {
            ProgressView("正在读取额度…").padding(.top, 40)
        }
    }

    private var currentCards: [QuotaCard] {
        if case .cards(let cards) = snapshot { return cards }
        return []
    }

    private func reload() async {
        guard case .connected = model.connection else {
            snapshot = nil; error = nil; history = nil
            return
        }
        do {
            snapshot = try await model.loadQuotaSnapshot()
            error = nil
        } catch {
            self.error = MagpieError.from(error)
        }
    }

    private func loadHistory() async {
        guard case .cards(let cards)? = snapshot, !cards.isEmpty else { return }
        do {
            history = try await model.loadQuotaHistory(days: range.days)
            historyFailed = false
        } catch is CancellationError {
        } catch {
            historyFailed = true
        }
    }

    /// 下拉刷新：让主机重新读取所有卡片。30 秒内刚刷新过时不再请求；主机返回缓存时（readAt 没变）给出提示。
    private func refreshAll() async {
        guard case .connected = model.connection else { return }
        guard case .cards(let before)? = snapshot, error == nil else { return await reload() }
        if before.isEmpty { return await reload() }
        if throttle.wait() != nil {
            notice = "30 秒内刚刷新过，显示的是刚才读到的数值。"
            return
        }
        throttle.record()
        do {
            let fresh = try await model.refreshQuotas()
            snapshot = .cards(QuotaMerge.merge(cards: fresh, readings: before))
            notice = QuotaRefreshOutcome.compare(before: before, after: fresh) == .cached
                ? "30 秒内刚刷新过，主机返回的是刚才读到的数值。" : nil
            await loadHistory()
        } catch let access as QuotaAccessError {
            notice = access.message
            if access == .keyHeld { await reload() }
        } catch is CancellationError {
        } catch {
            notice = "刷新失败：\(MagpieError.from(error).title)，显示的是上次读到的数值。"
        }
    }

    /// 单个账号重新读取（卡片的长按菜单）。
    private func refresh(_ card: QuotaCard) async {
        if throttle.wait(for: card.id) != nil {
            notice = "30 秒内刚刷新过这个账号，显示的是刚才读到的数值。"
            return
        }
        throttle.record(card.id)
        refreshingCard = card.id
        defer { refreshingCard = nil }
        do {
            let fresh = try await model.refreshQuotas(provider: card.provider, user: card.user)
            let updated = fresh.filter { $0.id == card.id }
            snapshot = .cards(QuotaMerge.replacing(currentCards, with: updated))
            notice = QuotaRefreshOutcome.compare(before: [card], after: updated) == .cached
                ? "30 秒内刚刷新过这个账号，主机返回的是刚才读到的数值。" : nil
        } catch let access as QuotaAccessError {
            notice = access.message
        } catch {
            notice = "刷新失败：\(MagpieError.from(error).title)"
        }
    }
}

// MARK: 卡片

private struct QuotaGroupsView: View {
    let cards: [QuotaCard]
    let now: Date
    let refreshingCard: String?
    let refresh: (QuotaCard) -> Void

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(QuotaGroup.group(cards)) { group in
                    if group.cards.count > 1 {
                        Text("\(group.title) · \(group.cards.count) 个账号")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                    ForEach(group.cards) { card in
                        QuotaCardView(card: card, now: now, showsProvider: group.cards.count == 1, refreshing: refreshingCard == card.id)
                            .contextMenu {
                                if card.canRefresh {
                                    Button("重新读取这个账号", systemImage: "arrow.clockwise") { refresh(card) }
                                }
                            }
                    }
                }
            }
        }
    }
}

private struct QuotaCardView: View {
    let card: QuotaCard
    let now: Date
    let showsProvider: Bool
    let refreshing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(showsProvider && card.accountLabel != card.name ? "\(card.name) · \(card.accountLabel)" : card.accountLabel)
                        .font(.headline)
                    if let detail = card.accountDetail {
                        Text(detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if refreshing {
                    ProgressView()
                } else if let lowest = card.lowestRemaining {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(QuotaFormat.percent(lowest)).font(.title2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(quotaTint(lowest))
                        Text("剩余").font(.caption2).foregroundStyle(.secondary)
                    }
                } else if let balance = card.balanceText {
                    Text(balance).font(.title3.weight(.semibold).monospacedDigit())
                }
            }

            ForEach(Array(card.windows.enumerated()), id: \.offset) { _, window in
                WindowRow(window: window, readAt: card.readAt, now: now)
            }

            if card.lowestRemaining != nil, let balance = card.balanceText {
                Label("余额 \(balance)", systemImage: "creditcard").font(.subheadline)
            } else if card.windows.isEmpty, card.balanceText != nil {
                Text("预付余额（供应商显示的金额）").font(.footnote).foregroundStyle(.secondary)
            }
            if let problem = card.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("quota.card")
    }

    @ViewBuilder private var footer: some View {
        let parts = footerParts
        if !parts.isEmpty {
            Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footerParts: [String] {
        var parts: [String] = []
        if let readAt = card.readAt { parts.append(QuotaFormat.readAgo(readAt, now: now)) }
        else if let asOf = card.asOf { parts.append("缓存于 \(QuotaFormat.absolute(asOf, now: now))") }
        if let until = card.until {
            parts.append((card.renew == "auto" ? "自动续费 " : "到期 ") + QuotaFormat.absolute(until, now: now))
        }
        if let from = card.from { parts.append("来自 \(from)") }
        return parts
    }
}

private struct WindowRow: View {
    let window: QuotaWindow
    let readAt: Date?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(QuotaFormat.windowName(window.name)).font(.subheadline.weight(.medium))
                Spacer()
                if let remaining = window.remainingPercent {
                    Text("已用 \(QuotaFormat.percent(100 - remaining)) · 剩余 \(QuotaFormat.percent(remaining))")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                } else if window.unlimited {
                    Text("不限量").font(.subheadline).foregroundStyle(.secondary)
                } else if let text = window.text {
                    Text(text).font(.subheadline).foregroundStyle(.secondary)
                } else if let balance = window.balance {
                    Text("余额 \(trim(balance))\(window.unit.map { " \($0)" } ?? "")").font(.subheadline.monospacedDigit())
                }
            }
            if let remaining = window.remainingPercent {
                ProgressView(value: remaining, total: 100)
                    .tint(quotaTint(remaining))
                    .accessibilityHidden(true)
            }
            if let counted = countedText {
                Text(counted).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let reset = window.resetDate(readAt: readAt) {
                Text(QuotaFormat.reset(reset, now: now)).font(.caption).foregroundStyle(.secondary)
            } else if let runsOut = window.runsOutAt {
                Text("按当前速度约在 \(QuotaFormat.absolute(runsOut, now: now)) 用完").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var countedText: String? {
        if let display = window.display { return display }
        if let amount = window.amount, let limit = window.limit {
            return "\(trim(amount)) / \(trim(limit))\(window.unit.map { " \($0)" } ?? "")"
        }
        return nil
    }

    private func trim(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}

private func quotaTint(_ remaining: Double) -> Color {
    if remaining <= 10 { return .red }
    if remaining <= 25 { return .orange }
    return .accentColor
}

// MARK: 密钥自己的限额

private struct KeyLimitCard: View {
    let limit: KeyLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "key.horizontal").foregroundStyle(.tint)
                    Text("这把密钥的限额").font(.headline)
                    Spacer()
                    if let key = limit.key { Text(key).font(.subheadline).foregroundStyle(.secondary) }
                }
                if !limit.limited || limit.allBudgets.isEmpty {
                    Text("这把密钥不限量。").font(.subheadline)
                }
                ForEach(Array(limit.allBudgets.enumerated()), id: \.offset) { index, budget in
                    BudgetRow(budget: budget, fromIssuer: index >= max(limit.limits.count, limit.limit == nil ? 0 : 1))
                }
                if let expires = limit.expires {
                    Text("密钥到期：\(QuotaFormat.absolute(expires))\(QuotaFormat.relative(to: expires).map { "（\($0)）" } ?? "（已过期）")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("quota.keyLimit")

            Text("\(QuotaAccessError.keyHeld.message)想看各账号的额度，请在 magpie 里给这把密钥打开「额度」选项，或换一把不受限的网关密钥。")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }
}

private struct BudgetRow: View {
    let budget: KeyBudget
    let fromIssuer: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(budget.periodText + (fromIssuer ? "（签发者）" : "")).font(.subheadline.weight(.medium))
                Spacer()
                if budget.spent {
                    Text("已用完").font(.subheadline).foregroundStyle(.red)
                } else if let remaining = budget.remainingPercent {
                    Text("剩余 \(QuotaFormat.percent(remaining))").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let remaining = budget.remainingPercent {
                ProgressView(value: remaining, total: 100).tint(quotaTint(remaining)).accessibilityHidden(true)
            }
            Text(budget.usageText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if let reset = budget.reset {
                Text(QuotaFormat.reset(reset)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: 空状态与提示

private struct QuotaEmptyView: View {
    var body: some View {
        ContentUnavailableView {
            Label("还没有订阅账号", systemImage: "gauge.with.dots.needle.0percent")
        } description: {
            Text("在 Mac 上的 magpie 里登录 Claude、Codex 等订阅账号，或添加带余额的供应商后，这里会显示剩余额度和重置时间。下拉可以刷新。")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quota.empty")
    }
}

private struct NoticeBanner: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "clock.arrow.circlepath")
            .font(.footnote)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .capsule)
            .accessibilityIdentifier("quota.notice")
    }
}

// MARK: 历史曲线

private struct QuotaHistorySection: View {
    @Binding var range: QuotaHistoryRange
    let history: [QuotaHistorySeries]?
    let failed: Bool
    let cards: [QuotaCard]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("剩余额度走势").font(.headline)
                Spacer()
                Text("近 \(range.days) 天").font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("quota.history.caption")
            }
            Picker("时间范围", selection: $range) {
                ForEach(QuotaHistoryRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("quota.history.picker")

            if failed {
                Text("历史曲线暂时读不到，下拉刷新再试。").font(.footnote).foregroundStyle(.secondary)
            } else if let history {
                let shown = history.filter { $0.pointCount > 0 }
                if shown.isEmpty {
                    Text("还没有历史记录：主机大约每 5 分钟记一次剩余额度。").font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(shown) { series in
                        HistoryChart(series: series, title: title(for: series))
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .glassCard()
    }

    private func title(for series: QuotaHistorySeries) -> String {
        if let card = cards.first(where: { $0.historyKey == series.id }) {
            return card.accountLabel == card.name ? card.name : "\(card.name) · \(card.accountLabel)"
        }
        return [series.provider, series.user].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct HistoryChart: View {
    let series: QuotaHistorySeries
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            Chart {
                ForEach(series.lines) { line in
                    ForEach(line.points, id: \.at) { point in
                        LineMark(x: .value("时间", point.at),
                                 y: .value("剩余", point.left),
                                 series: .value("窗口", line.name))
                            .foregroundStyle(by: .value("窗口", QuotaFormat.windowName(line.name)))
                            .interpolationMethod(.linear)
                    }
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text("\(Int(number))%") }
                    }
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 160)
            .accessibilityLabel("\(title) 的剩余额度走势")
        }
        .accessibilityIdentifier("quota.history.chart")
    }
}
