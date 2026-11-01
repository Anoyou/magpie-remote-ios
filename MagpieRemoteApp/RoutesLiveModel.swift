import Foundation
import Observation
import MagpieRemoteCore

/// 实时路由：长轮询 `GET /api/gateway/trace?after=<seq>&wait=1`（与 magpie 网页 `poll()` 相同：第一次不等，
/// 之后每次挂起最多 25 秒、网关把一阵变化攒 250 毫秒一起回答），把增量合并进 `TraceBook`，
/// 并按网页 `play()` 给每个请求排一段喜鹊的演出（`RoutePlay`）。页面不在屏幕上时停止；回来后只有还在路上的接着飞。
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
        }
    }
    /// 「账号打码」（网页 #rtMask，与「用量」共用 magpie.maskEmails）。
    var masked: Bool {
        didSet { if Self.persists { UserDefaults.standard.set(masked ? "1" : "0", forKey: Self.maskKey) } }
    }
    /// 卡片讲的请求（网页 `told()`）。
    private var toldID: Int64?
    private var task: Task<Void, Never>?
    private var prune: Task<Void, Never>?
    /// 页面刚回来：下一次读到的只让还在路上的飞（网页 resume / `caught`）。
    private var resuming = true

    static let maskKey = "magpie.maskEmails"
    /// UI 测试不读写，保证每次都从「不打码」开始。
    private static let persists = !ProcessInfo.processInfo.arguments.contains("--ui-testing")

    init() {
        masked = Self.persists && UserDefaults.standard.string(forKey: Self.maskKey) == "1"
    }

    var current: TraceRoute? {
        if let pinned, let route = book.routes[pinned] { return route }
        if let toldID, let route = book.routes[toldID] { return route }
        return book.newest
    }

    /// 与卡片讲的那个一起上台的请求（网页 `staged()`，不含 current）：正在飞的、每个 Agent 还在路上或刚结束 12 秒内的最后一个，
    /// 最多 4 个 Agent；选中一个时只画它。
    func staged(now: Date = RoutesClock.shared.date) -> [TraceRoute] {
        book.staged(current: current, pinned: pinned != nil, playing: Set(plays.keys), now: now).filter { $0.id != current?.id }
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
        // 网页 pause()：看不见时什么都不飞，回来后按当时的样子重画
        plays = [:]
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
                    plays = [:]
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }
                // 另一台 magpie 接管了网关：马上从头读
                if !book.loaded { continue }
                phase = .live
                if let id = pinned, book.routes[id] == nil { pinned = nil }
                toldID = book.told(toldID)?.id
                schedule(first: !wasLoaded)
                if RoutesClock.frozen { RoutesClock.shared.settle(step: RoutesClock.shared.currentStep) }
            } catch {
                let error = MagpieError.from(error)
                if error == .cancelled || Task.isCancelled { return }
                phase = .failed(error)
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
    }

    private func replayUnderWay() {
        guard book.loaded else { return }
        let t = now
        for route in book.playable where plays[route.id] == nil { plays[route.id] = RoutePlay(route: route, now: t, still: still) }
        advance(at: t)
    }

    private func advance(at t: TimeInterval) {
        for (id, var play) in plays {
            let route = book.routes[id]
            play.advance(route, now: t) { seat in route?.order.contains { $0.key == seat } ?? false }
            plays[id] = play
        }
        plays = plays.filter { ($0.value.over ?? .infinity) > t }
        schedulePrune()
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
            self.schedulePrune()
        }
    }
}
