import Foundation
import Observation

/// 「路由」舞台的时钟。平时就是系统时间。
///
/// UI 测试的逐帧截图（`--routes-snapshot=<秒>`，见 RoutesSnapshotUITests）里它是停住的：fixture 的示例请求
/// （RoutesFixture.trace）从第 <秒> − 4 秒开始，App 自己先走 4 秒（每步 0.1 秒）到 <秒>；之后每点一下
/// 「下一帧」（`routes.snapshot.step`）走 0.1 秒。舞台、喜鹊、示例请求都按这个时钟画，所以每一帧都是确定的，
/// 能和网页（用 Playwright 的假时钟逐帧截下来）在同一时刻对比。
@MainActor
@Observable
final class RoutesClock {
    static let shared = RoutesClock()

    /// 逐帧模式要截的第一帧（fixture 的 elapsed 秒数）；nil = 平时。
    nonisolated static let snapshotStart: TimeInterval? = {
        let prefix = "--routes-snapshot="
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return TimeInterval(arg.dropFirst(prefix.count))
    }()
    nonisolated static var frozen: Bool { snapshotStart != nil }
    /// 逐帧模式每步走多少秒。
    nonisolated static let step: TimeInterval = 0.1
    /// 先走多少秒再开始截（和网页一样：页面先载入、让前一个请求演一会儿）。
    nonisolated static let lead: TimeInterval = 4
    /// 停住的时钟从这一刻开始（随便一个固定时刻，只要每次一样）。
    nonisolated static let epoch: TimeInterval = 815_000_000

    /// 逐帧模式里此刻的时间（timeIntervalSinceReferenceDate）。
    private(set) var time: TimeInterval
    /// 已经处理完的步数（示例请求读进来、演出排好之后才算），UI 测试等它跟上再截图。
    private(set) var settledSteps = 0
    @ObservationIgnored private var steps = 0
    @ObservationIgnored private var waiting: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var warmed = false

    private init() {
        time = Self.epoch
    }

    /// 此刻（秒，timeIntervalSinceReferenceDate）。
    var now: TimeInterval { Self.frozen ? time : Date().timeIntervalSinceReferenceDate }
    var date: Date { Date(timeIntervalSinceReferenceDate: now) }

    /// fixture 示例请求的 elapsed：逐帧模式里从 snapshotStart − lead 开始。
    func fixtureElapsed(since start: Date) -> TimeInterval {
        guard let first = Self.snapshotStart else { return Date().timeIntervalSince(start) }
        return first - Self.lead + (time - Self.epoch)
    }

    /// 此刻是第几毫秒（fixture 的 elapsed），给 UI 测试看。
    var elapsedMilliseconds: Int {
        Int(((Self.snapshotStart ?? 0) - Self.lead + (time - Self.epoch)) * 1000 + 0.5)
    }

    /// 已经处理完的那一步对应的毫秒数。
    var settledMilliseconds: Int {
        Int(((Self.snapshotStart ?? 0) - Self.lead + Double(settledSteps) * Self.step) * 1000 + 0.5)
    }

    /// 走一步（逐帧模式）。
    func advance() {
        guard Self.frozen else { return }
        steps += 1
        time = Self.epoch + Double(steps) * Self.step
        let resume = waiting
        waiting = []
        for c in resume { c.resume() }
    }

    /// fixture 的长轮询：逐帧模式里等到下一步。
    func nextStep(after seen: Int) async {
        if steps > seen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    var currentStep: Int { steps }

    /// 舞台把这一步读完了。第一次读完之后自己先走 lead 秒。
    func settle(step: Int) {
        settledSteps = max(settledSteps, step)
        guard Self.frozen, !warmed else { return }
        warmed = true
        Task { @MainActor in
            let count = Int((Self.lead / Self.step).rounded())
            for _ in 0..<count {
                let target = steps + 1
                advance()
                while settledSteps < target { try? await Task.sleep(for: .milliseconds(10)) }
            }
        }
    }
}
