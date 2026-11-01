import XCTest
@testable import MagpieRemoteCore

/// 「路由」页讲请求的话（client.js firstWhy / trySaid / renderSteps / outcome）、舞台上的折叠（rebuild / together）、
/// 重放（replay / ghost / realAt）与舞台下那句话的队列（say / capQ）。只用假数据。
final class RouteStoryTests: XCTestCase {
    private let until = "2099-01-01T08:00:00Z"

    private func seat(_ id: String, _ model: String, kind: String = "key", who: String = "", provider: String? = nil, routing: String = "", via: [String] = []) -> WebJSON {
        let p = provider ?? String(id.split(separator: "#").first ?? "")
        var json: WebJSON = ["id": .string(id), "provider": .string(p), "name": .string(p.capitalized), "who": .string(who), "kind": .string(kind),
                             "model": .string(model), "routing": .string(routing)]
        if !via.isEmpty { json["via"] = .array(via.map { .string($0) }) }
        return json
    }

    private func attempt(_ id: String, _ model: String, done: Bool, status: Int = 0, ms: Int = 0, fail: String = "", rest: WebJSON? = nil, start: String = "2026-01-01T00:00:00Z") -> WebJSON {
        var json: WebJSON = ["id": .string(id), "model": .string(model), "done": .bool(done), "status": .int(Int64(status)), "ms": .int(Int64(ms)), "start": .string(start)]
        if !fail.isEmpty { json["fail"] = .string(fail) }
        if let rest { json["rest"] = rest }
        return json
    }

    private func route(id: Int64 = 1, agent: String = "codex", model: String = "gpt-4.1", order: [WebJSON], tries: [WebJSON], done: Bool, status: Int = 0,
                       group: WebJSON? = nil, time: String = "2026-01-01T00:00:00Z", ms: Int = 0, tokens: Int = 0) -> TraceRoute {
        var json: WebJSON = ["id": .int(id), "seq": .int(id), "agent": .string(agent), "model": .string(model), "provider": "relay",
                             "order": .array(order), "tries": .array(tries), "done": .bool(done), "status": .int(Int64(status)),
                             "time": .string(time), "ms": .int(Int64(ms)), "tokens": .int(Int64(tokens))]
        if let group { json["group"] = group }
        return TraceRoute(json: json)
    }

    private let names: (String) -> String = { ["codex": "Codex", "claude": "Claude Code"][$0] ?? $0 }

    // MARK: 讲请求

    func testRateLimitedThenRerouted() {
        let rest: WebJSON = ["why": "rate", "status": 429, "until": "2026-01-01T00:00:41Z", "by": "retry-after"]
        let r = route(order: [seat("relay#k1", "gpt-4.1", who: "主 Key", routing: "order"), seat("deepseek#k1", "deepseek-chat", who: "备 Key", routing: "order")],
                      tries: [attempt("relay#k1", "gpt-4.1", done: true, status: 429, ms: 1000, fail: "rate", rest: rest),
                              attempt("deepseek#k1", "deepseek-chat", done: true, status: 200, ms: 2100, start: "2026-01-01T00:00:01Z")],
                      done: true, status: 200, ms: 3100, tokens: 1840)
        XCTAssertEqual(RouteStory.firstWhy(r), "按顺序：主 Key 排第一，能响应就由它处理。")
        let first = RouteStory.trySaid(r, 0, agentName: names)
        XCTAssertTrue(first.hasPrefix("主 Key (gpt-4.1) 返回 429 · 限流"), first)
        XCTAssertTrue(first.hasSuffix("转给 备 Key。"), first)
        XCTAssertTrue(first.contains("限流"), first)
        XCTAssertTrue(first.contains("40 秒"), "休息到 until：从这次尝试结束时算 \(first)")
        let second = RouteStory.trySaid(r, 1, agentName: names)
        XCTAssertTrue(second.contains("2.1 秒"), second)
        XCTAssertTrue(second.contains("1.8k token"), second)
        XCTAssertTrue(second.contains("看不到之前失败的 1 次"), second)

        let steps = RouteStory.steps(r, agentName: names)
        XCTAssertEqual(steps.map(\.kind), [.asked, .why, .bad, .ok])
        XCTAssertEqual(steps[0].text, "Codex 请求 gpt-4.1 → Relay")
        XCTAssertEqual(RouteStory.outcome(r).how, .moved)
        XCTAssertEqual(RouteStory.outcome(r).said, "备 Key · deepseek-chat")
    }

    func testFailedRequestOutcomeAndSaid() {
        let r = route(order: [seat("relay#k1", "gpt-4.1", who: "主 Key")],
                      tries: [attempt("relay#k1", "gpt-4.1", done: true, status: 502, ms: 300, fail: "other")], done: true, status: 502)
        XCTAssertEqual(RouteStory.outcome(r).said, "502 · 失败")
        XCTAssertEqual(RouteStory.outcome(r).how, .bad)
        XCTAssertTrue(RouteStory.failed(r))
        XCTAssertEqual(RouteStory.firstWhy(r), "Relay 只启用了一个 Key，无需选择。")
        XCTAssertEqual(RouteStory.trySaid(r, 0, agentName: names), "主 Key (gpt-4.1) 返回 502，且无其他可试，Codex 收到此错误。")
        let waiting = route(order: [], tries: [], done: false)
        XCTAssertEqual(RouteStory.outcome(waiting).said, "路由中…")
        XCTAssertEqual(RouteStory.firstWhy(waiting), RouteWords.t("magpie hasn't routed this request yet, so who takes it isn't picked yet."))
    }

    func testRestHowAndWords() {
        let from = Date(timeIntervalSince1970: 0)
        func rest(_ by: String, _ secs: Double, why: String = "rate", failures: Int = 0) -> TraceRest {
            TraceRest(["why": .string(why), "status": 429, "by": .string(by), "failures": .int(Int64(failures)),
                       "until": .string(ISO8601DateFormatter().string(from: from.addingTimeInterval(secs)))])
        }
        XCTAssertEqual(RouteStory.restHow(rest("retry-after", 40), from: from), "按厂商 Retry-After 的要求，它休息 40 秒")
        XCTAssertTrue(RouteStory.restHow(rest("backoff", 120, failures: 3), from: from).contains("3"))
        XCTAssertEqual(RouteStory.restSay(rest("cooldown", 37), now: from), "限流 · 37 秒后恢复")
        XCTAssertEqual(RouteWords.modeName("weight"), "按权重")
        XCTAssertEqual(RouteWords.dur(7 * 24 * 3600), "7 天")
    }

    // MARK: 折叠

    private func keys(_ n: Int, provider: String = "relay", model: String = "gpt-4.1", via: [String] = []) -> [WebJSON] {
        (1...n).map { seat("\(provider)#k\($0)", model, provider: provider, via: via) }
    }

    func testKeysFoldWhenThreeOrMoreAndAccountsWhenSixOrMore() {
        let r = route(order: keys(3) + [seat("solo#k1", "x")], tries: [], done: false)
        let stage = RouteStageBuilder.build(current: r, staged: [], now: Date())
        var memory = StageFoldMemory()
        var layout = RouteStageBuilder.layout(stage, routes: [r], memory: memory)
        XCTAssertEqual(layout.items.map(\.kind), [.fold, .row], "三个 Key 合成一行（默认折起），另一个照常")
        let fold = layout.items[0]
        XCTAssertEqual(fold.count, "3 个密钥")
        XCTAssertFalse(fold.open)
        XCTAssertEqual(layout.shown("relay#k2\u{0}gpt-4.1"), fold.id, "飞向折起的 Key 时飞到合并的那一行")
        XCTAssertTrue(fold.status.contains("3 个可用"), fold.status)
        // 点开：三行挂在它下面，缩进一级，线从它的小车道下来
        memory.keep(fold.persistKey, open: true)
        layout = RouteStageBuilder.layout(stage, routes: [r], memory: memory)
        XCTAssertEqual(layout.items.map(\.kind), [.fold, .row, .row, .row, .row])
        XCTAssertEqual(layout.items[1].parent, fold.id)
        XCTAssertEqual(layout.items[1].depth, 1)
        XCTAssertEqual(layout.chains["relay#k2\u{0}gpt-4.1"], [fold.id, "relay#k2\u{0}gpt-4.1"])
        XCTAssertEqual(fold.persistKey, "relay/gpt-4.1")

        let accounts = (1...5).map { seat("codex#a\($0)", "gpt-5", kind: "account", who: "user\($0)@example.com", provider: "codex") }
        let ra = route(order: accounts, tries: [], done: false)
        let la = RouteStageBuilder.layout(RouteStageBuilder.build(current: ra, staged: [], now: Date()), routes: [ra], memory: StageFoldMemory())
        XCTAssertTrue(la.items[0].open, "不到 6 个账号默认展开")
        XCTAssertEqual(la.items[0].persistKey, "codex/gpt-5@")
    }

    func testTwoRoutesGetHeadingsAndSubGroupsFoldWhenLong() {
        let g: WebJSON = ["id": "smart", "name": "聪明组", "routing": "order",
                          "subs": [["id": "fast", "name": "快组", "routing": "fast", "in": "smart"]]]
        let a = route(id: 1, agent: "codex", order: (1...6).map { seat("p\($0)#k1", "m\($0)", provider: "p\($0)", via: ["fast"]) }, tries: [], done: false, group: g)
        let b = route(id: 2, agent: "claude", order: [seat("deepseek#k1", "deepseek-chat")], tries: [], done: false)
        let stage = RouteStageBuilder.build(current: b, staged: [a], now: Date())
        let layout = RouteStageBuilder.layout(stage, routes: [b, a], memory: StageFoldMemory(), agentName: names)
        let heads = layout.items.filter { $0.kind == .heading }
        XCTAssertEqual(heads.count, 3, "两条路由各一个标题，组里的子组一个")
        let group = heads.first { $0.name == "聪明组" }!
        XCTAssertTrue(group.route)
        XCTAssertEqual(group.ref, "group/smart")
        XCTAssertEqual(group.mode, "按顺序")
        XCTAssertEqual(group.tip, "Codex 在发往这里")
        XCTAssertTrue(group.open)
        let sub = heads.first { $0.name == "快组" }!
        XCTAssertEqual(sub.parent, group.id)
        XCTAssertFalse(sub.open, "6 个以上的子组默认折起")
        XCTAssertEqual(sub.count, "启用 6 个")
        XCTAssertEqual(layout.shown("p3#k1\u{0}m3"), sub.id)
        let provider = heads.first { $0.name == "Deepseek" }!
        XCTAssertEqual(provider.ref, "gpt-4.1")
        XCTAssertEqual(provider.mode, "", "只有一个 Key 的供应商不写路由方式")
    }

    // MARK: 重放

    func testReplaySkipsLongWaitsAndGhostsTries() throws {
        let a = route(id: 1, order: [seat("relay#k1", "gpt-4.1")],
                      tries: [attempt("relay#k1", "gpt-4.1", done: true, status: 200, ms: 10_000)], done: true, status: 200,
                      time: "2026-01-01T00:00:00Z", ms: 10_000)
        let b = route(id: 2, order: [seat("relay#k1", "gpt-4.1")],
                      tries: [attempt("relay#k1", "gpt-4.1", done: true, status: 200, ms: 1000, start: "2026-01-01T01:00:00Z")], done: true, status: 200,
                      time: "2026-01-01T01:00:00Z", ms: 1000)
        let open = route(id: 3, order: [], tries: [], done: false)
        var replay = try XCTUnwrap(RouteReplay([b, open, a]))
        XCTAssertEqual(replay.plan.map(\.route.id), [1, 2], "只放结束了的，按先后")
        XCTAssertEqual(replay.total, 1.8 + 1.8 + 1, accuracy: 1e-9, "10 秒的回答和一小时的空闲各只等 1.8 秒")
        XCTAssertEqual(replay.v, -RouteReplay.lead)
        let mid = RouteReplay.ghost(replay.plan[0], at: 1)
        XCTAssertFalse(mid.done)
        XCTAssertEqual(mid.tries.count, 1)
        XCTAssertFalse(mid.tries[0].done, "还没结束的尝试在答")
        XCTAssertTrue(RouteReplay.ghost(replay.plan[0], at: 1.8).done)
        // 钟走真实的时间：空闲那段快
        let quiet = replay.realAt(2.7)
        XCTAssertGreaterThan(quiet.fast, 100)
        XCTAssertFalse(replay.skipText(quiet.fast).isEmpty)
        XCTAssertEqual(replay.skipText(1), "")
        replay.nextSpeed(); replay.nextSpeed(); replay.nextSpeed()
        XCTAssertEqual(replay.speedText, "8× 速度")
        replay.nextSpeed()
        XCTAssertEqual(replay.speed, 1)
        replay.seek(0.5)
        XCTAssertEqual(replay.progress, 0.5, accuracy: 1e-9)
        replay.step(1)
        XCTAssertEqual(replay.v, replay.total / 2 + 0.25, accuracy: 1e-9, "一帧最多算 250 毫秒")
        XCTAssertNil(RouteReplay([open]))
    }

    // MARK: 那句话

    func testCaptionQueueHoldsEachLine() {
        var q = CaptionQueue()
        q.show("开始", now: 0)
        q.say("第一句")
        q.say("第二句")
        XCTAssertFalse(q.tick(now: 1), "一句至少讲 1.7 秒")
        XCTAssertTrue(q.tick(now: 1.8))
        XCTAssertEqual(q.shown, "第一句")
        q.say("不重要的", lo: true)
        XCTAssertTrue(q.pending)
        XCTAssertTrue(q.tick(now: 3.6))
        XCTAssertEqual(q.shown, "第二句", "有句子排着时不重要的不说")
        q.say("不重要的", lo: true)
        XCTAssertTrue(q.tick(now: 5.4))
        XCTAssertEqual(q.shown, "不重要的")
        q.say("重要的")
        XCTAssertFalse(q.tick(now: 5.8))
        XCTAssertTrue(q.tick(now: 6.0), "不重要的一句后面跟着重要的时只等 0.5 秒")
        XCTAssertEqual(q.shown, "重要的")
        for i in 0..<5 { q.say("句\(i)") }
        var shown: [String] = []
        var t = 6.0
        while q.pending { t += 2; q.tick(now: t); shown.append(q.shown) }
        XCTAssertEqual(shown, ["句2", "句3", "句4"], "最多排 3 句")
    }
}
