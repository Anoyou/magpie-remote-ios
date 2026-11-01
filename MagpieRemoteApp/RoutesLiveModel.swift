import Foundation
import Observation
import MagpieRemoteCore

/// 实时路由：长轮询 `GET /api/gateway/trace?after=<seq>&wait=1`（与 magpie 网页 `poll()` 相同：第一次不等，
/// 之后每次挂起最多 25 秒、网关把一阵变化攒 250 毫秒一起回答），把增量合并进 `TraceBook`，
/// 并按网页 `play()` 给每个请求排一段喜鹊的演出（`RoutePlay`）。页面不在屏幕上时停止；回来后只有还在路上的接着飞。
/// 还管：舞台下那句话的队列（网页 say / capQ）、重放（网页 replay）、舞台上折叠的行记住的开合。
@MainActor
@Observable
final class RoutesLiveModel {
    enum Phase: Equatable {
        case idle
        case loading
        case live
        /// 主机上的这台 magpie 没有在提供网关（网页同样显示「网关没有运行」）。
        case notServing
        case failed(MagpieError)
    }

    private(set) var phase: Phase = .idle
    private(set) var book = TraceBook()
    /// 正在演的请求（网页 `playing`）。
    private(set) var plays: [Int64: RoutePlay] = [:]
    /// 用户点选的请求；nil = 跟着实时走。
    var pinned: Int64? {
        didSet {
            guard pinned != oldValue else { return }
            // 网页 pick()：选了一个就只画它，飞着的结束（stopPlays）；回到实时时接着飞还在路上的
            plays = [:]
            if pinned == nil { replayUnderWay() }
            syncAgentOrder()
            if let current { sayLead(current) }
        }
    }
    /// 「账号打码」（网页 #rtMask，与「用量」共用 magpie.maskEmails）。
    var masked: Bool {
        didSet { if Self.persists { UserDefaults.standard.set(masked ? "1" : "0", forKey: Self.maskKey) } }
    }
    /// 舞台上折叠的行（网页 keysOpen / keysShut，localStorage 同名）。
    private(set) var folds: StageFoldMemory
    /// 舞台下的那句话（网页 .rt-cap 与 capQ）。
    private(set) var caption = CaptionQueue()
    /// 正在重放（网页 rp）。
    private(set) var replay: RouteReplay?
    /// 重放里此刻的请求（网页 rp.routes）。
    private(set) var replayRoutes: [Int64: TraceRoute] = [:]
    /// 重放里卡片讲的那个（网页 rp 时的 cur）。
    private var replayCurrent: Int64?
    /// 台上 Agent 卡片的先后（网页 rebuild()：已在台上的不挪，新来的排后面）。每次读完、演完一个时更新。
    private(set) var agentOrder: [String] = []
    /// 卡片讲的请求（网页 `told()`）。
    private var toldID: Int64?
    private var task: Task<Void, Never>?
    private var prune: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    /// 页面刚回来：下一次读到的只让还在路上的飞（网页 resume / `caught`）。
    private var resuming = true
    /// 每段演出已经交给说话队列的句数，和还没到时候的句子。
    @ObservationIgnored private var saidCount: [Int64: Int] = [:]
    @ObservationIgnored private var dueSays: [(at: TimeInterval, route: Int64, say: FlightSay)] = []
    @ObservationIgnored private var leadFor: Int64?
    @ObservationIgnored private var lastTick: TimeInterval = 0

    static let maskKey = "magpie.maskEmails"
    static let foldsOpenKey = "magpie.routingKeysOpen"
    static let foldsShutKey = "magpie.routingFolded"
    /// UI 测试不读写，保证每次都从「不打码」、默认开合开始。
    private static let persists = !ProcessInfo.processInfo.arguments.contains("--ui-testing")

    init() {
        masked = Self.persists && UserDefaults.standard.string(forKey: Self.maskKey) == "1"
        func set(_ key: String) -> Set<String> {
            guard Self.persists, let data = UserDefaults.standard.string(forKey: key)?.data(using: .utf8),
                  let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return Set(list)
        }
        folds = StageFoldMemory(opened: set(Self.foldsOpenKey), shut: set(Self.foldsShutKey))
    }

    /// 舞台演的请求从哪里来：重放时是重放里的，平时是网关的。
    var routes: [Int64: TraceRoute] { replay != nil ? replayRoutes : book.routes }

    var current: TraceRoute? {
        if replay != nil {
            if let id = replayCurrent, let route = replayRoutes[id] { return route }
            return replayRoutes.values.max { $0.id < $1.id }
        }
        if let pinned, let route = book.routes[pinned] { return route }
        if let toldID, let route = book.routes[toldID] { return route }
        return book.newest
    }

    /// 舞台上的「此刻」：重放时是重放的钟（网页 now() 在 rp 时是 rp.real）。
    func stageNow(_ date: Date) -> Date {
        guard let replay else { return date }
        return replay.realAt(replay.v).time
    }

    /// 与卡片讲的那个一起上台的请求（网页 `staged()`，不含 current）：正在飞的、每个 Agent 还在路上或刚结束 12 秒内的最后一个，
    /// 最多 4 个 Agent；选中一个时只画它。重放时是重放里正在飞的。
    func staged(now: Date = RoutesClock.shared.date) -> [TraceRoute] {
        if replay != nil {
            var out = replayRoutes.values.filter { plays[$0.id] != nil && $0.id != current?.id }.sorted { $0.id < $1.id }
            var agents: [String] = [current?.agent].compactMap { $0 }
            for r in out where !agents.contains(r.agent) { agents.append(r.agent) }
            let kept = Set(agents.suffix(4))
            out = out.filter { kept.contains($0.agent) }
            return out
        }
        return book.staged(current: current, pinned: pinned != nil, playing: Set(plays.keys), now: now).filter { $0.id != current?.id }
    }

    /// 打码规则：见过的账号；供应商与 Agent 的名字不算。
    func mask(agentName: (String) -> String) -> AccountMask? {
        guard masked else { return nil }
        var not: [String] = []
        for route in book.routes.values {
            not.append(route.agent)
            not.append(agentName(route.agent))
            not.append(route.provider)
            for seat in route.order { not.append(seat.provider); not.append(seat.name) }
        }
        return AccountMask(accounts: book.accounts, notNames: not)
    }

    // MARK: 折叠

    /// 网页 toggleSub / toggleFold：点标题或合并的行。
    func toggleFold(_ item: StageItem) {
        folds.keep(item.persistKey, open: !item.open)
        guard Self.persists else { return }
        func save(_ set: Set<String>, _ key: String) {
            if let data = try? JSONEncoder().encode(set.sorted()), let text = String(data: data, encoding: .utf8) {
                UserDefaults.standard.set(text, forKey: key)
            }
        }
        save(folds.opened, Self.foldsOpenKey)
        save(folds.shut, Self.foldsShutKey)
    }

    // MARK: 选一个 / 回到实时

    /// 网页 pick(r)：点列表里的一个请求。点最新的一个就是回到实时。
    func pick(_ route: TraceRoute) {
        if replay != nil { endReplay(stop: true, toLive: true) }
        pinned = route.id == book.newest?.id ? nil : route.id
        if pinned == nil, let current { sayLead(current) }
    }

    /// 网页「回到实时」。
    func backToLive() {
        if replay != nil { endReplay(stop: true, toLive: true) }
        pinned = nil
    }

    /// 网页 stats 的「Agent 收到的错误」：看最近一个失败的请求。
    var latestFailed: TraceRoute? { book.list.first(where: RouteStory.failed) }

    // MARK: 重放

    /// 网页 replay(list, back)：把这些请求（只有结束了的）按当时的样子再演一遍。
    func startReplay(_ list: [TraceRoute], back: Int64?) {
        guard var next = RouteReplay(list, back: back, speed: replay?.speed ?? 1) else { return }
        next.back = back
        plays = [:]
        saidCount = [:]
        dueSays = []
        replayRoutes = [:]
        replayCurrent = nil
        replay = next
        lastTick = RoutesClock.shared.now
        wakeTicker()
    }

    func cycleReplaySpeed() { replay?.nextSpeed() }

    /// 网页 seek：从轨道上点的地方接着放（飞着的结束，那时还在路上的从那里接着飞）。
    func seekReplay(_ fraction: Double) {
        guard var replay else { return }
        replay.seek(fraction)
        plays = [:]
        saidCount = [:]
        dueSays = []
        replayRoutes = replay.routes
        self.replay = replay
        let t = RoutesClock.shared.now
        for route in replayRoutes.values.sorted(by: { $0.id < $1.id }) where !route.done {
            plays[route.id] = RoutePlay(route: route, now: t, still: still)
        }
        replayCurrent = replayRoutes.keys.max()
        advance(at: t)
    }

    /// 重放条上点一个请求：卡片讲它（网页 row.onclick = () => { cur = r; renderLog() }）。
    func showInReplay(_ id: Int64) { replayCurrent = id }

    /// 网页 endReplay(stop)：回到选中的那个（重放前选了的话），否则回到实时。
    func endReplay(stop: Bool = true, toLive: Bool = false) {
        guard let replay else { return }
        self.replay = nil
        replayRoutes = [:]
        replayCurrent = nil
        if stop { plays = [:] }
        saidCount = [:]
        dueSays = []
        let back = toLive ? nil : replay.back.flatMap { book.routes[$0] != nil ? $0 : nil }
        if pinned != back { pinned = back } else {
            plays = [:]
            if pinned == nil { replayUnderWay() }
            syncAgentOrder()
            if let current { sayLead(current) }
        }
    }

    /// 重放一帧（网页 step(ts)）。
    private func stepReplay(now t: TimeInterval) {
        guard var replay else { return }
        replay.step(t - lastTick)
        var moved = false
        for e in replay.plan where e.start <= replay.v {
            let was = replayRoutes[e.route.id]
            let ghost = RouteReplay.ghost(e, at: replay.v)
            if let was, Self.same(was, ghost) { continue }
            replayRoutes[e.route.id] = ghost
            moved = true
            if was == nil {
                plays[e.route.id] = RoutePlay(route: ghost, now: t, still: still)
                replayCurrent = e.route.id
            }
        }
        self.replay = replay
        if moved {
            advance(at: t)
            syncAgentOrder()
        }
        if replay.finished(playing: !plays.isEmpty) { endReplay(stop: false) }
    }

    private static func same(_ a: TraceRoute, _ b: TraceRoute) -> Bool {
        a.done == b.done && a.tries.count == b.tries.count && zip(a.tries, b.tries).allSatisfy { $0.done == $1.done }
    }

    // MARK: 舞台下那句话

    /// 网页 sync 后的 `say(affWhy || ruleWhy || firstWhy)`。
    private func sayLead(_ route: TraceRoute) {
        leadFor = route.id
        caption.say(RouteStory.lead(route))
        wakeTicker()
    }

    /// 把演出里新排的句子交给说话队列：到时候的马上说，没到的等。
    private func collectSays(now t: TimeInterval) {
        for (id, play) in plays {
            let had = saidCount[id] ?? 0
            guard play.says.count > had else { continue }
            for say in play.says[had...] { dueSays.append((say.at, id, say)) }
            saidCount[id] = play.says.count
        }
        dueSays.sort { $0.at < $1.at }
        feedSays(now: t)
    }

    private func feedSays(now t: TimeInterval) {
        while let first = dueSays.first, first.at <= t {
            dueSays.removeFirst()
            guard let route = routes[first.route] else { continue }
            if let i = first.say.attempt {
                guard route.tries.indices.contains(i) else { continue }
                caption.say(RouteStory.trySaid(route, i, agentName: agentName), lo: first.say.lo)
            } else if route.id == current?.id, leadFor != route.id {
                leadFor = route.id
                caption.say(RouteStory.lead(route))
            }
        }
    }

    /// 说 Agent 名字用的（由页面给，见 ManageGroupsView）。
    @ObservationIgnored var agentName: (String) -> String = { $0 }

    /// 重放、说话队列都要一帧一帧地走：有事做时才走（网页 busy() 时才 requestAnimationFrame）。
    private func wakeTicker() {
        guard ticker == nil else { return }
        lastTick = RoutesClock.shared.now
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(RoutesClock.frozen ? 10 : 16))
                guard let self, !Task.isCancelled else { return }
                let t = RoutesClock.shared.now
                if self.replay != nil { self.stepReplay(now: t) }
                self.feedSays(now: t)
                // 只在该换句时动它：每帧都写会让整张卡片每帧重画
                if let due = self.caption.due, t > due { self.caption.tick(now: t) }
                self.lastTick = t
                if self.replay == nil && self.dueSays.isEmpty && !self.caption.pending {
                    self.ticker = nil
                    return
                }
            }
        }
    }

    // MARK: 读网关

    func start(service: (any ManageServing)?) {
        guard task == nil, let service else { return }
        if phase == .idle { phase = .loading }
        resuming = true
        task = Task { [weak self] in await self?.poll(service) }
    }

    func stop() {
        task?.cancel()
        task = nil
        prune?.cancel()
        prune = nil
        // 网页 pause()：看不见时什么都不飞，重放结束，回来后按当时的样子重画
        if replay != nil { endReplay(stop: true) }
        plays = [:]
        saidCount = [:]
        dueSays = []
    }

    private func poll(_ service: any ManageServing) async {
        while !Task.isCancelled {
            do {
                let snapshot = try await service.trace(after: book.seq, wait: book.loaded)
                if Task.isCancelled { return }
                let wasLoaded = book.loaded
                book.apply(snapshot)
                if !snapshot.mine {
                    phase = .notServing
                    if replay == nil { plays = [:] }
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }
                // 另一台 magpie 接管了网关：马上从头读
                if !book.loaded { continue }
                phase = .live
                if let id = pinned, book.routes[id] == nil { pinned = nil }
                let told = book.told(toldID)?.id
                let changed = told != toldID
                toldID = told
                if replay == nil {
                    schedule(first: !wasLoaded)
                    if (!wasLoaded || changed), pinned == nil, let current, leadFor != current.id, plays[current.id] == nil { sayLead(current) }
                }
                if RoutesClock.frozen { RoutesClock.shared.settle(step: RoutesClock.shared.currentStep) }
            } catch {
                let error = MagpieError.from(error)
                if error == .cancelled || Task.isCancelled { return }
                // 网页 poll 出错时只是 3 秒后再读，舞台照旧；从没读到过时才说连不上
                if !book.loaded { phase = .failed(error) }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var now: TimeInterval { RoutesClock.shared.now }
    /// 系统「减弱动态效果」（网页 still()）：飞行瞬间完成、不画喜鹊。由舞台告诉模型。
    var still = false

    /// 新请求开演；已经在演的按网关的新记录接着排；第一次读到或刚回到页面时只演还在路上的（最多 4 个）。
    private func schedule(first: Bool) {
        let t = now
        if pinned == nil {
            if first || resuming {
                for route in book.playable where plays[route.id] == nil { plays[route.id] = RoutePlay(route: route, now: t, still: still) }
            } else {
                for id in book.fresh { if plays[id] == nil, let route = book.routes[id] { plays[id] = RoutePlay(route: route, now: t, still: still) } }
            }
        }
        resuming = false
        advance(at: t)
        syncAgentOrder()
    }

    /// 按此刻台上的请求更新 Agent 卡片的先后。
    func syncAgentOrder() {
        guard let current else { return }
        let next = RouteStageBuilder.agentOrder(previous: agentOrder, routes: [current] + staged())
        if next != agentOrder { agentOrder = next }
    }

    private func replayUnderWay() {
        guard book.loaded, replay == nil else { return }
        let t = now
        for route in book.playable where plays[route.id] == nil { plays[route.id] = RoutePlay(route: route, now: t, still: still) }
        advance(at: t)
    }

    private func advance(at t: TimeInterval) {
        let source = routes
        for (id, var play) in plays {
            let route = source[id]
            play.advance(route, now: t) { seat in route?.order.contains { $0.key == seat } ?? false }
            plays[id] = play
        }
        collectSays(now: t)
        plays = plays.filter { ($0.value.over ?? .infinity) > t }
        schedulePrune()
        wakeTicker()
    }

    /// 最后一只喜鹊飞走后把演完的拿掉，舞台不再要帧（网页 busy() 为假时不再 requestAnimationFrame）。
    private func schedulePrune() {
        prune?.cancel()
        guard let next = plays.values.compactMap(\.over).min() else { return }
        let wait = max(0.05, next - now + 0.05)
        prune = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            let t = self.now
            self.plays = self.plays.filter { ($0.value.over ?? .infinity) > t }
            self.syncAgentOrder()
            self.schedulePrune()
        }
    }
}
