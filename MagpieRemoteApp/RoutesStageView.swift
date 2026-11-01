import SwiftUI
import UIKit
import MagpieRemoteCore

// 实时路由的舞台：移植自 magpie 网页「路由」页（internal/gui/assets/plugins/routing/client.js 与 routing.css，
// MIT，Copyright (c) 2026 yetone，见 THIRD_PARTY_NOTICES.md）。手机上用网页的窄屏布局（.rt.max560）：
// Agent 与 magpie 并排，账号 / Key 在它们下面，沿左侧一条线连到每一行。
// 线：默认灰；有请求在路上时按 Agent 的颜色虚线流动（3 5，每 0.7 秒流 8 点）；回答完亮着不动；休息中的虚线变淡。
// 每个请求由一只喜鹊衔着一个点飞过去（实心，Agent 的颜色），放在座位前等它回答（一闪一闪），回答由另一只衔回来
// （空心圈；失败是红圈，飞回 magpie 由它交给下一个）——演出的顺序与时长见 MagpieRemoteCore 的 RoutePlay（网页 play()）。
// 喜鹊与 magpie 标志的图形见 RoutesMagpie.swift。

// MARK: 颜色（routing.css / app.css 的变量）

enum RT {
    /// UI 测试时不放循环动画（流动的线、飞行的点、跳动的点），免得 XCUITest 一直等界面静止。
    static let uiTesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
    /// UI 测试里也让喜鹊飞（`--routes-fliers`），并给每只画出来的喜鹊放一个 `routes.flier` 元素，好检查它真的画出来了。
    static let fliersInTests = uiTesting && ProcessInfo.processInfo.arguments.contains("--routes-fliers")

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

// MARK: 账号打码

/// 打码的那几段字（网页 `.pii`）：画的时候模糊 2.2、半透明 0.5。
struct PIIAttribute: TextAttribute {}

/// 让带 `PIIAttribute` 的字模糊（routing.css `.pii { filter: blur(2.2px); opacity: .5 }`），其余照常画。
struct PIIRenderer: TextRenderer {
    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        for line in layout {
            for run in line {
                if run[PIIAttribute.self] != nil {
                    var blurred = ctx
                    blurred.opacity = 0.5
                    blurred.addFilter(.blur(radius: 2.2))
                    blurred.draw(run)
                } else {
                    ctx.draw(run)
                }
            }
        }
    }
}

enum PII {
    /// 一段可能含账号的字：打码时账号换成替身字母并模糊。
    static func text(_ string: String, _ mask: AccountMask?) -> Text {
        guard let mask else { return Text(verbatim: string) }
        let parts = mask.segments(string)
        guard parts.contains(where: \.masked) else { return Text(verbatim: string) }
        return parts.reduce(Text(verbatim: "")) { text, part in
            part.masked ? text + Text(verbatim: part.text).customAttribute(PIIAttribute()) : text + Text(verbatim: part.text)
        }
    }
}

// MARK: 舞台

struct RoutesStageView: View {
    let model: RoutesLiveModel
    let agentName: (String) -> String
    var onPickRouting: ((TraceRoute) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// 行上的动画（跳动的点、行的移动）：UI 测试时不放。
    private var reduceMotion: Bool { systemReduceMotion || RT.uiTesting }
    /// 喜鹊与流动的线：系统「减弱动态效果」时不飞（网页 still()）；UI 测试时只有 `--routes-fliers` 才飞。
    private var stillSky: Bool { systemReduceMotion || (RT.uiTesting && !RT.fliersInTests) }

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
                if model.current != nil {
                    // 倒计时（休息到几点、几小时后重置）与「刚结束的请求在台上留 12 秒」每秒走一次（网页 countdown()）
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 0) {
                            if let route = model.current {
                                let mask = model.mask(agentName: agentName)
                                stage(RouteStageBuilder.build(current: route, staged: model.staged(now: context.date), now: context.date, agentName: agentName),
                                      route: route, mask: mask)
                            }
                        }
                    }
                } else {
                    header(nil, mask: nil)
                    placeholder("还没有请求。Agent 通过 magpie 发出请求时，这里会实时显示它走的路。", symbol: "point.3.connected.trianglepath.dotted")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(RT.card, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(RT.line))
        .textRenderer(PIIRenderer())
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

    /// 标题：组名或供应商名 · 路由组 · 启用 N 个；下面一句话说路由方式。右边是「账号打码」（网页 #rtMask）。
    private func header(_ stage: RouteStage?, mask: AccountMask?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                if let stage {
                    (PII.text(stage.name, mask).fontWeight(.semibold).foregroundStyle(RT.fg) + PII.text(stage.tail, mask).foregroundStyle(RT.muted))
                        .font(.system(size: 13))
                    PII.text(stage.mode, mask).font(.system(size: 12.5)).foregroundStyle(RT.fg2).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("等待请求").font(.system(size: 13, weight: .semibold)).foregroundStyle(RT.fg)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.masked.toggle()
            } label: {
                Label(model.masked ? "账号已打码" : "账号打码", systemImage: model.masked ? "eye.slash" : "eye")
                    .font(.system(size: 12))
                    .foregroundStyle(model.masked ? RT.fg2 : RT.muted)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .accessibilityHint(model.masked ? "账号已打码，点击显示" : "给本页的账号（邮箱地址和账号名）打码，方便截图分享")
            .accessibilityValue(model.masked ? "开" : "关")
            .accessibilityIdentifier("routes.mask")
        }
    }

    @ViewBuilder
    private func stage(_ stage: RouteStage, route: TraceRoute, mask: AccountMask?) -> some View {
        header(stage, mask: mask)

        StageCanvas(stage: stage, model: model, reduceMotion: reduceMotion, stillSky: stillSky, mask: mask,
                    onPickRouting: { onPickRouting?(route) })
            .padding(.vertical, 16)

        // 底部：这次请求的一句话 + 计数
        Divider().overlay(RT.line)
        VStack(alignment: .leading, spacing: 8) {
            PII.text(stage.caption, mask)
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

/// 天空里此刻的一样东西：一个点，或一只喜鹊。
private struct SkyItem {
    enum Kind {
        case dot(FlightDot, held: Double?)
        case bird(MagpiePose, MagpieMotion.Lift, flap: TimeInterval)
    }

    var kind: Kind
    var point: CGPoint
    var hue: Color

    var isBird: Bool { if case .bird = kind { return true }; return false }
}

/// 节点、行与线。线、飞行的点和喜鹊都画在卡片下面（网页 .rt-sky z-index 0 在 .rt-node / .rt-accts 之下：
/// 「从卡片下面飞过，穿过 magpie 的框而不是压在它的字上」）。天空比舞台大一圈（网页 overflow: visible）：
/// 窄屏时喜鹊沿左边的车道往下飞，身子拖在车道左边，画布不能在舞台边上把它切掉。
private struct StageCanvas: View {
    let stage: RouteStage
    let model: RoutesLiveModel
    let reduceMotion: Bool
    let stillSky: Bool
    let mask: AccountMask?
    let onPickRouting: () -> Void

    /// 天空超出舞台的余量：喜鹊约 38 点长，车道离舞台左边 10 点。
    private static let overflow: CGFloat = 44

    var body: some View {
        // 在 body 里读：演出一变就重画、重新决定要不要每帧画
        let plays = Array(model.plays.values).sorted { $0.route < $1.route }
        let flowing = stage.agents.contains(where: \.busy) || stage.rows.contains { $0.state == .answering }
        let animating = !stillSky && (!plays.isEmpty || flowing)
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
                    SeatRow(row: row, reduceMotion: reduceMotion, mask: mask)
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
                    let layout = SkyLayout(anchors: anchors, proxy: proxy)
                    let time = context.date.timeIntervalSinceReferenceDate
                    let items = layout.map { sky(plays: plays, layout: $0, time: time) } ?? []
                    let pad = Self.overflow
                    ZStack(alignment: .topLeading) {
                        Canvas { gc, _ in
                            gc.translateBy(x: pad, y: pad)
                            if let layout { wires(in: &gc, layout: layout, plays: plays, time: time) }
                            draw(items, in: &gc)
                        }
                        .padding(-pad)
                        // UI 测试用：每只画出来的喜鹊一个看不见的元素（只在 --routes-fliers 时加，不打扰旁白）
                        if RT.fliersInTests {
                            ForEach(Array(items.filter(\.isBird).enumerated()), id: \.offset) { _, item in
                                Color.clear.frame(width: 6, height: 6)
                                    .contentShape(.rect)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel("喜鹊")
                                    .accessibilityIdentifier("routes.flier")
                                    .position(item.point)
                            }
                        }
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// 线：默认灰；有请求在路上（或点正在它上面飞）时按 Agent 的颜色虚线流动；回答完亮着不动；休息中的虚线变淡。
    private func wires(in gc: inout GraphicsContext, layout: SkyLayout, plays: [RoutePlay], time: TimeInterval) {
        // 0.7 秒流 8 点（@keyframes rtflow { to { stroke-dashoffset: -8 } }）
        let phase = stillSky ? 0 : CGFloat(time.truncatingRemainder(dividingBy: 0.7) / 0.7) * -8
        // 网页 render()：点在线上飞的 Agent 也算在发
        var onWire = Set<String>()
        for play in plays { if let segment = play.segment(at: time), case .fly = segment.kind { onWire.insert(play.agent) } }
        for agent in stage.agents {
            guard let rect = layout.agent(agent.id) else { continue }
            let path = Wires.agent(rect, hub: layout.hub)
            if agent.busy || onWire.contains(agent.id) {
                gc.stroke(path, with: .color(RT.hue(agent.id)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 5], dashPhase: -phase))
            } else {
                gc.stroke(path, with: .color(RT.line), lineWidth: 1.5)
            }
        }
        for row in stage.rows {
            guard let rect = layout.row(row.id) else { continue }
            let path = Wires.row(rect, hub: layout.hub, agentsBottom: layout.low)
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
    }

    /// 此刻天上有什么（client.js frame() / pose()）：每个请求一个点（衔在喜鹊嘴尖，或停在座位、magpie 前），加上衔着它的喜鹊。
    /// 「减弱动态效果」时只画停着的点（网页 still()：飞行瞬间完成，没有喜鹊）。
    private func sky(plays: [RoutePlay], layout: SkyLayout, time: TimeInterval) -> [SkyItem] {
        var items: [SkyItem] = []
        for play in plays {
            let hue = RT.hue(play.agent)
            if let segment = play.segment(at: time), let dot = dotPoint(segment, play: play, layout: layout, time: time) {
                var held: Double?
                if case .holdSeat(_, let pulsing) = segment.kind, pulsing, !stillSky {
                    // @keyframes rtheld 1.2s ease-in-out：50% 时 opacity .45
                    let q = (time - segment.start).truncatingRemainder(dividingBy: 1.2) / 1.2
                    held = 1 - 0.55 * (0.5 - 0.5 * cos(2 * Double.pi * q))
                }
                let moving: Bool = { if case .fly = segment.kind { return true }; return false }()
                if !(stillSky && moving) {
                    items.append(SkyItem(kind: .dot(segment.dot, held: held), point: dot, hue: hue))
                }
            }
            guard !stillSky else { continue }
            for bird in play.birds where time >= bird.come && time <= (bird.away ?? .infinity) + RoutePlay.awayTime {
                guard let place = play.place(of: bird, at: time),
                      let lift = MagpieMotion.lift(elapsed: time - bird.come, landed: (bird.away ?? .infinity) - bird.come),
                      let pose = birdPose(place.segment, play: play, layout: layout, at: place.time) else { continue }
                items.append(SkyItem(kind: .bird(pose, lift, flap: time - bird.come), point: pose.point, hue: hue))
            }
        }
        return items
    }

    private func dotPoint(_ segment: FlightSegment, play: RoutePlay, layout: SkyLayout, time: TimeInterval) -> CGPoint? {
        switch segment.kind {
        case .fly(let leg, let duration):
            guard let line = layout.line(leg, agent: play.agent), !line.isEmpty else { return nil }
            let k = duration > 0 ? (time - segment.start) / duration : 1
            return line.dot(at: CGFloat(MagpieMotion.glide(k)))
        case .holdSeat(let seat, _):
            guard let line = layout.rowLine(seat), !line.isEmpty else { return nil }
            return line.dot(at: 1)
        case .holdHub:
            guard let line = layout.agentLine(play.agent), !line.isEmpty else { return nil }
            return line.dot(at: 1)
        }
    }

    private func birdPose(_ segment: FlightSegment, play: RoutePlay, layout: SkyLayout, at time: TimeInterval) -> MagpiePose? {
        switch segment.kind {
        case .fly(let leg, let duration):
            guard let line = layout.line(leg, agent: play.agent), !line.isEmpty else { return nil }
            let back: Bool = { switch leg { case .home, .bounce: return true; default: return false } }()
            return MagpiePose.of(line, elapsed: time - segment.start, duration: duration, leftward: back)
        case .holdHub:
            // 在 magpie 前等：停在去 magpie 那段的终点
            guard let line = layout.agentLine(play.agent), !line.isEmpty else { return nil }
            return MagpiePose.of(line, elapsed: RoutePlay.toHubTime, duration: RoutePlay.toHubTime, leftward: false)
        case .holdSeat:
            return nil
        }
    }

    private func draw(_ items: [SkyItem], in gc: inout GraphicsContext) {
        // 点先画，喜鹊在上（网页里点和喜鹊按出现的顺序叠，喜鹊总是刚衔起点时才出现）
        for item in items {
            guard case .dot(let style, let held) = item.kind else { continue }
            let radius: CGFloat = style == .answer ? 4 : 4.5
            let p = item.point
            let dot = Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
            var layer = gc
            if let held { layer.opacity = held }
            switch style {
            case .request:
                // .pkt：Agent 的颜色，drop-shadow(0 0 3px)
                var glow = layer
                glow.addFilter(.shadow(color: item.hue, radius: 3))
                glow.fill(dot, with: .color(item.hue))
            case .answer:
                layer.fill(dot, with: .color(RT.card))
                layer.stroke(dot, with: .color(item.hue), lineWidth: 2.25)
            case .error:
                layer.fill(dot, with: .color(item.hue))
                layer.stroke(dot, with: .color(RT.red), lineWidth: 2.25)
            }
        }
        for item in items {
            guard case .bird(let pose, let lift, let flap) = item.kind else { continue }
            MagpieFlier.draw(in: gc, pose: pose, lift: lift, flapTime: flap, ink: RT.fg, card: RT.card)
        }
    }
}

/// 舞台上各张卡片此刻的位置，以及沿线飞的路线（网页 wiresTo / via / home）。
private struct SkyLayout {
    let hub: CGRect
    let low: CGFloat
    private let agents: [String: CGRect]
    private let rows: [String: CGRect]

    @MainActor
    init?(anchors: [StageNode: Anchor<CGRect>], proxy: GeometryProxy) {
        guard let hubAnchor = anchors[.hub] else { return nil }
        hub = proxy[hubAnchor]
        low = anchors[.agents].map { proxy[$0].maxY } ?? proxy[hubAnchor].maxY
        var agents: [String: CGRect] = [:], rows: [String: CGRect] = [:]
        for (node, anchor) in anchors {
            switch node {
            case .agent(let id): agents[id] = proxy[anchor]
            case .row(let id): rows[id] = proxy[anchor]
            default: break
            }
        }
        self.agents = agents
        self.rows = rows
    }

    func agent(_ id: String) -> CGRect? { agents[id] }
    func row(_ id: String) -> CGRect? { rows[id] }

    func agentLine(_ id: String) -> FlightLine? { agents[id].map { FlightLine(Wires.agent($0, hub: hub)) } }
    func rowLine(_ seat: String) -> FlightLine? { rows[seat].map { FlightLine(Wires.row($0, hub: hub, agentsBottom: low)) } }

    private static func back(_ v: CGPoint) -> CGPoint { CGPoint(x: -v.x, y: -v.y) }

    /// 一段飞行的整条路线。
    func line(_ leg: FlightLeg, agent: String) -> FlightLine? {
        switch leg {
        case .toHub:
            return agentLine(agent)
        case .out(let seat, let from):
            guard let toRow = rowLine(seat), let rowStart = toRow.start else { return nil }
            var way = FlightLine()
            let a: CGPoint, heading: CGPoint
            switch from {
            case .agent, .hubFromAgent:
                guard let toHub = agentLine(agent), let end = toHub.end else { return nil }
                if from == .agent { way = toHub }
                a = end
                heading = toHub.endHeading
            case .hubFromSeat(let previous):
                guard let before = rowLine(previous), let start = before.start else { return nil }
                a = start
                heading = Self.back(before.startHeading)
            }
            way.append(FlightLine.via(from: a, heading: heading, to: rowStart, heading: toRow.startHeading, hub: hub))
            way.append(toRow)
            return way
        case .home(let seat):
            guard let toRow = rowLine(seat), let toHub = agentLine(agent), let rowStart = toRow.start, let hubEnd = toHub.end else { return nil }
            var way = toRow.reversed()
            way.append(FlightLine.via(from: rowStart, heading: Self.back(toRow.startHeading), to: hubEnd, heading: Self.back(toHub.endHeading), hub: hub))
            way.append(toHub.reversed())
            return way
        case .bounce(let seat):
            return rowLine(seat)?.reversed()
        }
    }
}

private struct AgentNode: View {
    let agent: StageAgent

    var body: some View {
        VStack(spacing: 2) {
            Text(String(agent.name.prefix(1)).uppercased())
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RT.hue(agent.id), in: .rect(cornerRadius: 7, style: .continuous))
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
    let mask: AccountMask?
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
                PII.text(row.status, mask)
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
            Image(systemName: seat.kind == "account" ? "person.crop.circle" : seat.kind == "provider" ? "shippingbox" : "key")
                .font(.system(size: 12)).foregroundStyle(RT.fg2)
            PII.text(seat.title, mask).font(.system(size: 13, weight: .medium)).foregroundStyle(RT.fg).lineLimit(1)
            if !seat.detail.isEmpty {
                PII.text(seat.detail, mask).font(.system(size: 13)).foregroundStyle(RT.muted).lineLimit(1)
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

/// 舞台下方最近的请求（网页舞台下的请求列表，网关保留最近 60 个）：默认只列最新的 10 个，点「显示全部」展开；
/// 可按会话分组（网页「按请求 / 按会话」，记住选择）。点一个，舞台改画那个请求；「回到实时」跟着最新的走。
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
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("最近的请求").font(.footnote.weight(.semibold)).foregroundStyle(RT.fg)
                if !all.isEmpty {
                    Text("网关保留的最近 \(all.count) 个").font(.caption2).foregroundStyle(RT.muted)
                }
                Spacer()
                if model.pinned != nil {
                    Button("回到实时") { model.pinned = nil }
                        .font(.footnote)
                        .accessibilityIdentifier("routes.live")
                }
            }
            .padding(.bottom, 6)
            if all.isEmpty {
                Text("还没有请求").font(.footnote).foregroundStyle(RT.muted)
            } else {
                Picker("分组", selection: $bySession) {
                    Text("按请求").tag(false)
                    Text("按会话").tag(true)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .padding(.bottom, 6)
                .accessibilityIdentifier("routes.bySession")
            }
            if bySession && routes.contains(where: { !$0.session.isEmpty }) {
                ForEach(sessions(routes), id: \.key) { group in
                    sessionHead(group, mask: mask)
                    if !closedSessions.contains(group.key) {
                        ForEach(group.routes) { route in row(route, mask: mask) }
                    }
                }
            } else {
                ForEach(routes) { route in
                    row(route, mask: mask)
                    if route.id != routes.last?.id { Divider().overlay(RT.line) }
                }
            }
            if all.count > Self.folded {
                Button {
                    withAnimation(.easeOut(duration: 0.25)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(expanded ? "收起" : "显示全部 \(all.count) 个")
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2)
                    }
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RT.fg2)
                .accessibilityIdentifier("routes.requests.more")
            }
        }
        .textRenderer(PIIRenderer())
    }

    private func row(_ route: TraceRoute, mask: AccountMask?) -> some View {
        Button {
            model.pinned = route.id == model.pinned ? nil : route.id
        } label: {
            RequestRow(route: route, agentName: agentName, selected: route.id == model.current?.id, mask: mask)
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

    private func sessionHead(_ group: SessionGroup, mask: AccountMask?) -> some View {
        let first = group.routes[0]
        let open = !closedSessions.contains(group.key)
        let title = group.routes.first { !$0.sessionTitle.isEmpty }?.sessionTitle ?? ""
        let folder = group.routes.first { !$0.folder.isEmpty }?.folder ?? ""
        let name = group.key.isEmpty ? "未提供会话标识"
            : [agentName(first.agent), folder, title.isEmpty && folder.isEmpty ? first.session : title].filter { !$0.isEmpty }.joined(separator: " · ")
        let tokens = group.routes.reduce(0) { $0 + $1.tokens }
        let running = group.routes.filter { !$0.done }.count
        var bits = ["\(group.routes.count) 个请求"]
        if tokens > 0 { bits.append("\(UsageFormat.tokens(tokens)) token") }
        if running > 0 { bits.append("\(running) 个进行中") }
        return Button {
            guard !group.key.isEmpty else { return }
            if open { closedSessions.insert(group.key) } else { closedSessions.remove(group.key) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if !group.key.isEmpty {
                    Text(open ? "▾" : "▸").font(.caption).foregroundStyle(RT.muted)
                }
                PII.text(name, mask).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(RT.fg).lineLimit(1)
                Spacer(minLength: 4)
                Text(bits.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(RT.muted).lineLimit(1)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(RT.card2, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .accessibilityIdentifier("routes.session")
    }
}

private struct RequestRow: View {
    let route: TraceRoute
    let agentName: (String) -> String
    let selected: Bool
    let mask: AccountMask?

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
                    (Text(verbatim: "→ ") + PII.text(target, mask)).font(.system(size: 12)).foregroundStyle(route.failed ? RT.red : RT.muted).lineLimit(1)
                    if route.rerouted > 0 { Text("改道 \(route.rerouted) 次").font(.system(size: 11)).foregroundStyle(RT.muted) }
                }
                if !route.sessionTitle.isEmpty {
                    PII.text(route.sessionTitle, mask).font(.system(size: 11)).foregroundStyle(RT.muted).lineLimit(1)
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
