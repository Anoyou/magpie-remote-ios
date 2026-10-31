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
                        QuotaGroupsView(cards: cards, now: context.date, refreshingCard: refreshingCard,
                                        range: $range, history: history, historyFailed: historyFailed) { card in
                            Task { await refresh(card) }
                        }
                    }
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

// MARK: 账号（默认折叠）

/// 哪些账号是展开的：本次运行中记住（切换标签、刷新、重新连接都保持），重新打开 App 时全部折叠。
@MainActor @Observable
final class QuotaExpansionStore {
    static let shared = QuotaExpansionStore()
    var state = QuotaExpansion()
}

private struct QuotaGroupsView: View {
    let cards: [QuotaCard]
    let now: Date
    let refreshingCard: String?
    @Binding var range: QuotaHistoryRange
    let history: [QuotaHistorySeries]?
    let historyFailed: Bool
    let refresh: (QuotaCard) -> Void
    @State private var expansion = QuotaExpansionStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(QuotaGroup.group(cards)) { group in
                let accounts = QuotaAccount.group(group.cards)
                if accounts.count > 1 {
                    Text("\(group.title) · \(accounts.count) 个账号")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                ForEach(accounts) { account in
                    QuotaAccountView(
                        account: account, now: now,
                        expanded: expansion.state.isExpanded(account.id),
                        refreshing: account.cards.contains { $0.id == refreshingCard },
                        range: $range,
                        history: history.map { all in all.filter { account.historyKeys.contains($0.id) } },
                        historyFailed: historyFailed,
                        toggle: {
                            withAnimation(.snappy(duration: 0.3)) { expansion.state.toggle(account.id) }
                        },
                        refresh: { if let card = account.refreshCard { refresh(card) } }
                    )
                }
            }
        }
    }
}

private struct QuotaAccountView: View {
    let account: QuotaAccount
    let now: Date
    let expanded: Bool
    let refreshing: Bool
    @Binding var range: QuotaHistoryRange
    let history: [QuotaHistorySeries]?
    let historyFailed: Bool
    let toggle: () -> Void
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                detail
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var header: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                ProviderBadge(account: account)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(account.title).font(.headline).lineLimit(1)
                        if !account.subtitle.isEmpty {
                            Text(account.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Text(account.summary(now: now))
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 8)
                if refreshing {
                    ProgressView()
                } else if let lowest = account.lowestRemaining {
                    Text(QuotaFormat.percent(lowest)).font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(statusTint(account.status))
                } else if account.status == .problem {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .padding(16)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded ? "已展开" : "已收起")
        .accessibilityHint(expanded ? "点按收起明细" : "点按展开明细")
        .accessibilityIdentifier("quota.account.header")
        .contextMenu {
            if account.canRefresh {
                Button("重新读取这个账号", systemImage: "arrow.clockwise", action: refresh)
            }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            ForEach(account.cards, id: \.self) { card in
                QuotaCardView(card: card, now: now, showsTitle: account.cards.count > 1)
            }
            if account.hasMeteredWindows {
                AccountHistoryView(range: $range, history: history, failed: historyFailed, title: account.title)
            }
            if account.canRefresh {
                Button(action: refresh) {
                    Label(refreshing ? "正在重新读取…" : "重新读取这个账号", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(refreshing)
                .accessibilityIdentifier("quota.account.refresh")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}

/// 供应商标记：首字母圆角方块，底色跟随账号状态。
private struct ProviderBadge: View {
    let account: QuotaAccount

    var body: some View {
        Text(account.monogram)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(statusTint(account.status).gradient, in: .rect(cornerRadius: 10, style: .continuous))
            .accessibilityLabel(account.providerName)
    }
}

private func statusTint(_ status: QuotaAccount.Status) -> Color {
    switch status {
    case .ok: return .accentColor
    case .low: return .orange
    case .critical: return .red
    case .problem: return .orange
    case .neutral: return .gray
    }
}

/// 展开后的单张卡片明细（窗口、余额、问题、读取时间）；外层账号卡片已有标题。
private struct QuotaCardView: View {
    let card: QuotaCard
    let now: Date
    let showsTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsTitle || card.accountDetail != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if showsTitle { Text(card.plan ?? card.name).font(.subheadline.weight(.semibold)) }
                    if let detail = card.accountDetail {
                        Text(detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            ForEach(Array(card.windows.enumerated()), id: \.offset) { _, window in
                WindowRow(window: window, readAt: card.readAt, now: now)
            }

            if let balance = card.balanceText {
                Label("余额 \(balance)", systemImage: "creditcard").font(.subheadline)
                if card.windows.isEmpty {
                    Text("预付余额（供应商显示的金额）").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let problem = card.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// 展开账号里的剩余额度走势；时间范围在所有账号间共用。
private struct AccountHistoryView: View {
    @Binding var range: QuotaHistoryRange
    let history: [QuotaHistorySeries]?
    let failed: Bool
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("剩余额度走势").font(.subheadline.weight(.semibold))
                Spacer()
                Text("近 \(range.days) 天").font(.footnote).foregroundStyle(.secondary)
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
                        HistoryChart(series: series, title: title)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }
}

private struct HistoryChart: View {
    let series: QuotaHistorySeries
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
