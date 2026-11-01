import SwiftUI
import UIKit
import MagpieRemoteCore

// 实时路由的舞台：移植自 magpie 网页「路由」页（internal/gui/assets/plugins/routing/client.js 与 routing.css，
// MIT，Copyright (c) 2026 yetone，见 THIRD_PARTY_NOTICES.md）。手机上用网页的窄屏布局（.rt.max560）：
// Agent 与 magpie 并排，账号 / Key 在它们下面，沿左侧一条线连到每一行。
// 线：默认灰；有请求在路上时按 Agent 的颜色虚线流动（3 5，每 0.7 秒流 8 点）；回答完亮着不动；休息中的虚线变淡。
// 每个请求由一只喜鹊衔着一个点飞过去（实心，Agent 的颜色），回答由另一只衔回来（空心圈；失败是红圈，只飞回 magpie）；
// 喜鹊与 magpie 标志的图形见 RoutesMagpie.swift。

// MARK: 颜色（routing.css / app.css 的变量）

enum RT {
    /// UI 测试时不放循环动画（流动的线、飞行的点、跳动的点），免得 XCUITest 一直等界面静止。
    static let uiTesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { traits in UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light) })
    }
    static let line = dynamic(0xE3E3E8, 0x333339)
    static let fg = dynamic(0x1C1C21, 0xEDEDF1)
    static let fg2 = dynamic(0x45454D, 0xC4C4CC)
    static let muted = dynamic(0x85858D, 0x8B8B94)
    static let card = dynamic(0xFFFFFF, 0x1C1C20)
    static let card2 = dynamic(0xF4F4F6, 0x26262B)
    static let red = Color(UIColor(hex: 0xD64545))
    static let green = Color(UIColor(hex: 0x189A58))

    static func hue(_ agent: String) -> Color {
        let text = RouteStageBuilder.hue(agent).dropFirst()
        return Color(UIColor(hex: UInt32(text, radix: 16) ?? 0x85858D))
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: 位置

private enum StageNode: Hashable {
    case agent(String), hub, agents, row(String)
}

private struct StageBoundsKey: PreferenceKey {
    static let defaultValue: [StageNode: Anchor<CGRect>] = [:]
    static func reduce(value: inout [StageNode: Anchor<CGRect>], nextValue: () -> [StageNode: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    func stageNode(_ node: StageNode) -> some View {
        anchorPreference(key: StageBoundsKey.self, value: .bounds) { [node: $0] }
    }
}

/// 网页 layout() 的线：Agent → magpie 是一段横向贝塞尔；magpie → 每行沿左侧走一条「车道」。
private enum Wires {
    static func agent(_ s: CGRect, hub h: CGRect) -> Path {
        var p = Path()
        if h.minX > s.maxX {
            let mx = (s.maxX + h.minX) / 2
            p.move(to: CGPoint(x: s.maxX, y: s.midY))
            p.addCurve(to: CGPoint(x: h.minX, y: h.midY), control1: CGPoint(x: mx, y: s.midY), control2: CGPoint(x: mx, y: h.midY))
        } else {
            p.move(to: CGPoint(x: s.midX, y: s.maxY))
            p.addLine(to: CGPoint(x: h.midX, y: h.minY))
        }
        return p
    }

    static func row(_ a: CGRect, hub h: CGRect, agentsBottom low: CGFloat) -> Path {
        var p = Path()
        if a.minX > h.maxX {
            let mx = (h.maxX + a.minX) / 2
            p.move(to: CGPoint(x: h.maxX, y: h.midY))
            p.addCurve(to: CGPoint(x: a.minX, y: a.midY), control1: CGPoint(x: mx, y: h.midY), control2: CGPoint(x: mx, y: a.midY))
            return p
        }
        let x = a.minX - 12, y = max(h.maxY, low - 8)
        p.move(to: CGPoint(x: h.midX, y: h.maxY))
        p.addLine(to: CGPoint(x: h.midX, y: y))
        p.addCurve(to: CGPoint(x: x, y: y + 24), control1: CGPoint(x: h.midX, y: y + 22), control2: CGPoint(x: x, y: y + 2))
        p.addLine(to: CGPoint(x: x, y: max(y + 24, a.midY - 10)))
        p.addQuadCurve(to: CGPoint(x: a.minX, y: a.midY), control: CGPoint(x: x, y: a.midY))
        return p
    }
}

// MARK: 舞台

struct RoutesStageView: View {
    let model: RoutesLiveModel
    let agentName: (String) -> String
    var onPickRouting: ((TraceRoute) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || RT.uiTesting }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.phase {
            case .idle, .loading:
                placeholder("正在读取网关的路由…", symbol: nil)
            case .notServing:
                placeholder("网关没有运行，因此没有任何路由。", symbol: "pause.circle")
            case .failed(let error):
                placeholder(error.localizedDescription, symbol: "exclamationmark.triangle")
            case .live:
                if let route = model.current {
                    stage(RouteStageBuilder.build(current: route, staged: model.staged, now: Date(), agentName: agentName), route: route)
                } else {
                    placeholder("还没有请求。Agent 通过 magpie 发出请求时，这里会实时显示它走的路。", symbol: "point.3.connected.trianglepath.dotted")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(RT.card, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(RT.line))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("routes.stage")
    }

    private func placeholder(_ text: String, symbol: String?) -> some View {
        HStack(spacing: 10) {
            if let symbol { Image(systemName: symbol).foregroundStyle(RT.muted) } else { ProgressView() }
            Text(text).font(.footnote).foregroundStyle(RT.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 90)
    }

    @ViewBuilder
    private func stage(_ stage: RouteStage, route: TraceRoute) -> some View {
        // 标题：组名或供应商名 · 路由组 · 启用 N 个；下面一句话说路由方式
        VStack(alignment: .leading, spacing: 3) {
            (Text(stage.name).fontWeight(.semibold).foregroundStyle(RT.fg) + Text(stage.tail).foregroundStyle(RT.muted))
                .font(.system(size: 13))
            Text(stage.mode).font(.system(size: 12.5)).foregroundStyle(RT.fg2).fixedSize(horizontal: false, vertical: true)
        }

        StageCanvas(stage: stage, model: model, reduceMotion: reduceMotion, onPickRouting: { onPickRouting?(route) })
            .padding(.vertical, 16)

        // 底部：这次请求的一句话 + 计数
        Divider().overlay(RT.line)
        VStack(alignment: .leading, spacing: 8) {
            Text(stage.caption)
                .font(.system(size: 13)).foregroundStyle(RT.fg)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .id(stage.caption)
                .transition(.opacity.combined(with: .offset(y: 4)))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: stage.caption)
                .accessibilityIdentifier("routes.caption")
            HStack(spacing: 14) {
                stat(model.book.totals.requests, "请求")
                stat(model.book.totals.rerouted, "改道")
                stat(model.book.totals.errors, "Agent 收到的错误", red: model.book.totals.errors > 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("routes.stats")
        }
        .padding(.top, 10)
    }

    private func stat(_ value: Int, _ label: String, red: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)").font(.system(size: 19, weight: .semibold)).monospacedDigit().foregroundStyle(red ? RT.red : RT.fg)
            Text(label).font(.system(size: 11)).foregroundStyle(RT.muted)
        }
    }
}

/// 节点、行与线。线和飞行的点画在节点下面（网页里它们也在卡片之下穿过）。
private struct StageCanvas: View {
    let stage: RouteStage
    let model: RoutesLiveModel
    let reduceMotion: Bool
    let onPickRouting: () -> Void

    private var animating: Bool {
        !reduceMotion && (stage.agents.contains(where: \.busy) || !model.flights.isEmpty || stage.rows.contains { $0.state == .answering })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .center, spacing: 28) {
                VStack(spacing: 10) {
                    ForEach(stage.agents) { agent in AgentNode(agent: agent).stageNode(.agent(agent.id)) }
                }
                .frame(maxWidth: .infinity)
                .stageNode(.agents)
                HubNode(chip: stage.chip, chipHidden: stage.chipHidden, action: onPickRouting)
                    .frame(maxWidth: .infinity)
                    .stageNode(.hub)
            }
            VStack(spacing: 7) {
                ForEach(stage.rows) { row in
                    SeatRow(row: row, reduceMotion: reduceMotion)
                        .stageNode(.row(row.id))
                        .accessibilityIdentifier("routes.row.\(row.seat.id)")
                }
                if stage.rows.isEmpty {
                    Text(stage.mode.isEmpty ? "没有可用的账号" : "还没有排到任何账号")
                        .font(.system(size: 13)).foregroundStyle(RT.muted)
                        .frame(maxWidth: .infinity).padding(9)
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(RT.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
            }
            .padding(.leading, 22)
            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8), value: stage.rows.map(\.id))
        }
        .backgroundPreferenceValue(StageBoundsKey.self) { anchors in
            GeometryReader { proxy in
                TimelineView(.animation(paused: !animating)) { context in
                    Canvas { gc, _ in
                        draw(in: &gc, anchors: anchors, proxy: proxy, time: context.date)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func draw(in gc: inout GraphicsContext, anchors: [StageNode: Anchor<CGRect>], proxy: GeometryProxy, time: Date) {
        guard let hubAnchor = anchors[.hub] else { return }
        let hub = proxy[hubAnchor]
        let low = anchors[.agents].map { proxy[$0].maxY } ?? hub.maxY
        // 0.7 秒流 8 点（@keyframes rtflow { to { stroke-dashoffset: -8 } }）
        let phase = reduceMotion ? 0 : CGFloat(time.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.7) / 0.7) * -8

        for agent in stage.agents {
            guard let anchor = anchors[.agent(agent.id)] else { continue }
            let path = Wires.agent(proxy[anchor], hub: hub)
            if agent.busy {
                gc.stroke(path, with: .color(RT.hue(agent.id)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 5], dashPhase: -phase))
            } else {
                gc.stroke(path, with: .color(RT.line), lineWidth: 1.5)
            }
        }
        for row in stage.rows {
            guard let anchor = anchors[.row(row.id)] else { continue }
            let path = Wires.row(proxy[anchor], hub: hub, agentsBottom: low)
            let hue = row.agent.map(RT.hue) ?? RT.muted
            switch row.state {
            case .answering:
                gc.stroke(path, with: .color(hue), style: StrokeStyle(lineWidth: 1.5, dash: [3, 5], dashPhase: -phase))
            case .answered:
                gc.stroke(path, with: .color(hue), lineWidth: 1.5)
            case .resting, .passedOver:
                gc.stroke(path, with: .color(RT.line.opacity(0.45)), style: StrokeStyle(lineWidth: 1.5, dash: [2, 6]))
            case .idle:
                gc.stroke(path, with: .color(RT.line), lineWidth: 1.5)
            }
        }
        guard !reduceMotion else { return }
        // 飞行：一只喜鹊把请求衔出去（Agent → 穿过 magpie → 座位），另一只把回答衔回来（座位 → magpie → Agent；
        // 失败只回到 magpie）。点在它嘴尖上；到了就松开点，向上飞走（client.js play() / pose() / bird()）。
        for flight in model.flights {
            let elapsed = time.timeIntervalSince(flight.start)
            let duration: TimeInterval = 1.4
            guard elapsed >= 0, elapsed <= duration + MagpieMotion.away,
                  let agentAnchor = anchors[.agent(flight.agent)], let rowAnchor = anchors[.row(flight.seat)] else { continue }
            let way = flightLine(flight, agent: proxy[agentAnchor], row: proxy[rowAnchor], hub: hub, agentsBottom: low)
            guard !way.isEmpty else { continue }
            let hue = RT.hue(flight.agent)
            if elapsed <= duration {
                // 每个 Agent 的请求和回答用它的颜色飞：请求实心，回答空心圈，失败红圈
                let point = way.dot(at: CGFloat(MagpieMotion.glide(elapsed / duration)))
                let radius: CGFloat = flight.back && !flight.failed ? 4 : 4.5
                let dot = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
                if flight.back {
                    gc.fill(dot, with: .color(flight.failed ? hue : RT.card))
                    gc.stroke(dot, with: .color(flight.failed ? RT.red : hue), lineWidth: 2.25)
                } else {
                    var glow = gc
                    glow.addFilter(.shadow(color: hue, radius: 3))
                    glow.fill(dot, with: .color(hue))
                }
            }
            if let lift = MagpieMotion.lift(elapsed: elapsed, landed: duration) {
                let pose = MagpiePose.of(way, elapsed: elapsed, duration: duration, leftward: flight.back)
                MagpieFlier.draw(in: gc, pose: pose, lift: lift, flapTime: elapsed, ink: RT.fg, card: RT.card)
            }
        }
    }

    /// 这次飞行的整条路线：线 + 穿过 magpie 的弧（网页 via()）+ 线；回程沿同样的线反着飞（网页 home()）。
    private func flightLine(_ flight: RoutesLiveModel.Flight, agent: CGRect, row: CGRect, hub: CGRect, agentsBottom low: CGFloat) -> FlightLine {
        let toHub = FlightLine(Wires.agent(agent, hub: hub))
        let toRow = FlightLine(Wires.row(row, hub: hub, agentsBottom: low))
        guard let hubIn = toHub.end, let hubOut = toRow.start else { return FlightLine() }
        if flight.back {
            var way = toRow.reversed()
            if flight.failed { return way } // 失败：只飞回 magpie，由它交给下一个
            let home = toHub.reversed()
            guard let from = way.end, let to = home.start else { return way }
            way.append(FlightLine.via(from: from, heading: way.endHeading, to: to, heading: home.startHeading, hub: hub))
            way.append(home)
            return way
        }
        var way = toHub
        way.append(FlightLine.via(from: hubIn, heading: toHub.endHeading, to: hubOut, heading: toRow.startHeading, hub: hub))
        way.append(toRow)
        return way
    }
}

private struct AgentNode: View {
    let agent: StageAgent

    var body: some View {
        VStack(spacing: 2) {
            Group {
                // 网页 .rt-src 的 .rt-ic：Agent 的官方图标；认不出的 Agent 用首字母方块。
                if BrandIcon.isBrand(OfficialIcon.agent(agent.id)) {
                    BrandIcon(OfficialIcon.agent(agent.id), size: 22).foregroundStyle(RT.fg).frame(width: 26, height: 26)
                } else {
                    Text(String(agent.name.prefix(1)).uppercased())
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(RT.hue(agent.id), in: .rect(cornerRadius: 7, style: .continuous))
                }
            }
            .padding(.bottom, 3)
            Text(agent.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(RT.fg).lineLimit(1)
            Text(agent.busy ? "正在发送" : "Agent").font(.system(size: 11)).foregroundStyle(RT.muted).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(RT.card, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(RT.line))
        .accessibilityElement(children: .combine)
    }
}

/// 中间的 magpie：黑框外再一圈浅色描边，下方小胶囊是路由方式（点它看路由组设置）。
private struct HubNode: View {
    let chip: String
    let chipHidden: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            MagpieLogo().fill(RT.fg, style: FillStyle(eoFill: true)).frame(width: 26, height: 26).padding(.bottom, 3)
            Text("magpie").font(.system(size: 13, weight: .semibold)).foregroundStyle(RT.fg)
            Text("网关").font(.system(size: 11)).foregroundStyle(RT.muted)
            if !chipHidden {
                Button(action: action) {
                    Text(chip)
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 1)
                        .foregroundStyle(RT.card)
                        .background(RT.fg, in: .capsule)
                }
                .buttonStyle(.plain)
                .padding(.top, 5)
                .accessibilityIdentifier("routes.hub.chip")
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(RT.card, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(RT.fg))
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(RT.card2, lineWidth: 8))
        .accessibilityElement(children: .combine)
    }
}

/// 一个账号 / Key 的一行（网页 .rt-accts li）：点、名字、模型、一句状态、额度条；失败时右上角红色状态码。
private struct SeatRow: View {
    let row: StageRow
    let reduceMotion: Bool
    @State private var pulse = false

    private var dimmed: Double {
        switch row.state {
        case .resting: 0.5
        case .passedOver: 0.45
        default: 1
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            dot
            VStack(alignment: .leading, spacing: 6) {
                title
                Text(row.status)
                    .font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(statusColor)
                    .opacity(row.state == .resting ? 0.85 / dimmed : 1)
                    .fixedSize(horizontal: false, vertical: true)
                if let bar = row.bar {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(RT.card2)
                            Capsule().fill(row.state.lit ? RT.fg : RT.muted).frame(width: geo.size.width * bar / 100)
                        }
                    }
                    .frame(height: 3)
                    .animation(.easeOut(duration: 0.4), value: bar)
                }
            }
            .opacity(dimmed)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RT.card, in: .rect(cornerRadius: 10, style: .continuous))
        .overlay(border)
        .overlay(alignment: .topTrailing) {
            if let tag = row.tag {
                Text(tag)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(RT.red, in: .rect(cornerRadius: 6))
                    .offset(x: -10, y: -10)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: row.tag)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: row.state)
        .accessibilityElement(children: .combine)
        .accessibilityValue(stateLabel)
    }

    private var stateLabel: String {
        switch row.state {
        case .answering: "回答中"
        case .answered: "已回答"
        case .resting: "休息中"
        case .passedOver: "已跳过"
        case .idle: ""
        }
    }

    private var statusColor: Color {
        switch row.state {
        case .resting: RT.red
        case .answering, .answered: RT.fg
        default: row.low ? RT.fg2 : RT.muted
        }
    }

    private var border: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Group {
            switch row.state {
            case .answering, .answered: shape.strokeBorder(RT.fg)
            case .resting: shape.strokeBorder(RT.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            case .passedOver: shape.strokeBorder(RT.line, style: StrokeStyle(lineWidth: 1, dash: [1, 2]))
            case .idle: shape.strokeBorder(RT.line)
            }
        }
    }

    private var dot: some View {
        let lit = row.state.lit
        return Circle()
            .strokeBorder(lit ? RT.fg : RT.muted, lineWidth: 1.5)
            .background(Circle().fill(lit ? RT.fg : .clear))
            .frame(width: 8, height: 8)
            .background {
                // 正在回答：点向外扩散（@keyframes rtlive 1.8s）
                if row.state == .answering && !reduceMotion {
                    Circle().stroke(RT.fg.opacity(pulse ? 0 : 0.4), lineWidth: pulse ? 6 : 0)
                        .frame(width: pulse ? 20 : 8, height: pulse ? 20 : 8)
                        .onAppear { withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true } }
                        .onDisappear { pulse = false }
                }
            }
            .frame(width: 10)
    }

    private var title: some View {
        let seat = row.seat
        return HStack(spacing: 6) {
            if BrandIcon.isBrand(seat.officialIcon) {
                // 网页 .rt-accts b .ic：供应商标志
                BrandIcon(seat.officialIcon, size: 14).foregroundStyle(RT.fg)
            } else {
                Image(systemName: seat.kind == "account" ? "person.crop.circle" : seat.kind == "provider" ? "shippingbox" : "key")
                    .font(.system(size: 12)).foregroundStyle(RT.fg2)
            }
            Text(seat.title).font(.system(size: 13, weight: .medium)).foregroundStyle(RT.fg).lineLimit(1)
            if !seat.detail.isEmpty {
                Text(seat.detail).font(.system(size: 13)).foregroundStyle(RT.muted).lineLimit(1)
            }
            Text(seat.modelLabel)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(RT.fg2)
                .padding(.horizontal, 5).background(RT.card2, in: .rect(cornerRadius: 5))
                .lineLimit(1)
            if seat.fast { badge("快速") }
            if seat.fallback { badge("备用") }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(RT.muted)
            .padding(.horizontal, 6)
            .overlay(Capsule().strokeBorder(RT.line))
    }
}

// MARK: 请求列表

/// 舞台下方最近的请求（网页舞台下的请求列表）：点一个，舞台改画那个请求；「回到实时」跟着最新的走。
struct RoutesRequestList: View {
    let model: RoutesLiveModel
    let agentName: (String) -> String

    var body: some View {
        let routes = Array(model.book.list.prefix(20))
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("最近的请求").font(.footnote.weight(.semibold)).foregroundStyle(RT.fg)
                Spacer()
                if model.pinned != nil {
                    Button("回到实时") { model.pinned = nil }
                        .font(.footnote)
                        .accessibilityIdentifier("routes.live")
                }
            }
            .padding(.bottom, 6)
            if routes.isEmpty {
                Text("还没有请求").font(.footnote).foregroundStyle(RT.muted)
            }
            ForEach(routes) { route in
                Button {
                    model.pinned = route.id == model.pinned ? nil : route.id
                } label: {
                    RequestRow(route: route, agentName: agentName, selected: route.id == model.current?.id)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("routes.request.\(route.id)")
                if route.id != routes.last?.id { Divider().overlay(RT.line) }
            }
        }
    }
}

private struct RequestRow: View {
    let route: TraceRoute
    let agentName: (String) -> String
    let selected: Bool

    private var target: String {
        guard let attempt = route.answered ?? route.trying ?? route.tries.last, let seat = route.seat(of: attempt) else { return "等待中" }
        return seat.kind == "provider" || seat.who.isEmpty ? seat.name : "\(seat.name) · \(seat.who)"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(RT.hue(route.agent)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(agentName(route.agent)).font(.system(size: 13, weight: .medium)).foregroundStyle(RT.fg)
                    Text(route.model).font(.system(size: 11, design: .monospaced)).foregroundStyle(RT.fg2).lineLimit(1)
                }
                HStack(spacing: 4) {
                    Circle().fill(route.failed ? RT.red : route.done ? RT.green : RT.muted).frame(width: 6, height: 6)
                    Text("→ " + target).font(.system(size: 12)).foregroundStyle(route.failed ? RT.red : RT.muted).lineLimit(1)
                    if route.rerouted > 0 { Text("改道 \(route.rerouted) 次").font(.system(size: 11)).foregroundStyle(RT.muted) }
                }
                if !route.sessionTitle.isEmpty {
                    Text(route.sessionTitle).font(.system(size: 11)).foregroundStyle(RT.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(route.done ? (route.failed ? "\(route.status)" : String(format: "%.1f 秒", Double(route.ms) / 1000)) : "进行中")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(route.failed ? RT.red : RT.fg2)
                if let time = route.time {
                    Text(time, style: .time).font(.system(size: 11)).foregroundStyle(RT.muted)
                }
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 6)
        .background(selected ? RT.card2 : .clear, in: .rect(cornerRadius: 8))
        .contentShape(.rect)
    }
}
