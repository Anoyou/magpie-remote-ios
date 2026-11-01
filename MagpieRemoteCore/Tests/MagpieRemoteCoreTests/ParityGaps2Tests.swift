import XCTest
@testable import MagpieRemoteCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 第二轮对齐官方网页：网关密钥限额 / 可用模型与账号 / 可看额度、Agent 排序与隐藏、每个 Agent 的模型列表、停用的模型、逐个模型测试。
final class ParityGaps2Tests: XCTestCase {
    private var session: URLSession!
    private let base = URL(string: "http://100.64.0.1:3430")!
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
    }

    private var client: WebClient { WebClient(baseURL: base, key: "web-key-EXAMPLE-0123", session: session) }

    private func body(_ request: URLRequest?) throws -> WebJSON {
        guard let request else { return .null }
        if let data = request.httpBody { return try WebJSON.decode(data) }
        guard let stream = request.httpBodyStream else { return .null }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return try WebJSON.decode(data)
    }

    private func date(_ text: String) -> Date { QuotaTime.parse(text)! }

    // MARK: 限额

    func testDecodesKeyLimitsAndUsage() throws {
        let list = WebCallerKeys(json: try WebFixture.json("caller-keys-limits.json"))
        XCTAssertEqual(list.accountNames["codex/acct-01"], "Codex · someone@example.com")
        let key = try XCTUnwrap(list.keys.first)
        XCTAssertEqual(key.limits.map(\.period), ["hours", "week"])
        XCTAssertEqual(key.limits[0].hours, 5)
        XCTAssertEqual(key.limits[0].tokens, 2_000_000)
        XCTAssertEqual(key.limits[1].cost, 20)
        XCTAssertTrue(key.limits[1].cacheReads)
        XCTAssertEqual(key.usages.count, 2)
        XCTAssertTrue(key.quotas)
        // 用完的那条最卡住它
        let binding = try XCTUnwrap(key.bindingUsage)
        XCTAssertTrue(binding.spent)
        XCTAssertEqual(key.limitBadge, "已用完 · 200 万 / 200 万 · 每 5 小时 · 另 1 条限额")
        let now = date("2026-11-01T12:00:00+08:00")
        XCTAssertEqual(key.limitLine(binding, now: now, calendar: calendar),
                       "每 5 小时 · 已用 200 万 / 200 万 Token · 剩余 0 · 15:00 前拒绝请求 · 1 个请求进行中")
        XCTAssertEqual(key.limitLine(key.usages[1], now: now, calendar: calendar),
                       "每周 · 估算费用 $7.50 / $20.00 · 剩余 $12.50 · 明天 00:00 重置")
        XCTAssertEqual(key.resetLimitMessage(index: 0, now: now, calendar: calendar),
                       "iPhone 已用的 Token 和费用一起清零，并从现在开始新的 5 小时周期。")
        XCTAssertEqual(key.resetLimitMessage(index: 1, now: now, calendar: calendar),
                       "iPhone 已用的 Token 和费用一起清零，本周期内此前的调用不再计入；周期仍在 明天 00:00 重置。")
        XCTAssertEqual(key.modelsBadge(), "2 个模型")
        let accounts = list.keys[1]
        XCTAssertTrue(accounts.limits.isEmpty)
        XCTAssertEqual(accounts.limitBadge, "限额")
        XCTAssertEqual(accounts.modelsBadge(accountNames: list.accountNames), "Codex · someone@example.com")
        XCTAssertEqual(list.keys[2].modelsBadge(), "全部模型")
    }

    func testOldHostSingleUsedStillReads() {
        let key = WebCallerKey(raw: ["id": "k", "name": "k", "limit": ["period": "day", "cost": 5],
                                     "used": ["period": "day", "cost": 1, "costLimit": 5, "costLeft": 4, "tokensLeft": 0, "spent": false,
                                              "reset": "2026-11-02T00:00:00+08:00", "start": "2026-11-01T00:00:00+08:00"]])
        XCTAssertEqual(key.usages.count, 1)
        XCTAssertEqual(key.limitBadge, "$1.00 / $5.00 · 每日")
    }

    func testResetClock() {
        let now = date("2026-11-04T09:00:00+08:00") // 周三
        XCTAssertEqual(keyResetClock(date("2026-11-04T23:30:00+08:00"), now: now, calendar: calendar), "23:30")
        XCTAssertEqual(keyResetClock(date("2026-11-05T08:00:00+08:00"), now: now, calendar: calendar), "明天 08:00")
        XCTAssertTrue(keyResetClock(date("2026-11-08T00:00:00+08:00"), now: now, calendar: calendar).hasSuffix("00:00"))
        XCTAssertEqual(keyResetClock(date("2026-12-01T00:00:00+08:00"), now: now, calendar: calendar), "12月1日 00:00")
    }

    func testLimitDraftParsesLikeOfficial() {
        XCTAssertEqual(KeyLimitDraft.tokens("2,000,000"), 2_000_000)
        XCTAssertEqual(KeyLimitDraft.tokens("500k"), 500_000)
        XCTAssertEqual(KeyLimitDraft.tokens("1.5M"), 1_500_000)
        XCTAssertEqual(KeyLimitDraft.tokens("100万"), 1_000_000)
        XCTAssertEqual(KeyLimitDraft.tokens("1亿"), 100_000_000)
        XCTAssertEqual(KeyLimitDraft.tokens(""), 0)
        XCTAssertNil(KeyLimitDraft.tokens("lots"))
        XCTAssertEqual(KeyLimitDraft.cost("$2.50"), 2.5)
        XCTAssertEqual(KeyLimitDraft.cost(""), 0)
        XCTAssertNil(KeyLimitDraft.cost("5 USD"))
    }

    func testLimitDraftNewEditAndRemove() throws {
        let list = WebCallerKeys(json: try WebFixture.json("caller-keys-limits.json"))
        let key = list.keys[0]
        // 改第一条：带 index（有两条）
        var draft = KeyLimitDraft(key: key, index: 0)
        XCTAssertEqual(draft.period, "hours")
        XCTAssertEqual(draft.hours, "5")
        XCTAssertFalse(draft.changed)
        XCTAssertFalse(draft.canSave)
        draft.tokens = "3M"
        XCTAssertTrue(draft.canSave)
        XCTAssertEqual(draft.body(key: key.id),
                       ["key": "key-two-limits", "index": 0,
                        "limit": ["period": "hours", "hours": 5, "tokens": 3_000_000, "cost": .double(0), "cacheReads": false]])
        draft.hours = "0"
        XCTAssertEqual(draft.problem, "小时数应为 1 到 8760 的整数")
        XCTAssertFalse(draft.canSave)
        // 新加一条：选还没有的周期（已有 hours、week → day）
        let new = KeyLimitDraft(key: key, index: 2)
        XCTAssertTrue(new.isNew)
        XCTAssertEqual(new.period, "day")
        XCTAssertFalse(new.canSave) // 没有上限
        // 删除这条：两个上限都清空 → limit 为 null
        var remove = KeyLimitDraft(key: key, index: 1)
        remove.cost = ""
        XCTAssertNil(remove.limit)
        XCTAssertTrue(remove.canSave)
        XCTAssertEqual(remove.body(key: key.id)["limit"], .null)
        XCTAssertEqual(remove.body(key: key.id)["index"], 1)
        XCTAssertEqual(remove.savedSaid(name: "iPhone"), "已取消 iPhone 的限额")
        // 只有一条 / 没有时不带 index
        let plain = list.keys[2]
        var first = KeyLimitDraft(key: plain, index: 0)
        XCTAssertEqual(first.period, "day")
        first.period = "days"
        first.days = "10"
        first.cost = "5"
        XCTAssertTrue(first.canSave)
        XCTAssertNil(first.body(key: plain.id)["index"])
        XCTAssertEqual(first.body(key: plain.id)["limit"]?["days"], 10)
        XCTAssertEqual(first.savedSaid(name: "旧电脑"), "已保存 旧电脑 的限额")
        // 第二条新加的周期：已有 day → week
        let second = KeyLimitDraft(key: WebCallerKey(raw: ["id": "x", "limit": ["period": "day", "cost": 1]]), index: 1)
        XCTAssertEqual(second.period, "week")
        XCTAssertTrue(second.sendsIndex)
    }

    func testResetLimitBodyIndexOnlyWithSeveral() throws {
        let list = WebCallerKeys(json: try WebFixture.json("caller-keys-limits.json"))
        XCTAssertEqual(WebRequests.callerKeyResetLimit(list.keys[0], index: 1), ["key": "key-two-limits", "index": 1])
        let one = WebCallerKey(raw: ["id": "x", "limit": ["period": "day", "cost": 1], "usedAll": [["period": "day"]]])
        XCTAssertEqual(WebRequests.callerKeyResetLimit(one, index: 0), ["key": "x"])
    }

    func testPostsLimitKey() async throws {
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], try WebFixture.data("caller-keys-limits.json")) }
        let result = try await client.callerKey(.limit, ["key": "key-plain", "limit": ["period": "day", "cost": 5]])
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/caller-keys/limit-key")
        XCTAssertEqual(try body(StubURLProtocol.lastRequest)["limit"]?["cost"], 5)
        XCTAssertEqual(result.keys.count, 3)
        XCTAssertEqual(CallerKeyAction.models.rawValue, "models-key")
        XCTAssertEqual(CallerKeyAction.accounts.rawValue, "accounts-key")
        XCTAssertEqual(CallerKeyAction.quotas.rawValue, "quotas-key")
        XCTAssertEqual(WebRequests.callerKeyQuotas("k", on: true), ["key": "k", "quotas": true])
    }

    // MARK: 可用模型 / 账号

    func testCallerKeyModelOptionsInOfficialOrder() async throws {
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], try WebFixture.data("caller-keys-models-full.json")) }
        let models = try await client.callerKeyModels()
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/caller-keys/models")
        let keys = WebCallerKeys(json: try WebFixture.json("caller-keys-limits.json")).keys
        let options = models.options(for: keys[1]) // 只限 codex/acct-01 账号
        XCTAssertEqual(options.map(\.value), [
            "", "group/*", "group/smart",
            "relay-one/*", "relay-one/gpt-4.1", "relay-one/o3", "relay-one/k-01",
            "codex/*", "codex/gpt-5", "codex/acct-01",
            "kimi/acct-02",
        ])
        XCTAssertEqual(options[0].name, "全部模型")
        XCTAssertEqual(options[3].name, "Relay One 的全部模型")
        // 选了 Codex 的账号、没选模型：别的供应商的账号「不会被使用」
        XCTAssertEqual(options[6].note, "不会被使用：Relay One 没有勾选任何模型或账号")
        XCTAssertEqual(options[9].note, "Codex · Plus")
        // 第一把：只限模型；留着现在没提供的模型
        let first = models.options(for: WebCallerKey(raw: ["id": "k", "models": ["relay-one/gpt-4.1", "gone/model"], "accounts": ["codex/acct-01", "old/acct"]]))
        XCTAssertEqual(first.first { $0.value == "relay-one/k-01" }?.note, "会被使用：Relay One 没有勾选任何账号")
        XCTAssertEqual(first.first { $0.value == "gone/model" }?.note, "当前未提供")
        XCTAssertEqual(first.last?.value, "old/acct")
        XCTAssertEqual(first.last?.note, "当前未登录")
        // 分开发：模型总是发，账号变了才发
        let split = CallerKeyModels.split(picked: ["relay-one/gpt-4.1", "codex/acct-01"], options: options, key: keys[1])
        XCTAssertEqual(split.models, ["relay-one/gpt-4.1"])
        XCTAssertNil(split.accounts)
        let cleared = CallerKeyModels.split(picked: [], options: options, key: keys[1])
        XCTAssertEqual(cleared.accounts, [])
        XCTAssertEqual(CallerKeyModels.savedSaid(name: "Codex", models: [], accounts: ["codex/acct-01"]), "Codex 仅可使用所选账号的模型")
        XCTAssertEqual(CallerKeyModels.savedSaid(name: "Codex", models: [], accounts: []), "Codex 可使用全部模型")
    }

    // MARK: Agent 排序 / 隐藏

    private func agents() throws -> [WebAgent] {
        try XCTUnwrap(WebState(json: try WebFixture.json("state-agents-full.json")).agents)
    }

    func testMoveAndHideAgents() async throws {
        let all = try agents()
        let arrangement = AgentArrangement(agents: all, order: [], hidden: [])
        let shown = arrangement.shown.map(\.id)
        guard shown.count >= 2 else { return XCTFail("fixture needs two agents in view") }
        let moved = try XCTUnwrap(arrangement.moving(shown[1], to: 0))
        XCTAssertEqual(Array(moved.prefix(2)), [shown[1], shown[0]])
        XCTAssertEqual(Set(moved), Set(all.map(\.id)))
        XCTAssertNil(arrangement.moving(shown[0], to: -1))
        XCTAssertNil(arrangement.moving(shown[0], to: 0))
        let hide = AgentArrange.hiding(all[0], hide: true, all: all, order: [], hidden: ["x"])
        XCTAssertEqual(hide.hidden, ["x", all[0].id])
        XCTAssertEqual(hide.order, all.map(\.id))
        XCTAssertEqual(AgentArrange.hiding(all[0], hide: false, all: all, order: [], hidden: [all[0].id]).hidden, [])
        XCTAssertEqual(AgentArrange.said(all[0], hide: true, stillFolded: false), "已隐藏 \(all[0].name) · 可在列表底部「已隐藏」里找回")
        XCTAssertEqual(AgentArrange.said(all[0], hide: false, stillFolded: false), "已显示 \(all[0].name)")

        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], try WebFixture.data("settings-disabled-models.json")) }
        let settings = try await client.arrangeAgents(order: ["claude", "codex"], hidden: ["gemini"])
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/agents/arrange")
        XCTAssertEqual(try body(StubURLProtocol.lastRequest), ["order": ["claude", "codex"], "hidden": ["gemini"], "shown": []])
        XCTAssertEqual(settings.agentOrder, ["claude", "codex"])
        XCTAssertEqual(settings.agentsHidden, ["gemini"])
    }

    // MARK: 每个 Agent 的模型列表

    func testAgentModelList() async throws {
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], try WebFixture.data("agent-models.json")) }
        var list = try await client.agentModels("codex")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/agent-models/codex")
        XCTAssertTrue(list.own)
        // 路由组排最前
        XCTAssertEqual(list.groups.map(\.title), ["路由组", "Relay One", "Codex", "DeepSeek"])
        XCTAssertEqual(list.groups[1].shownCount, 1)
        XCTAssertEqual(list.count.entry, "显示 4 / 5 个模型")
        // 没拖过：Codex 自己的排前面
        XCTAssertEqual(list.inOrder.first?.id, "codex/gpt-5")
        // 在用的不能隐藏
        list.toggle("relay-one/gpt-4.1")
        XCTAssertFalse(list.models[0].hidden)
        list.toggle("relay-one/o3")
        XCTAssertEqual(list.visibilityBody, ["hidden": []])
        list.setAll(hidden: true)
        XCTAssertEqual(list.visibilityBody, ["hidden": ["group/smart", "relay-one/o3", "codex/gpt-5", "deepseek/deepseek-chat"]])
        list.only = true
        XCTAssertEqual(list.visibilityBody, ["shown": ["relay-one/gpt-4.1"]])
        list.setGroup("Relay One", hidden: false)
        XCTAssertEqual(list.groups[1].allOn, true)
        // 排序：挪动后显示着的在前，隐藏的在后
        var ordering = AgentModelList(json: try WebFixture.json("agent-models.json"))
        let ids = ordering.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        XCTAssertEqual(ids, ["deepseek/deepseek-chat", "codex/gpt-5", "relay-one/gpt-4.1", "group/smart"])
        XCTAssertTrue(ordering.ordered)
        XCTAssertEqual(ordering.models.last?.id, "relay-one/o3")
        XCTAssertEqual(AgentModelList.orderNote(agentID: "codex", agentName: "Codex"), "拖动排列 Codex 列表中的顺序；新模型排在最后")

        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], try WebFixture.data("agent-models-set.json")) }
        let answer = try await client.setAgentModels("codex", AgentModelList.onlyBody(true))
        XCTAssertEqual(try body(StubURLProtocol.lastRequest), ["only": true])
        list.merge(answer)
        XCTAssertEqual(list.models.count, 3)
        XCTAssertTrue(list.only)
        XCTAssertEqual(AgentModelCount(json: answer["count"])?.entry, "全部 3 个模型")
        XCTAssertEqual(agentContextShort(1_047_576), "1.0M")
        XCTAssertEqual(agentContextShort(2_000_000), "2M")
        XCTAssertEqual(agentContextShort(200_000), "200K")
    }

    func testInitiallyFoldedLongProviders() {
        var models: [WebJSON] = (0..<9).map { ["id": .string("a/m\($0)"), "name": .string("m\($0)"), "group": "A"] }
        models.append(["id": "b/x", "name": "x", "group": "B"])
        let list = AgentModelList(json: ["models": .array(models)])
        XCTAssertEqual(list.initiallyFolded, ["A"])
    }

    // MARK: 停用的模型

    func testDisabledModels() async throws {
        let settings = WebSettings(json: try WebFixture.json("settings-disabled-models.json"))
        XCTAssertEqual(settings.disabledModels, ["*preview*", "relay-one/o3"])
        XCTAssertEqual(DisabledModels.matches(settings.disabledHits["*preview*"] ?? []),
                       "匹配 5 个：relay-one/gpt-5-preview, deepseek/r2-preview, kimi/k3-preview, glm/glm-5-preview, …")
        XCTAssertEqual(DisabledModels.matches([]), "目前没有匹配的模型；出现时也会被拒绝")
        XCTAssertEqual(DisabledModels.adding(" *fable* ", to: settings.disabledModels), ["*preview*", "relay-one/o3", "*fable*"])
        XCTAssertNil(DisabledModels.adding("RELAY-ONE/O3", to: settings.disabledModels))
        XCTAssertNil(DisabledModels.adding("  ", to: []))
        let choices = DisabledModels.choices(settings)
        XCTAssertEqual(choices.map(\.provider), ["Relay One", "DeepSeek"]) // 路由组不算
        XCTAssertEqual(choices[0].models.map(\.name), ["GPT 4.1", "relay-one/o3"])

        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], try WebFixture.data("settings-disabled-models.json")) }
        _ = try await client.setDisabledModels(["*preview*"])
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/settings/disabled-models")
        XCTAssertEqual(try body(StubURLProtocol.lastRequest), ["models": ["*preview*"]])
    }

    // MARK: 测试模型

    func testProviderModelTests() async throws {
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], try WebFixture.data("provider-test-models.json")) }
        let ids = ["gpt-4.1", "o3", "gpt-5-preview"]
        let results = try await client.testProviderModels("relay-one", models: ids, run: "run-1")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/provider/test")
        XCTAssertEqual(try body(StubURLProtocol.lastRequest), ["id": "relay-one", "test": ["gpt-4.1", "o3", "gpt-5-preview"], "run": "run-1"])
        XCTAssertEqual(ProviderModelTest.detail(results[0]), "通过 OpenAI 协议在 640 毫秒内响应")
        XCTAssertEqual(ProviderModelTest.detail(results[1]), "Responses · 404 · model not found")
        XCTAssertEqual(ProviderModelTest.one(model: "o3", results[1]), "o3 通过 Responses 协议没有响应：404 · model not found")
        XCTAssertEqual(ProviderModelTest.one(model: "gpt-4.1", results[0]), "gpt-4.1 通过 OpenAI 协议在 640 毫秒内响应")
        let summary = ProviderModelTest.summary(ids: ids, results: results)
        XCTAssertFalse(summary.ok)
        XCTAssertEqual(summary.text, "3 个模型中有 2 个没有响应；o3：404 · model not found")
        XCTAssertEqual(ProviderModelTest.summary(ids: ["a"], results: [results[0]]).text, "1 个模型全部可用")
        XCTAssertEqual(ProviderModelTest.took(12_400), "12 秒")

        let provider = WebProvider(raw: ["id": "relay-one", "name": "Relay One",
                                         "models": [["id": "gpt-4.1", "on": true], ["id": "o3", "on": true], ["id": "mini", "on": true], ["id": "off", "on": false]]])
        XCTAssertEqual(ProviderModelTest.models(of: provider), ["gpt-4.1", "o3", "mini"])
        let working = ProviderModelTest.workingOnly(provider, results: ["gpt-4.1": results[0], "o3": results[1]])
        XCTAssertEqual(working.keep, ["gpt-4.1", "mini"]) // 没测的保留
        XCTAssertEqual(working.dropped, 1)
        XCTAssertEqual(ProviderModelTest.droppedSaid(1), "已取消选中 1 个没有响应的模型")
        XCTAssertNil(ProviderModelTest.unavailable(provider))
        XCTAssertNotNil(ProviderModelTest.unavailable(WebProvider(raw: ["id": "x", "name": "X", "modelTest": "own-api"])))

        StubURLProtocol.handler = { _ in (204, [:], Data()) }
        try await client.stopProviderTest(run: "run-1")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/provider/teststop")
        XCTAssertEqual(try body(StubURLProtocol.lastRequest), ["run": "run-1"])
    }
}
