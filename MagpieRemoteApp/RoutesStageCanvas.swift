import SwiftUI
import UIKit
import MagpieRemoteCore

// 舞台本身：Agent、magpie、账号 / Key 的行（与它们的标题、合并的行），线、喜鹊和它衔的点。
// 移植自 magpie 网页「路由」页（internal/gui/assets/plugins/routing/client.js 与 routing.css，MIT，Copyright (c) 2026 yetone）。

/// 天空里此刻的一样东西：一个点，或一只喜鹊。
struct SkyItem {
    enum Kind {
        case dot(FlightDot, held: Double?)
        case bird(MagpiePose, MagpieMotion.Lift, flap: TimeInterval)
    }

    var kind: Kind
    var point: CGPoint
    var hue: Color
    /// UI 测试用：喜鹊此刻在哪段路上（toHub＝Agent → magpie、out、home、bounce；停着时为 rest）。
    var leg = ""

    var isBird: Bool { if case .bird = kind { return true }; return false }
}

/// 节点、行与线。线、飞行的点和喜鹊都画在卡片下面（网页 .rt-sky z-index 0 在 .rt-node / .rt-accts 之下：
/// 「从卡片下面飞过，穿过 magpie 的框而不是压在它的字上」）。天空比舞台大一圈（网页 overflow: visible）：
/// 窄屏时喜鹊沿左边的车道往下飞，身子拖在车道左边，画布不能在舞台边上把它切掉。
struct StageCanvas: View {
    let stage: RouteStage
    let layout: StageLayout
    let model: RoutesLiveModel
    let reduceMotion: Bool
    let stillSky: Bool
    let mask: AccountMask?
    var gateway: String = ""
    let onPickRouting: () -> Void

    /// 天空超出舞台的余量：喜鹊约 38 点长，车道离舞台左边 10 点。
    private static let overflow: CGFloat = 44

    var body: some View {
        // 在 body 里读：演出一变就重画、重新决定要不要每帧画
        let plays = Array(model.plays.values).sorted { $0.route < $1.route }
        let flowing = stage.agents.contains(where: \.busy) || stage.rows.contains { $0.state == .answering }
        let animating = !stillSky && (!plays.isEmpty || flowing)
        // 卡片跳一下、行抖一下、红色标签（网页 tick() / rerun(row.li, "hit")）：演出里排好的时刻
        let agentTicks = Self.agentTicks(plays)
        let hubTicks = plays.flatMap { $0.ticks.filter { $0.node == .hub }.map(\.at) }.sorted()
        let hits = Dictionary(grouping: plays.flatMap(\.hits), by: \.seat).mapValues { $0.sorted { $0.at < $1.at } }
        // 减弱动态效果时没有这些（网页 prefers-reduced-motion: animation none），标签照样出现
        let moving = !plays.isEmpty && !stillSky
        // 喜鹊此刻在哪些项的路上（网页 render() 的 onWire：飞向一个座位起、到从那里飞回为止）
        let onWireItems: Set<String> = Set(plays.flatMap { play -> [String] in
            guard let segment = play.segment(at: RoutesClock.shared.now) else { return [] }
            switch segment.kind {
            case .fly(.out(let seat, _), _), .fly(.home(let seat), _), .fly(.bounce(let seat), _), .holdSeat(let seat, _):
                return layout.chains[seat] ?? []
            default: return []
            }
        })
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .center, spacing: 28) {
                VStack(spacing: 10) {
                    ForEach(stage.agents) { agent in
                        StageMotion(paused: !moving) { t in
                            AgentNode(agent: agent, many: stage.agents.count > 1).scaleEffect(moving ? MagpieMotion.tickScale(agentTicks[agent.id] ?? [], at: t) : 1)
                        }
                        .stageNode(.agent(agent.id))
                    }
                }
                .frame(maxWidth: .infinity)
                .stageNode(.agents)
                StageMotion(paused: !moving) { t in
                    HubNode(chip: stage.chip, chipHidden: stage.chipHidden, sub: gateway, action: onPickRouting)
                        .scaleEffect(moving ? MagpieMotion.tickScale(hubTicks, at: t) : 1)
                }
                .frame(maxWidth: .infinity)
                .stageNode(.hub)
            }
            VStack(spacing: 7) {
                ForEach(layout.items) { item in
                    let shown = hits.filter { layout.shown($0.key) == item.id }.values.flatMap { $0 }.sorted { $0.at < $1.at }
                    StageMotion(paused: shown.isEmpty || (RT.uiTesting && !RT.fliersInTests)) { t in
                        let hit = shown.last { $0.at <= t }
                        let tag = hit.flatMap { h in MagpieMotion.tagShown(t - h.at).map { (text: "\(h.status) · \(RouteStageBuilder.failWord(h.fail))", shown: $0) } }
                        itemView(item, tag: tag, onWire: onWireItems.contains(item.id))
                            .offset(x: stillSky ? 0 : MagpieMotion.hitOffset(hit.map { t - $0.at } ?? -1))
                    }
                    // 位置记的是缩进之后的那一块（网页 margin-left: depth × 18 不算在 li 的框里）
                    .stageNode(.row(item.id))
                    .padding(.leading, CGFloat(item.depth) * 18)
                }
                if layout.items.isEmpty {
                    Text(stage.mode.isEmpty ? "没有可用的账号" : RouteWords.t("No request yet"))
                        .font(.system(size: 13)).foregroundStyle(RT.muted)
                        .frame(maxWidth: .infinity).padding(9)
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(RT.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
            }
            .padding(.leading, 22)
            .animation(reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.5), value: layout.items.map(\.id))
        }
        .backgroundPreferenceValue(StageBoundsKey.self) { anchors in
            GeometryReader { proxy in
                TimelineView(.animation(paused: !animating || RoutesClock.frozen)) { context in
                    let sky = SkyLayout(anchors: anchors, proxy: proxy, stage: layout)
                    let time = RoutesClock.frozen ? RoutesClock.shared.now : context.date.timeIntervalSinceReferenceDate
                    let items = sky.map { self.sky(plays: plays, layout: $0, time: time) } ?? []
                    let pad = Self.overflow
                    ZStack(alignment: .topLeading) {
                        Canvas { gc, _ in
                            gc.translateBy(x: pad, y: pad)
                            if let sky { wires(in: &gc, layout: sky, plays: plays, time: time) }
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
                                    .accessibilityValue(item.leg)
                                    .accessibilityIdentifier("routes.flier")
                                    .position(item.point)
                            }
                            // 量到了几张 Agent 卡片、几行（Agent → magpie 的线要靠这些位置才画得出来）
                            Color.clear.frame(width: 6, height: 6)
                                .contentShape(.rect)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("线")
                                .accessibilityValue(Text(verbatim: Self.measured(sky, stage)))
                                .accessibilityIdentifier("routes.wires")
                        }
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func itemView(_ item: StageItem, tag: (text: String, shown: Double)?, onWire: Bool) -> some View {
        switch item.kind {
        case .row:
            if let row = item.row {
                SeatRow(row: row, reduceMotion: reduceMotion, mask: mask, flightTag: tag)
                    .accessibilityIdentifier("routes.row.\(row.seat.id)")
            }
        case .heading:
            HeadingRow(item: item, mask: mask, tag: tag, onWire: onWire) { model.toggleFold(item) }
                .accessibilityIdentifier("routes.heading")
        case .fold:
            FoldRow(item: item, mask: mask, tag: tag, onWire: onWire, reduceMotion: reduceMotion) { model.toggleFold(item) }
                .accessibilityIdentifier("routes.fold")
        }
    }

    /// 「agents=all rows=3」：每张 Agent 卡片都量到了位置时是 all，否则「量到的/应有的」。
    private static func measured(_ layout: SkyLayout?, _ stage: RouteStage) -> String {
        let got = layout?.agentCount ?? 0
        let agents = got > 0 && got >= stage.agents.count ? "all" : "\(got)/\(stage.agents.count)"
        return "agents=\(agents) rows=\(layout?.rowCount ?? 0)"
    }

    /// 喜鹊所在那段路的名字（只给 UI 测试看）。from agent 的去程也是从 Agent 的线起飞。
    private static func legName(_ segment: FlightSegment) -> String {
        guard case .fly(let leg, _) = segment.kind else { return "rest" }
        switch leg {
        case .toHub: return "toHub"
        case .out(_, let from): return from == .agent ? "toHub" : "out"
        case .home: return "home"
        case .bounce: return "bounce"
        }
    }

    /// 每个 Agent 的卡片跳一下的时刻（按先后）。
    private static func agentTicks(_ plays: [RoutePlay]) -> [String: [TimeInterval]] {
        var out: [String: [TimeInterval]] = [:]
        for play in plays {
            for tick in play.ticks where tick.node == .agent { out[play.agent, default: []].append(tick.at) }
        }
        return out.mapValues { $0.sorted() }
    }

    /// 线：默认灰；有请求在路上（或点正在它上面飞）时按 Agent 的颜色虚线流动；回答完亮着不动；休息中的虚线变淡。
    private func wires(in gc: inout GraphicsContext, layout: SkyLayout, plays: [RoutePlay], time: TimeInterval) {
        // 0.7 秒流 8 点（@keyframes rtflow { to { stroke-dashoffset: -8 } }）：虚线顺着线的方向往前走
        // （Agent → magpie → 座位）。dashPhase 与 stroke-dashoffset 同义，这里取 0…8 里等价的正值。
        let flow = stillSky ? 0 : CGFloat(time.truncatingRemainder(dividingBy: 0.7) / 0.7) * 8
        let phase = flow == 0 ? 0 : 8 - flow
        // 网页 render()：点在线上飞的 Agent 也算在发
        // 网页 render() 的 onWire：从飞向一个座位起、到从那里飞回为止（去程、在座位等回答、回程、退回 magpie），
        // 那一行的线一直在流动、用这个 Agent 的颜色，它的 Agent 也算在发
        var onWire = Set<String>()
        var seatOnWire: [String: String] = [:]
        for play in plays {
            guard let segment = play.segment(at: time) else { continue }
            switch segment.kind {
            case .fly(let leg, _):
                onWire.insert(play.agent)
                switch leg {
                case .out(let seat, _), .home(let seat), .bounce(let seat): seatOnWire[seat] = play.agent
                case .toHub: break
                }
            case .holdSeat(let seat, _):
                onWire.insert(play.agent)
                seatOnWire[seat] = play.agent
            case .holdHub:
                break
            }
        }
        // 网页：流动的线是 .rt-flows 里的副本，那一层在所有 .rt-wires 之上（原来的那条 .flown 藏起来）；
        // 其余的线按先后画在 .rt-wires 里。所以先画不动的，再画流动的——车道是几条线共用的，后画的灰线不能盖住流动的那条。
        var live: [(Path, Color)] = []
        for agent in stage.agents {
            guard let rect = layout.agent(agent.id) else { continue }
            let path = Wires.agent(rect, hub: layout.hub)
            if agent.busy || onWire.contains(agent.id) {
                live.append((path, RT.hue(agent.id)))
            } else {
                gc.stroke(path, with: .color(RT.line), lineWidth: 1.5)
            }
        }
        // 每一项的线：从 magpie 下来，或从它所在的子组 / 展开的合并行的小车道下来（网页 fromHub / fromSub）
        let rowsByID = Dictionary(uniqueKeysWithValues: stage.rows.map { ($0.id, $0) })
        for item in self.layout.items {
            guard let path = layout.wire(item.id) else { continue }
            if let row = item.row {
                let hue = row.agent.map(RT.hue) ?? RT.muted
                if row.state != .resting, row.state != .answering, let by = seatOnWire[row.id] {
                    live.append((path, RT.hue(by)))
                    continue
                }
                switch row.state {
                case .answering:
                    live.append((path, hue))
                case .answered:
                    gc.stroke(path, with: .color(hue), lineWidth: 1.5)
                case .resting, .passedOver:
                    gc.stroke(path, with: .color(RT.line.opacity(0.45)), style: StrokeStyle(lineWidth: 1.5, dash: [2, 6]))
                case .idle:
                    gc.stroke(path, with: .color(RT.line), lineWidth: 1.5)
                }
                continue
            }
            // 标题 / 合并的行：下面有一行在答时流动、答完亮着，颜色是那一行的（网页 lightRow + tint）
            let lit = item.seats.compactMap { rowsByID[$0] }
            let by = item.seats.compactMap { seatOnWire[$0] }.first
            let litRow = lit.first { $0.state == .answering } ?? lit.first { $0.state == .answered }
            if let by, !(lit.contains { $0.state == .answering }) {
                live.append((path, RT.hue(by)))
            } else if let litRow, litRow.state == .answering || by != nil {
                live.append((path, litRow.agent.map(RT.hue) ?? RT.muted))
            } else if let litRow {
                gc.stroke(path, with: .color(litRow.agent.map(RT.hue) ?? RT.muted), lineWidth: 1.5)
            } else if item.resting {
                gc.stroke(path, with: .color(RT.line.opacity(0.45)), style: StrokeStyle(lineWidth: 1.5, dash: [2, 6]))
            } else {
                gc.stroke(path, with: .color(RT.line), lineWidth: 1.5)
            }
        }
        for (path, color) in live {
            gc.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: [3, 5], dashPhase: phase))
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
                    // @keyframes rtheld 1.2s ease-in-out infinite：50% 时 opacity .45（每半段 ease-in-out）
                    let q = (time - segment.start).truncatingRemainder(dividingBy: 1.2) / 1.2
                    held = MagpieMotion.keyframes([(0, 1), (0.5, 0.45), (1, 1)], q, timing: .easeInOut)
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
                items.append(SkyItem(kind: .bird(pose, lift, flap: time - bird.come), point: pose.point, hue: hue,
                                     leg: Self.legName(place.segment)))
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
        // 按网页 .rt-sky 里元素的先后叠：每个请求先是它的点，再是衔着它的喜鹊（packet() 先于 bird()），后来的请求在上面
        for item in items {
            switch item.kind {
            case .dot(let style, let held):
                let radius: CGFloat = style == .answer ? 4 : 4.5
                let p = item.point
                let dot = Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
                var layer = gc
                if let held { layer.opacity = held }
                // .pkt：每种点都有 drop-shadow(0 0 3px var(--agent))——CSS 的模糊半径 3 = 高斯 σ 1.5
                layer.drawLayer { ctx in
                    ctx.addFilter(.shadow(color: item.hue, radius: 1.5))
                    switch style {
                    case .request:
                        ctx.fill(dot, with: .color(item.hue))
                    case .answer:
                        // .pkt.back：卡片色填充、Agent 色的圈（stroke-width 2.25）
                        ctx.fill(dot, with: .color(RT.card))
                        ctx.stroke(dot, with: .color(item.hue), lineWidth: 2.25)
                    case .error:
                        // .pkt.back.err：Agent 色填充、红圈（半径仍是 4.5）
                        ctx.fill(dot, with: .color(item.hue))
                        ctx.stroke(dot, with: .color(RT.red), lineWidth: 2.25)
                    }
                }
            case .bird(let pose, let lift, let flap):
                MagpieFlier.draw(in: gc, pose: pose, lift: lift, flapTime: flap, ink: RT.fg, card: RT.card)
            }
        }
    }
}

/// 随时间变的一小块（卡片跳一下、行抖一下）：平时跟着屏幕刷新，逐帧截图时跟着 RoutesClock。
struct StageMotion<Content: View>: View {
    let paused: Bool
    @ViewBuilder let content: (TimeInterval) -> Content

    var body: some View {
        TimelineView(.animation(paused: paused || RoutesClock.frozen)) { context in
            content(RoutesClock.frozen ? RoutesClock.shared.now : context.date.timeIntervalSinceReferenceDate)
        }
    }
}

/// 逐帧截图（`--routes-snapshot`）用的「下一帧」：放在「路由」分区标题里（舞台之外，不进截图）。它的 label / value
/// 是已经画好的那一刻（毫秒），UI 测试等它跟上再截。不放导航栏：导航栏按钮在 iOS 26 上不带 accessibilityValue。
struct RoutesSnapshotStep: View {
    var body: some View {
        let clock = RoutesClock.shared
        Button {
            clock.advance()
        } label: {
            Text(verbatim: "下一帧 \(clock.settledMilliseconds)").font(.caption.monospacedDigit())
        }
        .accessibilityIdentifier("routes.snapshot.step")
        .accessibilityLabel(Text(verbatim: "下一帧 \(clock.settledMilliseconds)"))
        .accessibilityValue(Text(verbatim: "\(clock.settledMilliseconds)"))
    }
}

/// 舞台上各张卡片此刻的位置，以及沿线飞的路线（网页 wiresTo / via / home）。
struct SkyLayout {
    let hub: CGRect
    let low: CGFloat
    private let agents: [String: CGRect]
    private let rows: [String: CGRect]
    private let stage: StageLayout
    private let parents: [String: String]

    @MainActor
    init?(anchors: [StageNode: Anchor<CGRect>], proxy: GeometryProxy, stage: StageLayout) {
        self.stage = stage
        parents = Dictionary(uniqueKeysWithValues: stage.items.compactMap { item in item.parent.map { (item.id, $0) } })
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
    var agentCount: Int { agents.count }
    var rowCount: Int { rows.count }
    func row(_ id: String) -> CGRect? { rows[id] }

    func agentLine(_ id: String) -> FlightLine? { agents[id].map { FlightLine(Wires.agent($0, hub: hub)) } }

    /// 一项自己的线：从 magpie 下来，或从它挂着的那一项的小车道下来（网页 layout() 的 fromHub / fromSub）。
    func wire(_ item: String) -> Path? {
        guard let rect = rows[item] else { return nil }
        if let parent = parents[item], let up = rows[parent] { return Wires.sub(up, to: rect) }
        return Wires.row(rect, hub: hub, agentsBottom: low)
    }

    /// 从 magpie 到一个座位的整条路（网页 wiresTo(shownRow)）：经过的标题、展开的合并行，再是它自己；折起的到折起的那一项为止。
    func rowLine(_ seat: String) -> FlightLine? {
        let chain = stage.chains[seat] ?? [seat]
        var line = FlightLine()
        for id in chain {
            guard let path = wire(id) else { return nil }
            line.append(FlightLine(path))
        }
        return line.isEmpty ? nil : line
    }

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

struct AgentNode: View {
    let agent: StageAgent
    /// 台上不止一个 Agent（网页 .rt-srcs.many）：卡片紧一点（padding 8 8 7）、标志 20。
    var many = false

    var body: some View {
        let icon: CGFloat = many ? 20 : 26
        // routing.css .rt-node：flex 列、gap 2；字是 line-height 1.4（13px → 18.2、11px → 15.4）。
        // 标志在一行 14px 的字里（.rt-ic 是行内的 inline-flex，margin-bottom 3）：那一块高 = 标志 + 3 + 3.6。
        VStack(spacing: 2) {
            Group {
                // 网页 .rt-src 的 .rt-ic：Agent 的官方图标；认不出的 Agent 用首字母方块。
                if BrandIcon.isBrand(OfficialIcon.agent(agent.id)) {
                    BrandIcon(OfficialIcon.agent(agent.id), size: icon).foregroundStyle(RT.fg).frame(width: icon, height: icon)
                } else {
                    Text(String(agent.name.prefix(1)).uppercased())
                        .font(.system(size: many ? 11 : 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: icon, height: icon)
                        .background(RT.hue(agent.id), in: .rect(cornerRadius: 7, style: .continuous))
                }
            }
            .frame(height: icon + 6.6, alignment: .top)
            // .rt-src b::before：名字前 7px 的 Agent 色圆点，右边留 6px
            HStack(spacing: 6) {
                Circle().fill(RT.hue(agent.id)).frame(width: 7, height: 7).padding(.top, 1)
                Text(agent.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(RT.fg).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 18.2)
            Text(agent.sub.isEmpty ? "Agent" : agent.sub).font(.system(size: 11)).foregroundStyle(RT.muted).lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .frame(height: 15.4)
        }
        .padding(.horizontal, 8)
        .padding(.top, many ? 8 : 12)
        .padding(.bottom, many ? 7 : 10)
        .frame(maxWidth: .infinity)
        .background(RT.card, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(RT.line))
        .accessibilityElement(children: .combine)
        .accessibilityValue(agent.busy ? "正在发送" : "")
    }
}

/// 中间的 magpie：黑框外再一圈浅色描边，下方小胶囊是路由方式（点它看路由组设置）。
struct HubNode: View {
    let chip: String
    let chipHidden: Bool
    /// 网页 hubText()：网关地址（去掉 http://），没有时是「网关」；放不下时截断。
    var sub: String = ""
    let action: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            // routing.css：svg.rt-bird 26×26 + margin-bottom 3；b 13px、small 11px、胶囊 10.5px，都是 line-height 1.4
            MagpieLogo().fill(RT.fg, style: FillStyle(eoFill: true)).frame(width: 26, height: 26).padding(.bottom, 3)
            Text("magpie").font(.system(size: 13, weight: .semibold)).foregroundStyle(RT.fg).frame(height: 18.2)
            Text(sub.isEmpty ? RouteWords.t("gateway") : sub).font(.system(size: 11)).foregroundStyle(RT.muted)
                .lineLimit(1).truncationMode(.tail).frame(height: 15.4)
            if !chipHidden {
                Button(action: action) {
                    // .rt-go::after { content: " ›" }：点它去改路由方式
                    Text(chip + " ›")
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                        .frame(height: 14.7)
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
struct SeatRow: View {
    let row: StageRow
    let reduceMotion: Bool
    let mask: AccountMask?
    /// 失败落在这里时的红色标签（网页 play()：`${status} · ${failWord}`，li.tagged 1.8 秒）与它显示了多少（0…1）。
    var flightTag: (text: String, shown: Double)?
    @State private var pulse = false

    private var dimmed: Double {
        switch row.state {
        case .resting: 0.5
        case .passedOver: 0.45
        default: 1
        }
    }

    var body: some View {
        // routing.css .rt-accts li：grid 10px | 1fr，column-gap 10、row-gap 6，padding 9 12；
        // 第一行（b）高 20.5（16px 的标志 vertical-align -3px 撑高了 13px/1.4 的行），第二行 em 12px/1.4 = 16.8；
        // 圆点在第一行里垂直居中。
        HStack(alignment: .top, spacing: 10) {
            dot.frame(height: 20.5)
            VStack(alignment: .leading, spacing: 6) {
                title.frame(height: 20.5)
                // 窄屏（.rt-accts.max560 em）：一句状态 white-space: normal，放不下就换行，不出框
                PII.text(row.status, mask)
                    .font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(statusColor)
                    .opacity(row.state == .resting ? 0.85 / dimmed : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 16.8, alignment: .leading)
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RT.card, in: .rect(cornerRadius: 10, style: .continuous))
        // 网页 li 只有边框颜色（.3s）和位置（.5s）有过渡；字、点、透明度都是立刻换的
        .overlay(border.animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: row.state))
        .overlay(alignment: .topTrailing) {
            // .rt-accts .tag：right 10px; top -10px; padding 1px 7px; radius 6; 红底白字 600 10.5px 等宽；
            // 没显示时 opacity 0、translateY(4px) scale(.9)，.tagged 时复原（.25s）
            if let tag = flightTag {
                Text(tag.text)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(RT.red, in: .rect(cornerRadius: 6))
                    .scaleEffect(0.9 + 0.1 * tag.shown)
                    .offset(x: -10, y: -10 + 4 * (1 - tag.shown))
                    .opacity(tag.shown)
            }
        }
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
        // 网页 makeRow()：标志（16×16，右边 7px）、名字（560）、空格、灰色补充、模型（margin-left 7、11px 等宽、卡片 2 色底）、
        // 快速 / 备用。整个 b 是一行：overflow hidden、text-overflow ellipsis、nowrap——放不下时从末尾截断，后面的不再画。
        return InlineLine {
            Group {
                if BrandIcon.isBrand(seat.officialIcon) {
                    BrandIcon(seat.officialIcon, size: 16).foregroundStyle(RT.fg)
                } else {
                    // 网页认不出的供应商用 generic（一个盒子）
                    Image(systemName: "shippingbox").font(.system(size: 12)).foregroundStyle(RT.fg2)
                        .frame(width: 16, height: 16)
                }
            }
            .padding(.trailing, 7)
            PII.text(seat.title, mask).font(.system(size: 13, weight: .medium)).foregroundStyle(RT.fg)
            if !seat.detail.isEmpty {
                PII.text(" " + seat.detail, mask).font(.system(size: 13)).foregroundStyle(RT.muted)
            }
            Text(seat.modelLabel)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(RT.fg2)
                .padding(.horizontal, 5).background(RT.card2, in: .rect(cornerRadius: 5))
                .padding(.leading, seat.detail.isEmpty ? 7 + 3.6 : 7)
            if seat.fast { badge(RouteWords.t("fast")).padding(.leading, 6) }
            if seat.fallback { badge(RouteWords.t("fallback")).padding(.leading, 6) }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .clipped()
    }

    func badge(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(RT.muted)
            .padding(.horizontal, 6)
            .overlay(Capsule().strokeBorder(RT.line))
    }
}


/// 网页里一行字的 `overflow: hidden; text-overflow: ellipsis; white-space: nowrap`：几段排成一行，按各自想要的宽度，
/// 放不下时跨过边的那一段用剩下的宽度（文字自己截断加省略号），后面的不再画——不会挤在一起、叠在一起或伸出框外。
struct InlineLine: Layout {
    /// 跨过边的那一段至少要这么宽才画（再窄就只剩一个省略号，不如不画）。
    static let minPiece: CGFloat = 14

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.reduce(CGFloat(0)) { $0 + $1.sizeThatFits(.unspecified).width }
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: min(ideal, proposal.width ?? ideal), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var done = false
        for v in subviews {
            let want = v.sizeThatFits(.unspecified)
            let left = bounds.maxX - x
            if done || left < Self.minPiece && want.width > left {
                // 放不下：放到框外看不见的地方，宽 0
                v.place(at: CGPoint(x: bounds.maxX + 10_000, y: bounds.midY), anchor: .leading, proposal: .zero)
                done = true
                continue
            }
            let w = min(want.width, left)
            v.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: w, height: want.height))
            x += w
            if w < want.width { done = true }
        }
    }
}

/// 网页 FAN（app.js）：一个模型分到几家，路由组的标志。16×16 的线稿。
struct FanShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 16
        var p = Path()
        for (x, y) in [(2.9, 8.0), (13.1, 3.4), (13.1, 8.0), (13.1, 12.6)] {
            p.addEllipse(in: CGRect(x: (x - 1.4) * s, y: (y - 1.4) * s, width: 2.8 * s, height: 2.8 * s))
        }
        p.move(to: CGPoint(x: 4.3 * s, y: 8 * s)); p.addLine(to: CGPoint(x: 11.7 * s, y: 8 * s))
        p.move(to: CGPoint(x: 4.3 * s, y: 8 * s))
        p.addCurve(to: CGPoint(x: 10.1 * s, y: 3.4 * s), control1: CGPoint(x: 6.9 * s, y: 8 * s), control2: CGPoint(x: 7.5 * s, y: 3.4 * s))
        p.addLine(to: CGPoint(x: 11.7 * s, y: 3.4 * s))
        p.move(to: CGPoint(x: 4.3 * s, y: 8 * s))
        p.addCurve(to: CGPoint(x: 10.1 * s, y: 12.6 * s), control1: CGPoint(x: 6.9 * s, y: 8 * s), control2: CGPoint(x: 7.5 * s, y: 12.6 * s))
        p.addLine(to: CGPoint(x: 11.7 * s, y: 12.6 * s))
        return p.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// 网页 CHEV（app.js `m5.5 6.5 2.5 2.5 2.5-2.5`）：向下的小箭头，展开时转 180°。
struct ChevronShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 16
        var p = Path()
        p.move(to: CGPoint(x: 5.5 * s, y: 6.5 * s))
        p.addLine(to: CGPoint(x: 8 * s, y: 9 * s))
        p.addLine(to: CGPoint(x: 10.5 * s, y: 6.5 * s))
        return p.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// 红色的失败标签（网页 .rt-accts .tag），挂在行、标题或合并的行右上角。
struct FlightTagView: View {
    let tag: (text: String, shown: Double)

    var body: some View {
        Text(tag.text)
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(RT.red, in: .rect(cornerRadius: 6))
            .scaleEffect(0.9 + 0.1 * tag.shown)
            .offset(x: -10, y: -10 + 4 * (1 - tag.shown))
            .opacity(tag.shown)
            .allowsHitTesting(false)
    }
}

/// 一条路由或组里一个子组的标题（网页 li.rt-sub）：标志、名字、地址、折起时「启用 N 个」、路由方式、箭头；
/// 折起时下一行是它下面的一起怎样了。点它折起 / 展开。
struct HeadingRow: View {
    let item: StageItem
    let mask: AccountMask?
    let tag: (text: String, shown: Double)?
    let onWire: Bool
    let toggle: () -> Void

    var body: some View {
        let on = item.lit || onWire
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Group {
                        if item.route, let w = item.iconOf {
                            if BrandIcon.isBrand(w.officialIcon) { BrandIcon(w.officialIcon, size: 14).foregroundStyle(RT.fg) }
                            else { Image(systemName: "shippingbox").font(.system(size: 11)).foregroundStyle(RT.fg2).frame(width: 14, height: 14) }
                        } else {
                            FanShape().stroke(RT.fg2, style: StrokeStyle(lineWidth: 1.5 * 14 / 16, lineCap: .round, lineJoin: .round))
                                .frame(width: 14, height: 14)
                        }
                    }
                    InlineLine {
                        PII.text(item.name, mask).font(.system(size: 12, weight: .medium)).foregroundStyle(RT.fg).padding(.trailing, 7)
                        Text(item.ref).font(.system(size: 11, design: .monospaced)).foregroundStyle(RT.fg2)
                            .padding(.horizontal, 5).background(RT.card2, in: .rect(cornerRadius: 5)).padding(.trailing, 7)
                        if !item.count.isEmpty { Text(item.count).font(.system(size: 12)).foregroundStyle(on ? RT.fg : RT.muted) }
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .clipped()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !item.mode.isEmpty {
                        Text(item.mode).font(.system(size: 10.5, weight: .medium)).foregroundStyle(RT.fg2).lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 1)
                            .overlay(Capsule().strokeBorder(RT.line))
                            .fixedSize()
                    }
                    ChevronShape().stroke(RT.muted, style: StrokeStyle(lineWidth: 1.7 * 12 / 16, lineCap: .round, lineJoin: .round))
                        .frame(width: 12, height: 12)
                        .rotationEffect(.degrees(item.open ? 180 : 0))
                        .animation(.easeInOut(duration: 0.2), value: item.open)
                }
                if !item.open && !item.status.isEmpty {
                    PII.text(item.status, mask).font(.system(size: 12)).foregroundStyle(on ? RT.fg : RT.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 21)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RT.card2, in: .rect(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(on ? RT.fg2 : RT.line, style: StrokeStyle(lineWidth: 1, dash: on ? [] : [4, 3])))
            .opacity(item.resting ? 0.5 : 1)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) { if let tag { FlightTagView(tag: tag) } }
        .accessibilityLabel(Text(verbatim: [item.name, item.ref, item.count, item.mode].filter { !$0.isEmpty }.joined(separator: "，")))
        .accessibilityValue(Text(verbatim: item.open ? "已展开" : item.status))
        .accessibilityHint(Text(verbatim: [item.tip, item.foldHint].filter { !$0.isEmpty }.joined(separator: "。")))
    }
}

/// 合在一起的 Key / 账号（网页 li.rt-fold）：点、名字、「N 个密钥」、模型、箭头；下一行是它们一起怎样了。展开时卡片 2 色底。
struct FoldRow: View {
    let item: StageItem
    let mask: AccountMask?
    let tag: (text: String, shown: Double)?
    let onWire: Bool
    let reduceMotion: Bool
    let toggle: () -> Void

    var body: some View {
        let on = item.lit || onWire
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 10) {
                Circle().strokeBorder(on ? RT.fg : RT.muted, lineWidth: 1.5)
                    .background(Circle().fill(on ? RT.fg : .clear))
                    .frame(width: 8, height: 8).frame(width: 10, height: 20.5)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        InlineLine {
                            Group {
                                if let w = item.iconOf, BrandIcon.isBrand(w.officialIcon) { BrandIcon(w.officialIcon, size: 16).foregroundStyle(RT.fg) }
                                else { Image(systemName: "shippingbox").font(.system(size: 12)).foregroundStyle(RT.fg2).frame(width: 16, height: 16) }
                            }
                            .padding(.trailing, 7)
                            PII.text(item.name, mask).font(.system(size: 13, weight: .medium)).foregroundStyle(RT.fg)
                            Text(" " + item.count).font(.system(size: 13)).foregroundStyle(RT.muted)
                            Text(item.ref).font(.system(size: 11, design: .monospaced)).foregroundStyle(RT.fg2)
                                .padding(.horizontal, 5).background(RT.card2, in: .rect(cornerRadius: 5)).padding(.leading, 7)
                            if item.fallback {
                                Text(RouteWords.t("fallback")).font(.system(size: 10.5, weight: .medium)).foregroundStyle(RT.muted)
                                    .padding(.horizontal, 6).overlay(Capsule().strokeBorder(RT.line)).padding(.leading, 6)
                            }
                        }
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .clipped()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 20.5)
                        ChevronShape().stroke(RT.muted, style: StrokeStyle(lineWidth: 1.7 * 12 / 16, lineCap: .round, lineJoin: .round))
                            .frame(width: 12, height: 12)
                            .rotationEffect(.degrees(item.open ? 180 : 0))
                            .animation(.easeInOut(duration: 0.2), value: item.open)
                    }
                    if !item.status.isEmpty {
                        PII.text(item.status, mask).font(.system(size: 12)).monospacedDigit().foregroundStyle(on ? RT.fg : RT.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .opacity(item.resting ? 0.5 : 1)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(item.open ? RT.card2 : RT.card, in: .rect(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(on ? RT.fg : RT.line, style: StrokeStyle(lineWidth: 1, dash: item.resting ? [4, 3] : []))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: on))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) { if let tag { FlightTagView(tag: tag) } }
        .accessibilityLabel(Text(verbatim: [item.name, item.count, item.ref].joined(separator: "，")))
        .accessibilityValue(Text(verbatim: item.status))
        .accessibilityHint(Text(verbatim: item.foldHint))
    }
}
