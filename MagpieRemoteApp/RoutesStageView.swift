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
    // app.css :root 与 prefers-color-scheme: dark 里的值，一个不差
    static let line = dynamic(0xE3E3E8, 0x333339)
    static let fg = dynamic(0x1C1C21, 0xEDEDF1)
    static let fg2 = dynamic(0x4B4B53, 0xB9B9C1)
    static let muted = dynamic(0x85858D, 0x8B8B94)
    static let card = dynamic(0xFFFFFF, 0x232327)
    static let card2 = dynamic(0xF9F9FB, 0x1F1F23)
    static let red = dynamic(0xD64545, 0xF28B82)
    static let green = dynamic(0x189A58, 0x6FD99B)
    static let faint = dynamic(0xB9B9C2, 0x56565F)
    static let accent = dynamic(0x4F46E5, 0xA5B4FC)
    static let ctlFg = dynamic(0x63636B, 0xA1A1AA)
    static let lineSoft = dynamic(0xECECF0, 0x2C2C32)

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

enum StageNode: Hashable {
    case agent(String), hub, agents, row(String)
}

struct StageBoundsKey: PreferenceKey {
    static let defaultValue: [StageNode: Anchor<CGRect>] = [:]
    static func reduce(value: inout [StageNode: Anchor<CGRect>], nextValue: () -> [StageNode: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// 记下这块的位置。用 transform：外层（.agents）记自己时不能把里面各张 Agent 卡片记的位置盖掉
    /// （anchorPreference 会用自己的值替换子视图的值——这样 Agent 的线、飞向 magpie 的路线全都没了）。
    func stageNode(_ node: StageNode) -> some View {
        transformAnchorPreference(key: StageBoundsKey.self, value: .bounds) { $0[node] = $1 }
    }
}

/// 网页 layout() 的线：Agent → magpie 是一段横向贝塞尔；magpie → 每行沿左侧走一条「车道」。
enum Wires {
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

    /// 网页 fromSub()：组里的子组、展开的合并行，下面的每一项从它左边中间往下走一条小车道。
    static func sub(_ s: CGRect, to a: CGRect) -> Path {
        var p = Path()
        let x = s.minX + 9
        p.move(to: CGPoint(x: s.minX, y: s.midY))
        p.addQuadCurve(to: CGPoint(x: x, y: s.midY + 9), control: CGPoint(x: x, y: s.midY))
        p.addLine(to: CGPoint(x: x, y: a.midY - 9))
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

/// 实时路由的卡片（网页 section.rt）：上面一句「谁 · 路由组 · 启用 N 个」和路由方式；重放时的重放条；舞台；
/// 下面那句话和计数；再下面「最近一个请求是怎么路由的」（重放、从这里重放、回到实时、查看用量）。
struct RoutesStageView: View {
    let model: RoutesLiveModel
    let agentName: (String) -> String
    /// magpie 方框里的小字（网页 hubText：网关地址，没有时是「网关」）。
    var gateway: String = ""
    var onPickRouting: ((TraceRoute) -> Void)?
    /// 「查看用量」（网页 openUsageRoute）。
    var onViewUsage: ((TraceRoute) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// 行上的动画（跳动的点、行的移动）：UI 测试时不放。
    private var reduceMotion: Bool { systemReduceMotion || RT.uiTesting }
    /// 喜鹊与流动的线：系统「减弱动态效果」时不飞（网页 still()）；UI 测试时只有 `--routes-fliers` 才飞。
    private var stillSky: Bool { systemReduceMotion || (RT.uiTesting && !RT.fliersInTests) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.phase {
            case .idle, .loading:
                off("正在读取网关的路由…")
            case .notServing:
                off(RouteWords.t("The gateway isn't running, so nothing is routed."))
            case .failed(let error):
                off(error.localizedDescription)
            case .live:
                // 倒计时（休息到几点、几小时后重置）与「刚结束的请求在台上留 12 秒」每秒走一次（网页 countdown()）
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let date = model.stageNow(RoutesClock.frozen ? RoutesClock.shared.date : context.date)
                    VStack(alignment: .leading, spacing: 0) {
                        if let route = model.current {
                            let mask = model.mask(agentName: agentName)
                            let staged = model.staged(now: date)
                            let built = RouteStageBuilder.build(current: route, staged: staged, now: date, order: model.agentOrder, agentName: agentName)
                            stage(built, routes: [route] + staged, route: route, mask: mask)
                        } else {
                            empty()
                        }
                    }
                }
            }
        }
        // .rt：padding 14 16 12，圆角 14，卡片底、1 像素边
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(RT.card, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(RT.line))
        .textRenderer(PIIRenderer())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("routes.stage")
        .onAppear { model.still = systemReduceMotion; model.agentName = agentName }
        .onChange(of: systemReduceMotion) { _, still in model.still = still }
    }

    /// 网页 .rt-off：网关看不了时舞台的位置只有一句灰字（padding 18 4，居中，13px）。
    private func off(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(RT.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .padding(.horizontal, 4)
            .accessibilityIdentifier("routes.off")
    }

    /// 标题：组名或供应商名 · 路由组 · 启用 N 个；下面一句话说路由方式（网页 header()）。
    private func header(name: String, tail: String, mode: String, mask: AccountMask?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            (PII.text(name, mask).fontWeight(.semibold).foregroundStyle(RT.fg) + PII.text(tail, mask).foregroundStyle(RT.muted))
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            if !mode.isEmpty {
                PII.text(mode, mask).font(.system(size: 12.5)).foregroundStyle(RT.fg2).lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func stage(_ stage: RouteStage, routes: [TraceRoute], route: TraceRoute, mask: AccountMask?) -> some View {
        header(name: stage.name, tail: stage.tail, mode: stage.mode, mask: mask)
        if let replay = model.replay {
            ReplayBar(model: model, replay: replay, agentName: agentName, mask: mask)
        }
        let layout = RouteStageBuilder.layout(stage, routes: routes, memory: model.folds, agentName: agentName)
        StageCanvas(stage: stage, layout: layout, model: model, reduceMotion: reduceMotion, stillSky: stillSky, mask: mask,
                    gateway: gateway, onPickRouting: { onPickRouting?(route) })
            .padding(.vertical, 16)
        foot(mask: mask)
        StoryLog(model: model, route: model.pinned.flatMap { model.book.routes[$0] } ?? route, agentName: agentName, mask: mask,
                 onViewUsage: onViewUsage)
    }

    /// 网页 empty()：还没有请求时，台上是「你的 Agent」、magpie 和一行虚线框「还没有请求」。
    @ViewBuilder
    private func empty() -> some View {
        header(name: RouteWords.t("Waiting for a request"), tail: "",
               mode: RouteWords.t("Send one from any agent routed through magpie and it plays here as it happens: who routing put first and why, each try, and what each answered."),
               mask: nil)
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .center, spacing: 28) {
                AgentNode(agent: StageAgent(id: "", name: RouteWords.t("your agent"), busy: false, hue: "#85858d", sub: ""))
                    .frame(maxWidth: .infinity)
                HubNode(chip: "", chipHidden: true, sub: gateway, action: {}).frame(maxWidth: .infinity)
            }
            Text(RouteWords.t("No request yet"))
                .font(.system(size: 13)).foregroundStyle(RT.muted)
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(RT.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .padding(.leading, 22)
        }
        .padding(.vertical, 16)
        Divider().overlay(RT.line)
        Text(RouteWords.t("Every request an agent sends to magpie shows up here, routed for real."))
            .font(.system(size: 13)).foregroundStyle(RT.fg)
            .frame(maxWidth: .infinity, minHeight: 37.7, alignment: .leading)
            .padding(.top, 10)
            .accessibilityIdentifier("routes.caption")
        stats
    }

    /// 底部：那句话（网页 .rt-cap：min-height 3em，新的一句从下方 4 点淡入 0.4 秒）与计数。
    private func foot(mask: AccountMask?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(RT.line)
            let line = model.caption.shown
            PII.text(line, mask)
                .font(.system(size: 13)).foregroundStyle(RT.fg)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 37.7, alignment: .leading)
                .id(model.caption.serial)
                .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 4)))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: model.caption.serial)
                .accessibilityIdentifier("routes.caption")
            stats
        }
    }

    /// 计数（网页 .rt-stats：19px 650、11px 灰字，间隔 14）；「Agent 收到的错误」点一下看最近失败的那个。
    private var stats: some View {
        let totals = model.book.totals
        let failed = model.latestFailed
        return HStack(spacing: 14) {
            stat(totals.requests, RouteWords.t("requests"))
            stat(totals.rerouted, RouteWords.t("rerouted"))
            Button {
                if let failed { model.pick(failed) }
            } label: {
                stat(totals.errors, RouteWords.t("errors your agent saw"), red: totals.errors > 0)
            }
            .buttonStyle(.plain)
            .disabled(failed == nil)
            .accessibilityHint(RouteWords.t(failed != nil ? "Show the latest request that failed" : "No failed request in this list"))
            .accessibilityIdentifier("routes.errors")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(RouteWords.t("Counts since the gateway started"))
        .accessibilityIdentifier("routes.stats")
    }

    private func stat(_ value: Int, _ label: String, red: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)").font(.system(size: 19, weight: .semibold)).monospacedDigit().foregroundStyle(red ? RT.red : RT.fg)
                .tracking(-0.38)
            Text(label).font(.system(size: 11)).foregroundStyle(RT.muted)
        }
    }
}

// MARK: 重放条

/// 网页 .rt-replay：重放中 · 钟（时:分:秒.十分之一）· 哪天 · 跳过空闲时段；速度、停止；此刻在路上的请求；轨道（点一下跳过去）。
private struct ReplayBar: View {
    let model: RoutesLiveModel
    let replay: RouteReplay
    let agentName: (String) -> String
    let mask: AccountMask?

    var body: some View {
        let (time, fast) = replay.realAt(replay.v)
        let shown = replay.shown(playing: Set(model.plays.keys))
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(RT.accent).frame(width: 7, height: 7)
                    Text(RouteWords.t("Replaying")).font(.system(size: 11, weight: .semibold)).foregroundStyle(RT.muted)
                }
                Text(Self.clock(time)).font(.system(size: 22, weight: .semibold)).monospacedDigit().foregroundStyle(RT.fg).tracking(-0.44)
                Text(Self.day(time)).font(.system(size: 11)).foregroundStyle(RT.muted)
                let skip = replay.skipText(fast)
                if !skip.isEmpty { Text(skip).font(.system(size: 11)).foregroundStyle(RT.accent).lineLimit(1) }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button(replay.speedText) { model.cycleReplaySpeed() }
                    .accessibilityIdentifier("routes.replay.speed")
                Button(RouteWords.t("Stop replay")) { model.endReplay(stop: true) }
                    .accessibilityIdentifier("routes.replay.stop")
            }
            .buttonStyle(TextButtonStyle())
            VStack(alignment: .leading, spacing: 3) {
                if shown.entries.isEmpty {
                    Text(RouteWords.t("starting…")).font(.system(size: 12)).foregroundStyle(RT.faint)
                }
                ForEach(shown.entries, id: \.route.id) { e in
                    let r = model.replayRoutes[e.route.id] ?? e.route
                    let on = shown.on.contains(e.route.id)
                    Button { model.showInReplay(e.route.id) } label: {
                        HStack(spacing: 6) {
                            Text(RouteWords.t("request {i} of {n}", ["i": "\(e.n)", "n": "\(replay.plan.count)"]))
                                .monospacedDigit().foregroundStyle(on ? RT.fg : RT.muted)
                            Circle().fill(RT.hue(r.agent)).frame(width: 8, height: 8)
                            Text(agentName(r.agent)).fontWeight(.semibold).foregroundStyle(RT.fg).lineLimit(1)
                            Text(r.model).font(.system(size: 11, design: .monospaced)).foregroundStyle(RT.fg2)
                                .padding(.horizontal, 5).background(RT.card2, in: .rect(cornerRadius: 5)).lineLimit(1)
                            (Text(verbatim: "→ ") + PII.text(RouteStory.outcome(r).said, mask)).foregroundStyle(RT.muted)
                                .lineLimit(1).truncationMode(.tail)
                                .layoutPriority(-1)
                        }
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(minHeight: 20, alignment: .top)
            ReplayTrack(replay: replay, on: shown.on) { model.seekReplay($0) }
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 10)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(RT.line))
        .padding(.top, 10).padding(.bottom, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("routes.replay")
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let tenth = Int((d.timeIntervalSince1970 * 10).truncatingRemainder(dividingBy: 10))
        return f.string(from: d) + ".\(max(0, tenth))"
    }

    static func day(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return RouteWords.t("today") }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE"
        return f.string(from: d)
    }
}

/// 网页 .rp-track：一条 2 点的线，每个请求一个小竖条（Agent 的颜色，正在路上的亮、高一倍半），播放头；点哪里从哪里放。
private struct ReplayTrack: View {
    let replay: RouteReplay
    let on: Set<Int64>
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Capsule().fill(RT.line).frame(height: 2).offset(y: 7)
                ForEach(replay.plan, id: \.route.id) { e in
                    let lit = on.contains(e.route.id)
                    RoundedRectangle(cornerRadius: 1.5).fill(RT.hue(e.route.agent))
                        .frame(width: 3, height: 8)
                        .scaleEffect(x: 1, y: lit ? 1.5 : 1)
                        .opacity(lit ? 1 : 0.45)
                        .animation(.easeOut(duration: 0.2), value: lit)
                        .offset(x: geo.size.width * replay.mark(e) - 1.5, y: 4)
                }
                RoundedRectangle(cornerRadius: 1).fill(RT.fg).frame(width: 2, height: 14)
                    .offset(x: geo.size.width * replay.progress - 1, y: 1)
            }
            .contentShape(.rect)
            .onTapGesture(coordinateSpace: .local) { p in seek(p.x / max(1, geo.size.width)) }
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityLabel(RouteWords.t("Replaying"))
        .accessibilityValue("\(Int(replay.progress * 100))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: seek(min(1, replay.progress + 0.1))
            case .decrement: seek(max(0, replay.progress - 0.1))
            @unknown default: break
            }
        }
    }
}

/// 网页 button.text：12px、控件灰、padding 3 7、圆角 6。
struct TextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(RT.ctlFg)
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(configuration.isPressed ? RT.card2 : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
    }
}

// MARK: 这个请求是怎么路由的

/// 网页 .rt-log：标题（最近一个 / 某时刻的请求是怎么路由的）、查看用量、重放、从这里重放、回到实时；下面一步一句（最高 200，可滚）。
private struct StoryLog: View {
    let model: RoutesLiveModel
    let route: TraceRoute
    let agentName: (String) -> String
    let mask: AccountMask?
    var onViewUsage: ((TraceRoute) -> Void)?

    var body: some View {
        let pinned = model.pinned != nil
        let replaying = model.replay != nil
        let on = model.book.list.filter { $0.id >= route.id }
        let title = replaying || pinned ? RouteWords.t("How the request at {time} was routed", ["time": RouteStory.clockText(route.time)])
            : RouteWords.t("How the last request was routed")
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(RT.line)
            // .rt-log-head：flex-wrap，12px 600；按钮是 button.text
            FlowRow(spacing: 0, lineSpacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(RT.fg)
                    .padding(.trailing, 6)
                    .accessibilityIdentifier("routes.log.title")
                if !replaying && route.done {
                    if let onViewUsage {
                        Button(RouteWords.t("View usage")) { onViewUsage(route) }.accessibilityIdentifier("routes.usage")
                    }
                    Button(RouteWords.t("Replay")) { model.startReplay([route], back: model.pinned) }
                        .accessibilityIdentifier("routes.replay.one")
                    if pinned && on.count > 1 {
                        Button(RouteWords.t("Replay from here")) { model.startReplay(on, back: model.pinned) }
                            .accessibilityIdentifier("routes.replay.from")
                    }
                }
                if pinned && !replaying {
                    Button(RouteWords.t("Back to live")) { model.backToLive() }
                        .accessibilityIdentifier("routes.live")
                }
            }
            .buttonStyle(TextButtonStyle())
            .padding(.top, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(RouteStory.steps(route, agentName: agentName).enumerated()), id: \.offset) { _, step in
                        StepLine(step: step, mask: mask)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 200)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
            .accessibilityIdentifier("routes.steps")
        }
        .padding(.top, 10)
    }
}

/// 网页 .rt-steps li：左边 6 点的圆点（why 深色、ok 绿、bad 红、wait 灰且向外扩散、aside 空心小圈），12.5px / 1.45。
private struct StepLine: View {
    let step: RouteStory.Step
    let mask: AccountMask?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            dot.frame(width: 20, alignment: .leading)
            PII.text(step.text, mask)
                .font(step.kind == .said ? .system(size: 11.5, design: .monospaced) : .system(size: 12.5))
                .foregroundStyle(color)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var color: Color {
        switch step.kind {
        case .why: RT.fg
        case .aside, .said: RT.muted
        default: RT.fg2
        }
    }

    @ViewBuilder private var dot: some View {
        switch step.kind {
        case .aside, .said:
            Circle().strokeBorder(RT.muted, lineWidth: 1).frame(width: 6, height: 6).padding(.leading, 5)
        default:
            Circle().fill(step.kind == .why ? RT.fg : step.kind == .ok ? RT.green : step.kind == .bad ? RT.red : RT.muted)
                .frame(width: 6, height: 6).padding(.leading, 5)
        }
    }
}

/// 一行排不下就换行的一排（网页 flex-wrap）。
struct FlowRow: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            let w = min(s.width, width)
            if x > 0 && x + w > width { y += line + lineSpacing; x = 0; line = 0 }
            x += w + spacing
            line = max(line, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            let w = min(s.width, bounds.width)
            if x > 0 && x + w > bounds.width { y += line + lineSpacing; x = 0; line = 0 }
            v.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(width: w, height: s.height))
            x += w + spacing
            line = max(line, s.height)
        }
    }
}
