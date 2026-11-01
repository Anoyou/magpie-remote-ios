import Foundation
import Observation
import MagpieRemoteCore

/// 实时路由：长轮询 `GET /api/gateway/trace?after=<seq>&wait=1`（与 magpie 网页 `poll()` 相同），
/// 把增量合并进 `TraceBook`，并记下要「飞」的请求（新出现的、刚回答完的）。页面不在屏幕上时停止。
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

    /// 一次飞行：去程（Agent → magpie → 座位）或回程（座位 → magpie → Agent）。
    struct Flight: Identifiable, Equatable {
        let id = UUID()
        var route: Int64
        var agent: String
        var seat: String
        var back: Bool
        var failed: Bool
        var start: Date
    }

    private(set) var phase: Phase = .idle
    private(set) var book = TraceBook()
    private(set) var flights: [Flight] = []
    /// 用户点选的请求；nil = 跟着最新的走。
    var pinned: Int64?
    private var task: Task<Void, Never>?
    private var finished = Set<Int64>()

    var current: TraceRoute? {
        if let pinned, let route = book.routes[pinned] { return route }
        return book.newest
    }

    /// 与选中请求一起上台的：其余还在路上的请求（网页 `staged()`，多个 Agent 同时在发时一起画）。
    var staged: [TraceRoute] { book.underWay.filter { $0.id != current?.id } }

    func start(service: (any ManageServing)?) {
        guard task == nil, let service else { return }
        if phase == .idle { phase = .loading }
        task = Task { [weak self] in await self?.poll(service) }
    }

    func stop() {
        task?.cancel()
        task = nil
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
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }
                phase = .live
                if pinned != nil, book.routes[pinned!] == nil { pinned = nil }
                schedule(wasLoaded: wasLoaded)
            } catch {
                let error = MagpieError.from(error)
                if error == .cancelled || Task.isCancelled { return }
                phase = .failed(error)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// 新请求飞去程；刚结束的请求飞回程（失败时回程是红圈，只飞到 magpie 为止由下一次尝试接着）。
    private func schedule(wasLoaded: Bool) {
        let now = Date()
        flights.removeAll { now.timeIntervalSince($0.start) > 4 }
        guard wasLoaded else {
            finished = Set(book.routes.values.filter(\.done).map(\.id))
            return
        }
        for id in book.fresh.suffix(4) {
            guard let route = book.routes[id] else { continue }
            let target = route.trying.map(route.seatKey(of:)) ?? route.tries.first.map(route.seatKey(of:)) ?? route.order.first?.key
            if let target {
                flights.append(Flight(route: id, agent: route.agent, seat: target, back: false, failed: false, start: now))
            }
        }
        for route in book.routes.values where route.done && !finished.contains(route.id) {
            finished.insert(route.id)
            guard let last = route.tries.last else { continue }
            flights.append(Flight(route: route.id, agent: route.agent, seat: route.seatKey(of: last), back: true,
                                  failed: route.failed, start: now.addingTimeInterval(book.fresh.contains(route.id) ? 1.6 : 0)))
        }
    }
}
