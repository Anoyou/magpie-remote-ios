import XCTest
@testable import MagpieRemoteCore

/// 路由页：路由组的路由设置与成员、多 Key 供应商、模型速度、整组保存，以及实时路由（/api/gateway/trace）。
final class GroupRoutingTests: XCTestCase {
    private func groups() throws -> WebGroups { WebGroups(json: try WebFixture.json("groups-routing.json")) }

    func testRoutingKindsKeepUnknownAndPluginRoutings() {
        XCTAssertEqual(GroupRouting(raw: ""), .smart)
        XCTAssertEqual(GroupRouting(raw: "cheap"), .cheap)
        XCTAssertEqual(GroupRouting(raw: "rotation/sticky"), .other("rotation/sticky"))
        XCTAssertEqual(GroupRouting(raw: "rotation/sticky").raw, "rotation/sticky")
        for routing in GroupRouting.groupChoices { XCTAssertEqual(GroupRouting(raw: routing.raw), routing) }
        XCTAssertEqual(GroupRouting.groupChoices.map(\.title), ["智能", "按顺序", "轮流", "最少使用", "重置前用完", "免费优先", "速度优先", "最便宜优先", "按权重", "手动"])
        XCTAssertFalse(GroupRouting.poolChoices.contains(.manual))
        XCTAssertFalse(GroupRouting.poolChoices.contains(.cheap))
        XCTAssertFalse(GroupRouting.rotate.sinkable)
        XCTAssertFalse(GroupRouting.weight.sinkable)
        XCTAssertTrue(GroupRouting.order.sinkable)
        XCTAssertEqual(GroupAffinity(raw: "nonsense"), .auto)
        XCTAssertEqual(GroupAffinity.allCases.map(\.title), ["自动", "整个会话", "一轮之内", "关闭", "严格"])
    }

    func testDecodesGroupSettingsAndMembers() throws {
        let all = try groups()
        XCTAssertFalse(all.found)
        XCTAssertEqual(all.visible.map(\.id), ["smart", "pick", "plug"])
        let smart = try XCTUnwrap(all[group: "smart"])
        XCTAssertEqual(smart.routingKind, .weight)
        XCTAssertEqual(smart.affinity, .session)
        XCTAssertTrue(smart.sink)
        XCTAssertEqual(smart.firstToken, 60)
        XCTAssertEqual(smart.patience, -1)
        XCTAssertTrue(smart.unlists)
        XCTAssertEqual(smart.ruleCount, 1)
        XCTAssertEqual(smart.named, ["relay-one/gpt-4.1", "codex/gpt-5"])
        XCTAssertEqual(smart.patterns, [GroupPattern(pattern: "openrouter/*:free", models: 1)])
        XCTAssertEqual(smart.classifierFailure, "timeout")
        XCTAssertEqual(smart.offCount, 1)
        XCTAssertEqual(smart.weight(of: "relay-one/gpt-4.1"), 3)
        XCTAssertEqual(smart.weight(of: "openrouter/free-a"), 1)
        // 开着的：gpt-4.1（3）与 free-a（1）
        XCTAssertEqual(smart.share(of: "relay-one/gpt-4.1"), 75)
        XCTAssertEqual(smart.share(of: "codex/gpt-5"), 0)

        let details = smart.memberDetails
        XCTAssertEqual(details.map(\.id), smart.members)
        XCTAssertEqual(details[0].title, "gpt-4.1")
        XCTAssertEqual(details[0].providerName, "Relay One")
        XCTAssertEqual(details[0].accounts, 2)
        XCTAssertTrue(details[0].canFast)
        XCTAssertEqual(details[0].context, 1_000_000)
        XCTAssertTrue(details[1].off)
        XCTAssertTrue(details[2].matched)
        XCTAssertTrue(details[2].providerOff)
        XCTAssertNotNil(details[2].unavailableReason)
        XCTAssertNil(details[0].unavailableReason)
        XCTAssertEqual(smart.memberSummary, "Relay One · gpt-4.1 · Codex · gpt-5（已关闭） · OpenRouter · free-a")

        let pick = try XCTUnwrap(all[group: "pick"])
        XCTAssertEqual(pick.routingKind, .manual)
        XCTAssertEqual(pick.pickedMember, "group/smart")
        XCTAssertTrue(pick.memberDetails[1].isGroup)
        XCTAssertEqual(pick.memberDetails[1].title, "Smart group")
        XCTAssertEqual(all[group: "plug"]?.routingKind, .other("rotation/sticky"))
    }

    func testDecodesPoolsAndArrangeOrder() throws {
        let all = try groups()
        XCTAssertEqual(all.pools.count, 2)
        XCTAssertEqual(all.pools[0].routing, .usage)
        XCTAssertEqual(all.pools[0].affinity, .turn)
        XCTAssertTrue(all.pools[0].sink)
        XCTAssertEqual(all.pools[0].countText, "2 个 Key")
        XCTAssertEqual(all.pools[1].countText, "2 个 anthropic Key")
        XCTAssertNotEqual(all.pools[0].id, all.pools[1].id)
        // 可见的 smart, pick, plug；把 plug 挪到最前，隐藏的 auto 组排最后
        XCTAssertEqual(all.order(moving: IndexSet(integer: 2), to: 0), ["plug", "smart", "pick", "auto-gpt-5"])
        XCTAssertEqual(WebGroups.moved([1, 2, 3, 4], from: IndexSet(integer: 0), to: 3), [2, 3, 1, 4])
        XCTAssertEqual(WebGroups.moved([1, 2, 3, 4], from: IndexSet([1, 2]), to: 4), [1, 4, 2, 3])
    }

    func testLiveGroupsFixtureDecodesWithDefaults() throws {
        let group = WebGroups(json: try WebFixture.json("live-groups.json")).groups[0]
        XCTAssertEqual(group.routingKind, .order)
        XCTAssertEqual(group.affinity, .auto)
        XCTAssertEqual(group.memberDetails.map(\.title), ["mock-gpt-1", "mock-gpt-mini"])
        XCTAssertTrue(group.memberDetails.allSatisfy(\.imagesUnknown))
        XCTAssertEqual(group.memberSummary, "Mock · mock-gpt-1 → Mock · mock-gpt-mini")
    }

    func testModelSpeeds() throws {
        let speeds = ModelSpeeds(json: try WebFixture.json("model-speeds.json"))
        XCTAssertEqual(speeds.byRef.count, 2, "没有首字时间也没有速度的条目要丢掉")
        XCTAssertEqual(speeds.byRef["relay-one/gpt-4.1"], ModelSpeed(ttft: 820, tps: 61.5, samples: 14))
        XCTAssertEqual(speeds.byRef["relay-one/gpt-4.1"]?.text, "首字 820 毫秒 · 62 tok/s")
        XCTAssertEqual(ModelSpeed(ttft: 1430, tps: 8.25).text, "首字 1.4 秒 · 8.2 tok/s")
        let details = try XCTUnwrap(try groups()[group: "smart"]).memberDetails
        XCTAssertEqual(speeds.speed(for: details[1])?.ttft, 1430)
        XCTAssertNil(speeds.speed(for: details[2]))
        XCTAssertEqual(speeds.fastest(in: details), "relay-one/gpt-4.1")
        XCTAssertEqual(ModelSpeeds(json: .null).byRef.count, 0)
    }

    func testGroupSaveKeepsEverythingNotEdited() throws {
        let smart = try XCTUnwrap(try groups()[group: "smart"])
        let body = WebRequests.groupSave(smart, edits: GroupEdits(routing: .order))
        XCTAssertEqual(body["routing"], "order")
        // 只发点名的成员；完整顺序（含模式匹配的）放在 placed
        XCTAssertEqual(body["members"], ["relay-one/gpt-4.1", "codex/gpt-5"])
        XCTAssertEqual(body["placed"], ["relay-one/gpt-4.1", "codex/gpt-5", "openrouter/free-a"])
        for kept in ["match", "rules", "classifier", "family", "levels", "affinity", "firstToken", "patience", "unlists", "off", "weights"] {
            XCTAssertEqual(body[kept], smart.raw[kept], "\(kept) 应原样保留")
        }
        XCTAssertEqual(body["sink"], true, "按顺序时可以限流后排到最后")
        for derived in ["ready", "memberInfo", "holds", "offers", "shared", "patterns", "ref", "classifierFailed", "auto", "matched"] {
            XCTAssertNil(body[derived], "\(derived) 是主机算出来的，不该回写")
        }
        XCTAssertNil(body["from"])

        // 换成轮流：不能再「限流后排到最后」
        XCTAssertNil(WebRequests.groupSave(smart, edits: GroupEdits(routing: .rotate))["sink"])
    }

    func testGroupSaveAppliesEditsAndCleansStaleMembers() throws {
        let smart = try XCTUnwrap(try groups()[group: "smart"])
        let edits = GroupEdits(id: "Smart-2", name: " 新名字 ", members: ["openrouter/free-a", "relay-one/gpt-4.1"], routing: .smart,
                               affinity: .auto, sink: false, off: ["codex/gpt-5", "openrouter/free-a"], weights: ["relay-one/gpt-4.1": 5, "codex/gpt-5": 2],
                               fast: ["relay-one/gpt-4.1"], firstToken: 0, patience: 120, unlists: false)
        let body = WebRequests.groupSave(smart, edits: edits)
        XCTAssertEqual(body["id"], "smart-2")
        XCTAssertEqual(body["from"], "smart")
        XCTAssertEqual(body["name"], "新名字")
        XCTAssertEqual(body["members"], ["relay-one/gpt-4.1"])
        XCTAssertEqual(body["placed"], ["openrouter/free-a", "relay-one/gpt-4.1"])
        XCTAssertNil(body["routing"], "智能 = 不发 routing")
        XCTAssertNil(body["affinity"])
        XCTAssertNil(body["sink"])
        XCTAssertNil(body["firstToken"])
        XCTAssertNil(body["unlists"])
        XCTAssertEqual(body["patience"], 120)
        XCTAssertEqual(body["off"], ["openrouter/free-a"], "不在组里的成员不再关着")
        XCTAssertEqual(body["weights"], ["relay-one/gpt-4.1": 5])
        XCTAssertEqual(body["fast"], ["relay-one/gpt-4.1"])
        XCTAssertEqual(body["rules"], smart.raw["rules"])

        let fresh = WebRequests.groupSave(nil, edits: GroupEdits(id: "new", name: "", members: ["a/b"], routing: .fast))
        XCTAssertEqual(fresh, ["id": "new", "name": "new", "members": ["a/b"], "routing": "fast"])
    }

    func testManualPickDroppedWhenMemberRemoved() throws {
        let pick = try XCTUnwrap(try groups()[group: "pick"])
        XCTAssertEqual(WebRequests.groupSave(pick, edits: GroupEdits(members: ["relay-one/gpt-4.1"]))["pick"], nil)
        XCTAssertEqual(WebRequests.groupSave(pick, edits: GroupEdits(name: "x"))["pick"], "group/smart")
    }

    func testSmallRequestBodies() {
        XCTAssertEqual(WebRequests.groupPick("pick", member: "a/b"), ["id": "pick", "pick": "a/b"])
        XCTAssertEqual(WebRequests.groupArrange(["b", "a"]), ["order": ["b", "a"]])
        XCTAssertEqual(WebRequests.groupFound(false), ["on": false])
        XCTAssertEqual(WebRequests.groupCopy("smart", name: "Smart 副本"), ["id": "smart", "name": "Smart 副本"])
        XCTAssertEqual(WebRequests.providerRouting("relay-one", routing: .smart), ["id": "relay-one", "routing": ""])
        XCTAssertEqual(WebRequests.providerAffinity("relay-one", affinity: .strict), ["id": "relay-one", "affinity": "strict"])
        XCTAssertEqual(WebRequests.providerSink("relay-one", sink: true), ["id": "relay-one", "sink": true])
        XCTAssertEqual(GroupTimeouts.firstTokenTitle(0), "一直等")
        XCTAssertEqual(GroupTimeouts.firstTokenTitle(300), "5 分钟")
        XCTAssertEqual(GroupTimeouts.patienceTitle(60), "1 分钟")
        XCTAssertEqual(GroupTimeouts.patienceTitle(-1), "关闭")
    }

    func testCandidateDetailForNewMember() throws {
        let all = try groups()
        let model = GroupMemberDetail.candidate("relay-one/gpt-4.1", models: all.models, groups: all.groups)
        XCTAssertEqual(model.title, "gpt-4.1")
        XCTAssertEqual(model.providerName, "Relay One")
        XCTAssertTrue(model.ready)
        let inner = GroupMemberDetail.candidate("group/smart", models: all.models, groups: all.groups)
        XCTAssertTrue(inner.isGroup)
        XCTAssertEqual(inner.title, "Smart group")
        XCTAssertFalse(GroupMemberDetail.candidate("x/y", models: all.models, groups: all.groups).ready)
    }

    func testWebClientRoutingRequests() throws {
        let client = WebClient(baseURL: URL(string: "http://100.64.0.1:3430")!, key: "web-key-EXAMPLE")
        var request = try client.makeRequest("/api/gateway/trace", query: [URLQueryItem(name: "after", value: "4"), URLQueryItem(name: "wait", value: "1")])
        XCTAssertEqual(request.url?.absoluteString, "http://100.64.0.1:3430/api/gateway/trace?after=4&wait=1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "magpie_web_3430=web-key-EXAMPLE")
        request = try client.makeRequest("/api/model-speeds")
        XCTAssertEqual(request.url?.path, "/api/model-speeds")
    }
}

final class RouteTraceTests: XCTestCase {
    private func snapshot(_ name: String) throws -> TraceSnapshot { TraceSnapshot(json: try WebFixture.json(name)) }
    private let now = UsageTimestamp.parse("2026-11-01T10:00:01+08:00")!

    func testDecodesTrace() throws {
        let trace = try snapshot("trace.json")
        XCTAssertTrue(trace.mine)
        XCTAssertEqual(trace.seq, 4)
        XCTAssertEqual(trace.totals, TraceTotals(requests: 7, rerouted: 2, errors: 1))
        XCTAssertEqual(trace.ids, [41, 42])
        XCTAssertNotNil(trace.now)
        let route = trace.routes[0]
        XCTAssertEqual(route.id, 41)
        XCTAssertEqual(route.agent, "codex")
        XCTAssertEqual(route.groupName, "Smart group")
        XCTAssertEqual(route.routing, "order")
        XCTAssertEqual(route.order.count, 3)
        XCTAssertEqual(route.order[1].kind, "account")
        XCTAssertEqual(route.order[1].used, 72.5)
        XCTAssertNotNil(route.order[1].renews, "纳秒精度的时间也要能读")
        XCTAssertEqual(route.tries.count, 2)
        XCTAssertEqual(route.tries[0].rest?.why, "rate")
        XCTAssertFalse(route.tries[0].ok)
        XCTAssertTrue(route.tries[1].ok)
        XCTAssertEqual(route.answered?.id, "codex#someone")
        XCTAssertEqual(route.seat(of: route.tries[1])?.who, "someone@example.com")
        XCTAssertEqual(route.rerouted, 1)
        XCTAssertFalse(route.failed)
        XCTAssertEqual(route.cost, 0.0042)
        XCTAssertEqual(route.sessionTitle, "修复登录页")
        let flying = trace.routes[1]
        XCTAssertFalse(flying.done)
        XCTAssertEqual(flying.trying?.id, "relay-one#k1")
        XCTAssertNil(flying.groupID)
        XCTAssertNil(flying.cost)
    }

    func testBookMergesLikeThePage() throws {
        var book = TraceBook()
        book.apply(try snapshot("trace.json"))
        XCTAssertTrue(book.loaded)
        XCTAssertEqual(book.fresh, [], "第一次读到的请求不再飞一遍")
        XCTAssertEqual(book.list.map(\.id), [42, 41])
        XCTAssertEqual(book.underWay.map(\.id), [42])
        book.apply(try snapshot("trace-next.json"))
        XCTAssertEqual(book.seq, 5)
        XCTAssertEqual(book.fresh, [43])
        XCTAssertEqual(book.newest?.id, 43)
        XCTAssertTrue(try XCTUnwrap(book.routes[42]).failed)
        XCTAssertEqual(book.totals.errors, 2)

        // 网关重启：seq 变小时从头来
        var restarted = try snapshot("trace.json")
        restarted.seq = 1
        restarted.routes = [restarted.routes[1]]
        book.apply(restarted)
        XCTAssertEqual(book.list.map(\.id), [42], "seq 变小时旧记录全部丢掉")

        // 网关已丢弃的未完成请求删掉
        var dropped = try snapshot("trace.json")
        dropped.routes = []
        dropped.ids = []
        dropped.seq = 9
        book.apply(dropped)
        XCTAssertTrue(book.routes.isEmpty)

        book.apply(try snapshot("trace-not-mine.json"))
        XCTAssertFalse(book.mine)
        XCTAssertFalse(book.loaded)
    }

    func testBookKeepsSixty() throws {
        var book = TraceBook()
        let base = try snapshot("trace.json")
        var many = base
        many.ids = nil
        many.routes = (1...80).map { id in
            var route = base.routes[0]
            route.id = Int64(id)
            return route
        }
        book.apply(many)
        XCTAssertEqual(book.routes.count, TraceBook.keep)
        XCTAssertEqual(book.list.last?.id, 21)
    }

    func testStageRowsMatchThePage() throws {
        let trace = try snapshot("trace.json")
        let names = ["codex": "Codex", "claude": "Claude Code"]
        let stage = RouteStageBuilder.build(current: trace.routes[0], staged: [trace.routes[1]], now: now) { names[$0] ?? $0 }
        XCTAssertEqual(stage.agents.map(\.id), ["codex", "claude"])
        XCTAssertEqual(stage.agents.map(\.busy), [false, true])
        XCTAssertEqual(stage.agents[0].hue, "#6366f1")
        XCTAssertEqual(stage.name, "Smart group")
        XCTAssertEqual(stage.tail, " · 路由组 · 启用 3 个 · 2 个 Agent 同时在发")
        XCTAssertEqual(stage.chip, "按顺序")
        XCTAssertFalse(stage.chipHidden)
        XCTAssertEqual(stage.mode, GroupRouting.order.hint)
        XCTAssertEqual(stage.rows.count, 3)

        // 第一个 Key 限流后在休息；另一个请求（claude）正在用它——休息优先
        let first = stage.rows[0]
        XCTAssertEqual(first.state, .resting)
        XCTAssertEqual(first.status, "限流 · 39 秒后恢复")
        // 订阅账号回答了，额度条 72.5%
        let second = stage.rows[1]
        XCTAssertEqual(second.state, .answered)
        XCTAssertEqual(second.status, "回答了 Codex")
        XCTAssertEqual(second.bar, 72.5)
        XCTAssertEqual(second.agent, "codex")
        XCTAssertEqual(stage.rows[2].state, .passedOver)
        XCTAssertEqual(stage.rows[2].status, "套餐不含这个模型 · 已跳过")
        XCTAssertTrue(stage.caption.contains("Codex · someone@example.com 回答了 Codex 的 group/smart"))
        XCTAssertTrue(stage.caption.contains("改道 1 次"))
    }

    func testStageForSingleKeyAndFailure() throws {
        var book = TraceBook()
        book.apply(try snapshot("trace.json"))
        book.apply(try snapshot("trace-next.json"))
        let failed = try XCTUnwrap(book.routes[42])
        let stage = RouteStageBuilder.build(current: failed, staged: [], now: now)
        XCTAssertEqual(stage.rows.count, 1)
        XCTAssertEqual(stage.rows[0].state, .resting)
        XCTAssertEqual(stage.rows[0].status, "502 · 失败 · 已交给 claude")
        XCTAssertEqual(stage.rows[0].tag, "502")
        XCTAssertTrue(stage.chipHidden, "只有一个 Key 时不显示路由方式")
        XCTAssertTrue(stage.mode.hasPrefix("这里只开了一个账号或 Key"))
        XCTAssertTrue(stage.caption.hasPrefix("claude 收到了错误：502"))

        let waiting = try XCTUnwrap(book.routes[43])
        let idle = RouteStageBuilder.build(current: waiting, staged: [], now: now)
        XCTAssertEqual(idle.rows[0].state, .idle)
        XCTAssertTrue(idle.rows[0].status.hasPrefix("已用 73%"), idle.rows[0].status)
        XCTAssertTrue(idle.rows[0].status.contains("后重置"))

        let answering = RouteStageBuilder.build(current: try snapshot("trace.json").routes[1], staged: [], now: now)
        XCTAssertEqual(answering.rows[0].state, .answering)
        XCTAssertEqual(answering.rows[0].status, "回答中…")
        XCTAssertEqual(answering.rows[0].agent, "claude")
        XCTAssertTrue(answering.agents[0].busy)
    }

    func testHuesNeverRedAndStable() {
        XCTAssertEqual(RouteStageBuilder.hue("claude"), "#d97757")
        XCTAssertEqual(RouteStageBuilder.hue("my-tool"), RouteStageBuilder.hue("my-tool"))
        XCTAssertTrue(RouteStageBuilder.spare.contains(RouteStageBuilder.hue("my-tool")))
        XCTAssertEqual(RouteStageBuilder.failWord("quota"), "额度用尽")
        XCTAssertEqual(RouteStageBuilder.duration(39), "39 秒")
        XCTAssertEqual(RouteStageBuilder.duration(3 * 3600 + 120), "3 小时 2 分")
    }
}
