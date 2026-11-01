import XCTest
@testable import MagpieRemoteCore

/// 路由舞台上的喜鹊（client.js play()）、舞台上画哪些请求（staged / told）与「账号打码」（app.js hideAccounts）。
final class RoutePlayTests: XCTestCase {
    private func seat(_ id: String, _ model: String, kind: String = "key", who: String = "") -> WebJSON {
        ["id": .string(id), "provider": .string(String(id.split(separator: "#").first ?? "")), "name": .string(String(id.split(separator: "#").first ?? "")),
         "who": .string(who), "kind": .string(kind), "model": .string(model), "routing": ""]
    }

    private func attempt(_ id: String, _ model: String, done: Bool, status: Int = 0, rest: Bool = false, fail: String = "") -> WebJSON {
        var json: WebJSON = ["id": .string(id), "model": .string(model), "done": .bool(done), "status": .int(Int64(status))]
        if !fail.isEmpty { json["fail"] = .string(fail) }
        if rest { json["rest"] = ["why": "rate", "status": 429, "until": "2099-01-01T00:00:00Z"] }
        return json
    }

    private func route(id: Int64 = 1, agent: String = "claude", tries: [WebJSON], done: Bool, status: Int = 0, order: [WebJSON]? = nil) -> TraceRoute {
        TraceRoute(json: ["id": .int(id), "seq": .int(id), "agent": .string(agent), "model": "gpt-4.1",
                          "order": .array(order ?? [seat("a#k1", "gpt-4.1"), seat("b#k1", "deepseek-chat")]),
                          "tries": .array(tries), "done": .bool(done), "status": .int(Int64(status))])
    }

    private func legs(_ play: RoutePlay) -> [String] {
        play.segments.map { segment in
            switch segment.kind {
            case .fly(.toHub, let d): "toHub \(d)"
            case .fly(.out(let seat, let from), let d): "out \(seat.prefix(4)) \(from) \(d)"
            case .fly(.home(let seat), let d): "home \(seat.prefix(4)) \(d)"
            case .fly(.bounce(let seat), let d): "bounce \(seat.prefix(4)) \(d)"
            case .holdSeat(let seat, let pulsing): "hold \(seat.prefix(4))\(pulsing ? " pulsing" : "")"
            case .holdHub: "hub"
            }
        }
    }

    func testRequestFliesOutWaitsAtSeatAndIsAnsweredHome() {
        var r = route(tries: [attempt("a#k1", "gpt-4.1", done: false)], done: false)
        var play = RoutePlay(route: r, now: 100)
        play.advance(r, now: 100)
        XCTAssertEqual(legs(play), ["out a#k1 agent 1.4", "hold a#k1 pulsing"])
        XCTAssertEqual(play.segments[0].start, 100)
        XCTAssertEqual(play.segments[1].start, 101.4, accuracy: 1e-9)
        XCTAssertNil(play.segments[1].end, "回答之前点一直停在座位上")
        XCTAssertEqual(play.birds.count, 1)
        XCTAssertEqual(play.birds[0].away ?? 0, 101.4, accuracy: 1e-9, "到了座位就松开点飞走")
        XCTAssertFalse(play.ended)
        // 飞到一半时：点在去程上，喜鹊衔着它
        XCTAssertEqual(play.segment(at: 100.7)?.dot, .request)
        XCTAssertEqual(play.place(of: play.birds[0], at: 100.7)?.time ?? 0, 100.7, accuracy: 1e-9)

        r = route(tries: [attempt("a#k1", "gpt-4.1", done: true, status: 200)], done: true, status: 200)
        play.advance(r, now: 105)
        XCTAssertEqual(legs(play), ["out a#k1 agent 1.4", "hold a#k1 pulsing", "hold a#k1", "home a#k1 1.4"])
        XCTAssertEqual(play.segments[1].end ?? 0, 105)
        XCTAssertEqual(play.segments[3].start, 105)
        XCTAssertEqual(play.segments[3].dot, .answer)
        XCTAssertEqual(play.birds.count, 2, "回答由另一只喜鹊衔回来")
        XCTAssertTrue(play.ended)
        XCTAssertEqual(play.over ?? 0, 106.4 + RoutePlay.awayTime, accuracy: 1e-9)
        XCTAssertNil(play.segment(at: 107))
    }

    func testRequestDoneWhenFirstSeenStillFliesBothWays() {
        let r = route(tries: [attempt("a#k1", "gpt-4.1", done: true, status: 200)], done: true, status: 200)
        var play = RoutePlay(route: r, now: 10)
        play.advance(r, now: 10)
        XCTAssertEqual(legs(play), ["out a#k1 agent 1.4", "hold a#k1 pulsing", "hold a#k1", "home a#k1 1.4"])
        XCTAssertEqual(play.segments[3].start, 11.4, accuracy: 1e-9, "回程接在去程后面")
        XCTAssertTrue(play.ended)
    }

    func testWaitsAtMagpieUntilRoutingPicks() {
        var r = route(tries: [], done: false)
        var play = RoutePlay(route: r, now: 0)
        play.advance(r, now: 0)
        XCTAssertEqual(legs(play), ["toHub 0.62", "hub"])
        XCTAssertNil(play.birds[0].away, "在 magpie 等的时候喜鹊还衔着点")
        r = route(tries: [attempt("b#k1", "deepseek-chat", done: false)], done: false)
        play.advance(r, now: 3)
        XCTAssertEqual(legs(play), ["toHub 0.62", "hub", "out b#k1 hubFromAgent 0.9", "hold b#k1 pulsing"])
        XCTAssertEqual(play.segments[1].end ?? 0, 3)
        XCTAssertEqual(play.birds.count, 1, "同一只喜鹊接着把请求送到座位")
        XCTAssertEqual(play.birds[0].away ?? 0, 3.9, accuracy: 1e-9)
    }

    func testFailureGoesBackToMagpieAndOnToTheNext() {
        let r = route(tries: [attempt("a#k1", "gpt-4.1", done: true, status: 429, rest: true, fail: "rate"),
                              attempt("b#k1", "deepseek-chat", done: false)], done: false)
        var play = RoutePlay(route: r, now: 0)
        play.advance(r, now: 0)
        XCTAssertEqual(legs(play), ["out a#k1 agent 1.4", "hold a#k1 pulsing", "bounce a#k1 0.62",
                                    "out b#k1 hubFromSeat(\"a#k1\\0gpt-4.1\") 0.9", "hold b#k1 pulsing"])
        XCTAssertEqual(play.segments[2].dot, .error, "失败是红圈")
        XCTAssertEqual(play.segments[3].dot, .request)
        XCTAssertEqual(play.birds.count, 3)
    }

    func testLastFailureIsCarriedHomeAsTheError() {
        let r = route(tries: [attempt("a#k1", "gpt-4.1", done: true, status: 500, fail: "other")], done: true, status: 500)
        var play = RoutePlay(route: r, now: 0)
        play.advance(r, now: 0)
        XCTAssertEqual(legs(play), ["out a#k1 agent 1.4", "hold a#k1 pulsing", "home a#k1 1.35"])
        XCTAssertEqual(play.segments[2].dot, .error)
        XCTAssertTrue(play.ended)
    }

    /// 网页 tick()：Agent 卡片在请求出发、回答到达时跳一下，magpie 在喜鹊到达、从它这里再出发时跳一下；
    /// 失败落在座位上时那一行抖一下、显示「状态码 · 原因」（rerun(row.li, "hit")）。
    func testTicksAndHitsFollowTheFlight() {
        let r = route(tries: [attempt("a#k1", "gpt-4.1", done: true, status: 429, rest: true, fail: "rate"),
                              attempt("b#k1", "deepseek-chat", done: true, status: 200)], done: true, status: 200)
        var play = RoutePlay(route: r, now: 0)
        play.advance(r, now: 0)
        XCTAssertEqual(play.ticks.map(\.node), [.agent, .hub, .agent])
        XCTAssertEqual(play.ticks[0].at, 0)
        XCTAssertEqual(play.ticks[1].at, 1.4 + 0.62, accuracy: 1e-9, "从 magpie 再出发时 magpie 跳一下")
        XCTAssertEqual(play.ticks[2].at, 1.4 + 0.62 + 0.9 + 1.4, accuracy: 1e-9, "回答到 Agent 时 Agent 跳一下")
        XCTAssertEqual(play.hits.count, 1)
        XCTAssertEqual(play.hits[0].status, 429)
        XCTAssertEqual(play.hits[0].fail, "rate")
        XCTAssertEqual(play.hits[0].at, 1.4, accuracy: 1e-9)

        var waiting = RoutePlay(route: route(tries: [], done: false), now: 0)
        waiting.advance(route(tries: [], done: false), now: 0)
        XCTAssertEqual(waiting.ticks.map(\.node), [.agent, .hub])
        XCTAssertEqual(waiting.ticks[1].at, 0.62, accuracy: 1e-9, "喜鹊到 magpie 时 magpie 跳一下")
    }

    /// 减弱动态效果：每段飞行瞬间完成（网页 still() 时 fly 的 ms 为 0），点直接停在座位上。
    func testStillPlaysWithoutFlightTime() {
        let r = route(tries: [attempt("a#k1", "gpt-4.1", done: false)], done: false)
        var play = RoutePlay(route: r, now: 5, still: true)
        play.advance(r, now: 5)
        XCTAssertEqual(legs(play), ["out a#k1 agent 0.0", "hold a#k1 pulsing"])
        XCTAssertEqual(play.segments[1].start, 5)
    }

    func testSeatNotOnStageIsSkippedAndGoneRouteEnds() {
        let r = route(tries: [attempt("a#k1", "gpt-4.1", done: false)], done: false)
        var play = RoutePlay(route: r, now: 0)
        play.advance(r, now: 0, seated: { _ in false })
        XCTAssertEqual(legs(play), [], "座位不在舞台上：这次尝试不飞")
        play.advance(nil, now: 2)
        XCTAssertTrue(play.ended, "网关不再保留它：演出结束")
    }

    func testToldStaysOnTheRequestUntilItIsDone() {
        var book = TraceBook()
        func snap(_ routes: [TraceRoute], seq: Int64) -> TraceSnapshot {
            var s = TraceSnapshot(json: ["seq": .int(seq), "mine": true, "routes": []])
            s.routes = routes
            return s
        }
        let first = route(id: 1, tries: [attempt("a#k1", "gpt-4.1", done: false)], done: false)
        book.apply(snap([first], seq: 1))
        XCTAssertEqual(book.told(nil)?.id, 1)
        let second = route(id: 2, agent: "codex", tries: [], done: false)
        book.apply(snap([second], seq: 2))
        XCTAssertEqual(book.told(1)?.id, 1, "第一个还没结束：卡片还讲它")
        let firstDone = route(id: 1, tries: [attempt("a#k1", "gpt-4.1", done: true, status: 200)], done: true, status: 200)
        book.apply(snap([firstDone], seq: 3))
        XCTAssertEqual(book.told(1)?.id, 1, "更新的那个还没被路由：不抢走已经路由了的")
        let secondRouted = route(id: 2, agent: "codex", tries: [attempt("b#k1", "deepseek-chat", done: false)], done: false)
        book.apply(snap([secondRouted], seq: 4))
        XCTAssertEqual(book.told(1)?.id, 2)

        // 舞台：正在飞的、每个 Agent 还在路上的最后一个；选中时只画选中的
        let staged = book.staged(current: book.routes[2], pinned: false, playing: [1], now: Date())
        XCTAssertEqual(staged.map(\.id), [1, 2])
        XCTAssertEqual(book.staged(current: book.routes[1], pinned: true, playing: [2], now: Date()).map(\.id), [1])
        XCTAssertEqual(book.playable.map(\.id), [2], "回到页面时只有还在路上的接着飞")
    }

    func testAnotherMagpieTakingOverStartsAgainAndAccountsAreNoted() {
        var book = TraceBook()
        let json: WebJSON = ["seq": 5, "mine": true, "routes": [["id": 1, "agent": "codex", "order": [
            ["id": "codex#a", "kind": "account", "who": "demo.user@example.com", "name": "Codex", "provider": "codex"],
            ["id": "kimi#a", "kind": "account", "who": "lingting", "name": "Kimi", "provider": "kimi"],
            ["id": "relay#k1", "kind": "key", "who": "主 Key", "name": "Relay"],
        ]]]]
        book.apply(TraceSnapshot(json: json))
        XCTAssertEqual(book.accounts, ["demo.user@example.com", "lingting"], "key 的名字不算账号")
        XCTAssertTrue(book.loaded)
        var other = json
        other["by"] = ["pid": 42]
        book.apply(TraceSnapshot(json: other))
        XCTAssertFalse(book.loaded, "另一台 magpie 接管了网关：从头读")
        XCTAssertTrue(book.routes.isEmpty)
        XCTAssertEqual(book.seq, 0)
    }

    func testMaskHidesAddressesAndWholeAccountNames() {
        XCTAssertEqual(AccountMask.dots("user.name"), "dmtd.rlcs", "与 app.js dots() 的替身字母一样，. 和 @ 留着")
        XCTAssertEqual(AccountMask.dots("lingting"), "oiuohctn")
        let mask = AccountMask(accounts: ["lingting", "demo.user@example.com", "Codex", "main", "x"], notNames: ["codex", "Kimi"])
        XCTAssertEqual(mask.names, ["lingting"], "地址由 EMAIL 盖住；供应商名、通用词、太短的不算账号")
        XCTAssertEqual(mask.segments("Codex · demo.user@example.com 回答了"),
                       [MaskSegment("Codex · ", masked: false), MaskSegment(AccountMask.dots("demo.user@example.com"), masked: true), MaskSegment(" 回答了", masked: false)])
        XCTAssertEqual(mask.apply("lingting 的额度"), "oiuohctn 的额度")
        XCTAssertEqual(mask.apply("项目 lingting-react-ui"), "项目 lingting-react-ui", "连字符连着的词不是账号")
        XCTAssertEqual(mask.apply("lingtings"), "lingtings", "更长的词里的名字不是账号")
        XCTAssertEqual(mask.apply("别人 abc***gh@zhipu.example 的"), "别人 " + AccountMask.dots("abc***gh@zhipu.example") + " 的", "厂商自己打了一半的地址也整个藏起来")
        XCTAssertEqual(mask.segments("没有账号"), [MaskSegment("没有账号", masked: false)])
    }
}
