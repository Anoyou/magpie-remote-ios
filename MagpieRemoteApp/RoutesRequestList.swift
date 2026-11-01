import SwiftUI
import MagpieRemoteCore

// 舞台下面的请求列表（网页 #rtMore 的「请求」一栏：row-head、按请求 / 按会话、.list.rt-reqs）。
// 窄屏时（.rt-col.max760）每行两列：左边是时刻，右边三行——Agent 的点和标志、问的模型；→ 谁答的 · 哪个模型；尝试次数与各项指标。
// 移植自 magpie 的 internal/gui/assets/plugins/routing/client.js（reqRow、groupedRows、renderHist）与 routing.css，MIT，Copyright (c) 2026 yetone。

/// 舞台下方最近的请求（网关保留最近 60 个）：默认只列最新的 10 个，点「显示全部」展开；
/// 可按会话分组（网页「按请求 / 按会话」，记住选择）。点一个，舞台改画那个请求（网页 pick）。
struct RoutesRequestList: View {
    let model: RoutesLiveModel
    let agentName: (String) -> String
    /// 默认收起时列几个。
    static let folded = 10
    @State private var expanded = false
    @State private var closedSessions = Set<String>()
    @AppStorage("magpie.routingBySession") private var bySession = false

    var body: some View {
        let all = model.book.list
        let routes = expanded ? all : Array(all.prefix(Self.folded))
        let mask = model.mask(agentName: agentName)
        VStack(alignment: .leading, spacing: 0) {
            // .row-head.rt-req-head：「请求」、灰色小字、全部重放
            HStack(alignment: .center, spacing: 0) {
                Text(RouteWords.t("Requests")).font(.system(size: 13, weight: .semibold)).foregroundStyle(RT.fg)
                if !all.isEmpty {
                    Text(RouteWords.t("the last {n} the gateway keeps", ["n": "\(all.count)"]))
                        .font(.system(size: 11)).foregroundStyle(RT.faint).lineLimit(1)
                        .padding(.leading, 8)
                }
                Spacer(minLength: 6)
                if all.filter(\.done).count > 1 && model.replay == nil {
                    Button(RouteWords.t("Replay them all")) { model.startReplay(all, back: model.pinned) }
                        .buttonStyle(TextButtonStyle())
                        .accessibilityIdentifier("routes.replay.all")
                }
            }
            .frame(minHeight: 26)
            .padding(.horizontal, 2)
            .padding(.bottom, 6)
            if !all.isEmpty {
                // .rt-group-by：两个小圆角按钮（.rt-day），选中的深色字和边
                HStack(spacing: 4) {
                    pill(RouteWords.t("By request"), on: !bySession) { bySession = false }
                    pill(RouteWords.t("By session"), on: bySession) { bySession = true }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 6)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("routes.bySession")
            }
            VStack(alignment: .leading, spacing: 0) {
                if all.isEmpty {
                    // .rt-reqs.none .empty-state
                    VStack(alignment: .leading, spacing: 2) {
                        Text(RouteWords.t("No requests since magpie started")).font(.system(size: 13, weight: .semibold)).foregroundStyle(RT.fg)
                        Text(RouteWords.t("Each request an agent sends through magpie shows up here: who answered it, why, and each try."))
                            .font(.system(size: 12)).foregroundStyle(RT.muted).lineSpacing(3)
                    }
                    .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 18)
                } else if bySession && routes.contains(where: { !$0.session.isEmpty }) {
                    ForEach(sessions(routes), id: \.key) { group in
                        sessionHead(group, mask: mask)
                        if !closedSessions.contains(group.key) {
                            ForEach(group.routes) { route in row(route, mask: mask) }
                        }
                    }
                } else {
                    ForEach(routes) { route in row(route, mask: mask) }
                }
                if all.count > Self.folded {
                    Button {
                        withAnimation(.easeOut(duration: 0.25)) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(expanded ? "收起" : "显示全部 \(all.count) 个")
                            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10))
                        }
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(RT.ctlFg)
                    .accessibilityIdentifier("routes.requests.more")
                }
            }
            // .list.rt-reqs：卡片底、1 像素边、圆角 12，里面留 4
            .padding(all.isEmpty ? 0 : 4)
            .background(all.isEmpty ? Color.clear : RT.card, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay {
                if !all.isEmpty { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(RT.line) }
            }
        }
        .textRenderer(PIIRenderer())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("routes.requests")
    }

    private func pill(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(on ? RT.fg : RT.muted)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .overlay(Capsule().strokeBorder(on ? RT.fg : RT.line))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func row(_ route: TraceRoute, mask: AccountMask?) -> some View {
        Button {
            model.pick(route)
        } label: {
            RequestRow(route: route, agentName: agentName, selected: route.id == model.current?.id && model.replay == nil, mask: mask)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("routes.request.\(route.id)")
    }

    private struct SessionGroup {
        var key: String
        var routes: [TraceRoute]
    }

    /// 网页 groupedRows：同一个 Agent 的同一个会话在一起，按第一次出现的顺序。
    private func sessions(_ routes: [TraceRoute]) -> [SessionGroup] {
        var out: [SessionGroup] = []
        for route in routes {
            if let index = out.firstIndex(where: { $0.key == route.sessionKey }) { out[index].routes.append(route) }
            else { out.append(SessionGroup(key: route.sessionKey, routes: [route])) }
        }
        return out
    }

    /// 网页 .rt-session：▾ / ▸、名字（Agent · 文件夹 · 标题）、N 个请求 · token · N 个进行中、费用。
    private func sessionHead(_ group: SessionGroup, mask: AccountMask?) -> some View {
        let first = group.routes[0]
        let open = !closedSessions.contains(group.key)
        let title = group.routes.first { !$0.sessionTitle.isEmpty }?.sessionTitle ?? ""
        let folder = group.routes.first { !$0.folder.isEmpty }?.folder ?? ""
        let name = group.key.isEmpty ? RouteWords.t("No session ID")
            : [agentName(first.agent), folder, title.isEmpty && folder.isEmpty ? first.session : title].filter { !$0.isEmpty }.joined(separator: " · ")
        let tokens = group.routes.reduce(0) { $0 + $1.tokens }
        let running = group.routes.filter { !$0.done }.count
        var bits = [RouteWords.t("{n} requests", ["n": "\(group.routes.count)"])]
        if tokens > 0 { bits.append(RouteWords.t("{n} tokens", ["n": RouteWords.tokens(Double(tokens))])) }
        if running > 0 { bits.append(RouteWords.t("{n} in progress", ["n": "\(running)"])) }
        let costs = group.routes.compactMap(\.cost)
        return Button {
            guard !group.key.isEmpty else { return }
            if open { closedSessions.insert(group.key) } else { closedSessions.remove(group.key) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if !group.key.isEmpty {
                    Text(open ? "▾" : "▸").foregroundStyle(RT.muted).frame(width: 10)
                }
                PII.text(name, mask).fontWeight(.medium).foregroundStyle(RT.fg2).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(bits.joined(separator: " · ")).foregroundStyle(RT.muted).monospacedDigit().lineLimit(1)
                    .layoutPriority(1)
                if !costs.isEmpty {
                    Text(RequestRow.cost(costs.reduce(0, +))).foregroundStyle(RT.fg2).monospacedDigit().lineLimit(1)
                }
            }
            .font(.system(size: 12))
            .padding(.vertical, 9)
            .padding(.horizontal, 8)
            .background(RT.card2, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(RT.line))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .accessibilityIdentifier("routes.session")
    }
}

/// 一个请求（网页 button.rt-req，窄屏 .max760：时刻一列，其余三行）。
struct RequestRow: View {
    let route: TraceRoute
    let agentName: (String) -> String
    let selected: Bool
    let mask: AccountMask?

    static func clock(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    /// 网页 fmtCost：≈$0.004（1 以上两位小数，100 以上不带小数）。
    static func cost(_ c: Double) -> String {
        "≈$" + (c >= 100 ? String(format: "%.0f", c) : c >= 1 ? String(format: "%.2f", c) : String(format: "%.3f", c))
    }

    var body: some View {
        let (said, how) = RouteStory.outcome(route)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Self.clock(route.time)).monospacedDigit().foregroundStyle(RT.muted).lineLimit(1).fixedSize()
            VStack(alignment: .leading, spacing: 2) {
                // .asked：Agent 的点（8）、Agent 的标志（14）、问的模型（放不下时省略号）
                HStack(spacing: 6) {
                    Circle().fill(RT.hue(route.agent)).frame(width: 8, height: 8)
                    let icon = OfficialIcon.agent(route.agent)
                    if BrandIcon.isBrand(icon) { BrandIcon(icon, size: 14).foregroundStyle(RT.fg) }
                    else { Image(systemName: "shippingbox").font(.system(size: 10)).foregroundStyle(RT.fg2).frame(width: 14, height: 14) }
                    Text(route.model).lineLimit(1).truncationMode(.tail).foregroundStyle(RT.fg2)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "\(agentName(route.agent)) · \(route.model)"))
                // .to：去向前的小点（答了绿、改道过的 accent、失败红、还在等灰且向外扩散）
                HStack(spacing: 6) {
                    Circle().fill(dotColor(how)).frame(width: 6, height: 6)
                    saidView(said, how: how)
                }
                .foregroundStyle(how == .bad ? RT.red : RT.fg)
                let meta = Self.meta(route, how: how)
                if !meta.isEmpty {
                    Text(meta).monospacedDigit().foregroundStyle(RT.muted).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(selected ? RT.card2 : .clear, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? RT.line : .clear))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 谁答的 · 哪个模型：放不下时先让账号短下去（网页 .said.split：.who flex-shrink 大、.mdl 不缩）。
    @ViewBuilder
    private func saidView(_ text: String, how: RouteStory.Outcome) -> some View {
        if (how == .ok || how == .moved), let cut = text.range(of: " · ", options: .backwards) {
            HStack(spacing: 0) {
                PII.text(String(text[..<cut.lowerBound]), mask).lineLimit(1).truncationMode(.tail)
                    .frame(minWidth: 40, alignment: .leading)
                Text(String(text[cut.lowerBound...])).lineLimit(1).truncationMode(.tail).layoutPriority(1)
            }
        } else {
            PII.text(text, mask).lineLimit(1).truncationMode(.tail)
        }
    }

    private func dotColor(_ how: RouteStory.Outcome) -> Color {
        switch how {
        case .ok: RT.green
        case .moved: RT.accent
        case .bad: RT.red
        case .wait: RT.muted
        }
    }

    /// 网页 rowSays 的 meta 与 requestMetrics（紧凑：耗时、首字耗时、token、速度只写数，费用在后面）。
    static func meta(_ r: TraceRoute, how: RouteStory.Outcome) -> String {
        var parts: [String] = []
        if r.tries.count > 1 { parts.append(RouteWords.t("{n} tries", ["n": "\(r.tries.count)"])) }
        if r.done && r.ms > 0 { parts.append(RouteWords.took(r.ms)) }
        if r.done && r.ttft > 0 { parts.append(RouteWords.t("First token") + " " + RouteWords.took(r.ttft)) }
        if r.tokens > 0 { parts.append(RouteWords.tokens(Double(r.tokens)) + " token") }
        if r.done, how != .bad, r.output > 0, r.ttft > 0, r.ms - r.ttft >= 100 {
            let speed = Double(r.output) / (Double(r.ms - r.ttft) / 1000)
            if speed <= 10_000 { parts.append(RouteWords.t("{n} tok/s", ["n": "\(Int(speed.rounded()))"])) }
        }
        var text = parts.joined(separator: " · ")
        if let c = r.cost { text += (text.isEmpty ? "" : "   ") + Self.cost(c) }
        return text
    }
}
