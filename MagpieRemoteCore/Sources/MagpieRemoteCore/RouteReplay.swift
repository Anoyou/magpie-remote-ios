import Foundation

// 重放（网页 client.js 的 replay / ghost / realAt / step / seek / replayBar）：把网关留下的请求按当时的样子再演一遍——
// 每个在它的时刻出发，每次尝试用它当时用的时间，舞台上的 Agent、账号、休息和那句话都是当时的。
// 等得比 GAP（1.8 秒）久的地方只等 GAP，所以一分钟的回答、一小时的空闲不会拖住它；舞台上方的钟仍走真实的时间，
// 跳过的地方走得快。magpie 以 MIT 许可发布（Copyright (c) 2026 yetone）。

public struct RouteReplay: Hashable, Sendable {
    public static let gap: TimeInterval = 1.8
    public static let lead: TimeInterval = 0.5

    public struct Entry: Hashable, Sendable {
        public var route: TraceRoute
        /// 第几个（从 1 起）。
        public var n: Int
        /// 在重放里开始 / 结束的时刻（秒）。
        public var start: TimeInterval
        public var end: TimeInterval
        public var tries: [(start: TimeInterval, end: TimeInterval)]

        public static func == (a: Entry, b: Entry) -> Bool {
            a.route == b.route && a.n == b.n && a.start == b.start && a.end == b.end
                && a.tries.map(\.start) == b.tries.map(\.start) && a.tries.map(\.end) == b.tries.map(\.end)
        }
        public func hash(into h: inout Hasher) { h.combine(route.id); h.combine(n) }
    }

    public private(set) var plan: [Entry]
    /// 真实时刻（自 1970 起的秒）与它在重放里的时刻。
    private let ts: [TimeInterval]
    private let vs: [TimeInterval]
    public let total: TimeInterval
    /// 重放结束后回到的那个请求（网页 back：选中的那个）。
    public var back: Int64?
    /// 现在在重放里的哪里（从 −LEAD 起）。
    public var v: TimeInterval
    /// 1×、2×、4×、8×。
    public var speed: Double

    static func at(_ d: Date?) -> TimeInterval { d?.timeIntervalSince1970 ?? 0 }
    static func ends(_ r: TraceRoute) -> TimeInterval {
        var e = at(r.time) + Double(r.ms) / 1000
        for tr in r.tries { e = max(e, at(tr.start) + Double(tr.ms) / 1000) }
        return e
    }

    /// 网页 replay(list)：只放结束了的，按先后。没有可放的时为 nil。
    public init?(_ list: [TraceRoute], back: Int64? = nil, speed: Double = 1) {
        let done = list.filter(\.done).sorted { $0.id < $1.id }
        guard !done.isEmpty else { return nil }
        var all: [TimeInterval] = []
        for r in done {
            all.append(Self.at(r.time))
            all.append(Self.ends(r))
            for tr in r.tries { all.append(Self.at(tr.start)); all.append(Self.at(tr.start) + Double(tr.ms) / 1000) }
        }
        let ts = Array(Set(all)).sorted()
        var vs: [TimeInterval] = []
        var v: TimeInterval = 0
        for (i, x) in ts.enumerated() {
            if i > 0 { v += min(x - ts[i - 1], Self.gap) }
            vs.append(v)
        }
        let index = Dictionary(uniqueKeysWithValues: ts.enumerated().map { ($1, $0) })
        func vOf(_ x: TimeInterval) -> TimeInterval { vs[index[x] ?? 0] }
        plan = done.enumerated().map { i, r in
            Entry(route: r, n: i + 1, start: vOf(Self.at(r.time)), end: vOf(Self.ends(r)),
                  tries: r.tries.map { (vOf(Self.at($0.start)), vOf(Self.at($0.start) + Double($0.ms) / 1000)) })
        }
        self.ts = ts
        self.vs = vs
        total = v
        self.back = back
        self.v = -Self.lead
        self.speed = speed
    }

    /// 网页 ghost(g, v)：那个请求在重放 v 秒时的样子——还没开始的尝试不在，没结束的还在答。
    public static func ghost(_ e: Entry, at v: TimeInterval) -> TraceRoute {
        var r = e.route
        var tries: [TraceTry] = []
        for (i, tr) in e.route.tries.enumerated() {
            let x = e.tries[i]
            guard x.start <= v else { continue }
            if x.end <= v { tries.append(tr) } else {
                var open = tr
                open.done = false
                open.status = 0
                open.rest = nil
                open.again = 0
                tries.append(open)
            }
        }
        r.tries = tries
        r.done = e.end <= v
        if !r.done { r.status = 0; r.ms = 0 }
        return r
    }

    /// 此刻重放里的每个请求（已经开始的）。
    public func routes(at v: TimeInterval) -> [Int64: TraceRoute] {
        var out: [Int64: TraceRoute] = [:]
        for e in plan where e.start <= v { out[e.route.id] = Self.ghost(e, at: v) }
        return out
    }
    public var routes: [Int64: TraceRoute] { routes(at: v) }

    /// 网页 realAt(v)：重放 v 秒时是真实的几点，那里比真实时间快几倍（跳过空闲时 > 1）。
    public func realAt(_ v: TimeInterval) -> (time: Date, fast: Double) {
        guard let first = ts.first else { return (Date(), 1) }
        if v <= 0 { return (Date(timeIntervalSince1970: first + v), 1) }
        for k in 1..<max(1, ts.count) where k < ts.count {
            if v > vs[k] { continue }
            let dv = vs[k] - vs[k - 1], dt = ts[k] - ts[k - 1]
            return (Date(timeIntervalSince1970: dv > 0 ? ts[k - 1] + (v - vs[k - 1]) * dt / dv : ts[k]), dv > 0 ? dt / dv : 1)
        }
        return (Date(timeIntervalSince1970: ts[ts.count - 1]), 1)
    }

    /// 网页 step()：往前走一帧（帧间隔最多算 250 毫秒：看不见时它等着）。
    public mutating func step(_ dt: TimeInterval) { v += min(dt, 0.25) * speed }

    /// 网页 rSpeed：1× → 2× → 4× → 8× → 1×。
    public mutating func nextSpeed() { speed = speed >= 8 ? 1 : speed * 2 }

    /// 网页 seek(frac)：从轨道上点的地方接着放。
    public mutating func seek(_ fraction: Double) { v = max(0, min(1, fraction)) * total }

    public var progress: Double { max(0, min(1, v / (total > 0 ? total : 1))) }
    /// 每个请求在轨道上的位置（0…1）。
    public func mark(_ e: Entry) -> Double { e.start / (total > 0 ? total : 1) }

    /// 演完了（网页：v > total 且没有在飞的）。
    public func finished(playing: Bool) -> Bool { v > total && !playing }

    /// 网页 replayBar 的那句「跳过空闲时段 · 时钟 N×」。
    public func skipText(_ fast: Double) -> String {
        fast > 1.5 ? rt("skipping a quiet stretch · clock {n}×", ["n": "\(Int(fast.rounded()))"]) : ""
    }
    public var speedText: String { rt("{n}× speed", ["n": speed == speed.rounded() ? "\(Int(speed))" : "\(speed)"]) }

    /// 此刻在路上的（没有就是最后一个开始了的）——重放条上列它们（网页 replayBar 的 shown_）。
    public func shown(playing: Set<Int64>) -> (entries: [Entry], on: Set<Int64>) {
        let routes = self.routes
        let on = plan.filter { playing.contains($0.route.id) || (routes[$0.route.id].map { !$0.done } ?? false) }
        let ids = Set(on.map(\.route.id))
        if !on.isEmpty { return (on, ids) }
        return (plan.filter { routes[$0.route.id] != nil }.suffix(1).map { $0 }, ids)
    }
}

// MARK: 舞台下的那句话

/// 网页 say() / show() / frame() 的说话队列：一句至少讲 1.7 秒（不重要的一句后面跟着重要的时 0.5 秒），
/// 不重要的一句（lo）在有句子排着时不说；来了重要的就把排着的不重要的去掉；最多排 3 句。
public struct CaptionQueue: Hashable, Sendable {
    public struct Line: Hashable, Sendable {
        public var text: String
        public var lo: Bool
    }

    public private(set) var shown: String = ""
    public private(set) var shownLo = false
    /// 换上这句的时刻。
    public private(set) var at: TimeInterval = -.infinity
    private var queue: [Line] = []
    /// 换句计数：界面用它让新的一句淡入（网页 .rt-cap.in）。
    public private(set) var serial = 0

    public init() {}

    public mutating func say(_ text: String, lo: Bool = false) {
        guard !text.isEmpty else { return }
        if lo && !queue.isEmpty { return }
        if !lo { queue.removeAll(where: \.lo) }
        queue.append(Line(text: text, lo: lo))
        if queue.count > 3 { queue.removeFirst() }
    }

    /// 直接换上（页面看不见时网页就这样）。
    public mutating func show(_ text: String, now: TimeInterval) {
        queue = []
        shown = text
        shownLo = false
        at = now
        serial += 1
    }

    /// 每帧：时候到了就换下一句。返回换没换。
    @discardableResult
    public mutating func tick(now: TimeInterval) -> Bool {
        guard let next = queue.first else { return false }
        let wait: TimeInterval = shownLo && !next.lo ? 0.5 : 1.7
        guard now - at > wait else { return false }
        queue.removeFirst()
        shown = next.text
        shownLo = next.lo
        at = now
        serial += 1
        return true
    }

    /// 下一次可能换句的时刻（没有排着的时为 nil）。
    public var due: TimeInterval? {
        guard let next = queue.first else { return nil }
        return at + (shownLo && !next.lo ? 0.5 : 1.7)
    }
    public var pending: Bool { !queue.isEmpty }
}
