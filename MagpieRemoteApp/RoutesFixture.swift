import Foundation
import MagpieRemoteCore

/// fixture 模式下「路由」页的示例数据：路由组、多 Key 供应商、模型速度，以及按时间推进的实时路由记录。
/// 形状对照 magpie v0.1.2438 的 `GET /api/groups`、`/api/model-speeds`、`/api/gateway/trace`；名字与密钥都是假的。
enum RoutesFixture {
    static let groups: [WebJSON] = [
        ["id": "smart", "name": "聪明组", "members": ["relay-example/gpt-4.1", "deepseek/deepseek-chat"], "routing": "order",
         "rules": [["use": "deepseek/deepseek-chat", "compact": true]]],
        ["id": "fast-first", "name": "最快优先", "members": ["relay-example/o3", "deepseek/deepseek-reasoner", "relay-example/gpt-4.1"],
         "routing": "fast", "affinity": "session", "firstToken": 60, "off": ["relay-example/gpt-4.1"]],
        ["id": "manual-pick", "name": "手动切换", "members": ["relay-example/gpt-4.1", "deepseek/deepseek-chat"], "routing": "manual",
         "pick": "deepseek/deepseek-chat"],
        ["id": "by-weight", "name": "按权重分摊", "members": ["relay-example/gpt-4.1", "deepseek/deepseek-chat"], "routing": "weight",
         "weights": ["relay-example/gpt-4.1": 3]],
        ["id": "auto-deepseek-chat", "name": "deepseek-chat", "members": ["deepseek/deepseek-chat", "relay-example/deepseek-chat"],
         "auto": true],
    ]

    static let pools: [WebJSON] = [
        ["provider": "relay-example", "name": "示例中转", "kind": "key", "who": ["主 Key", "备用 Key"], "routing": "", "affinity": ""],
    ]

    static let speeds: WebJSON = [
        "relay-example/gpt-4.1": ["ttft": 820, "tps": .double(61.5), "n": 14],
        "deepseek/deepseek-chat": ["ttft": 1430, "tps": .double(38.2), "n": 9],
        "relay-example/o3": ["ttft": 2600, "tps": 44, "n": 5],
        "deepseek/deepseek-reasoner": ["ttft": 3100, "tps": .double(29.4), "n": 3],
    ]

    /// 像主机那样给每个组补上 ready / memberInfo / ref / picked。
    static func groupsJSON(groups: [WebJSON], providers: [WebJSON], pools: [WebJSON], found: Bool) -> WebGroups {
        var models: [WebJSON] = []
        for provider in providers where provider["off"]?.bool != true {
            for model in provider["models"]?.array ?? [] where model["on"]?.bool == true {
                models.append(["id": .string("\(provider["id"]?.string ?? "")/\(model["id"]?.string ?? "")"),
                               "name": model["name"] ?? "", "provider": provider["id"] ?? "", "providerName": provider["name"] ?? ""])
            }
        }
        let shown = groups.filter { found || $0["auto"]?.bool != true }
        let decorated = shown.map { decorate($0, providers: providers, groups: shown) }
        return WebGroups(json: ["groups": .array(decorated), "models": .array(models), "pools": .array(pools), "found": .bool(found)])
    }

    static func decorate(_ group: WebJSON, providers: [WebJSON], groups: [WebJSON]) -> WebJSON {
        var group = group
        let id = group["id"]?.string ?? ""
        let members = group["members"]?.strings ?? []
        var info: [WebJSON] = []
        var ready = false
        for member in members {
            if member.hasPrefix("group/") {
                let inner = groups.first { "group/" + ($0["id"]?.string ?? "") == member }
                info.append(["id": .string(member), "group": true, "ready": .bool(inner != nil), "name": inner?["name"] ?? .string(member), "on": 1])
                ready = ready || inner != nil
                continue
            }
            let parts = member.split(separator: ":", maxSplits: 1).map(String.init)
            let of = parts[0]
            let pid = String(of.split(separator: "/").first ?? "")
            let model = String(of.split(separator: "/", maxSplits: 1).last ?? "")
            let provider = providers.first { $0["id"]?.string == pid }
            let on = provider?["models"]?.array?.contains { $0["id"]?.string == model && $0["on"]?.bool == true } ?? false
            let off = provider?["off"]?.bool == true
            var item: WebJSON = ["id": .string(member), "of": .string(of), "on": 1]
            if let provider {
                item["provider"] = .string(pid)
                item["name"] = provider["name"]
                item["model"] = .string(model)
            }
            if parts.count > 1 { item["effort"] = .string(parts[1]) }
            if off { item["providerOff"] = true }
            let isReady = on && !off
            item["ready"] = .bool(isReady)
            item["context"] = model.hasPrefix("deepseek") ? 128_000 : 1_000_000
            if model == "gpt-4.1" { item["images"] = true }
            ready = ready || isReady
            info.append(item)
        }
        group["memberInfo"] = .array(info)
        group["ready"] = .bool(ready)
        group["ref"] = .string(group["auto"]?.bool == true ? "auto/" + id.replacingOccurrences(of: "auto-", with: "") : "group/" + id)
        if group["routing"]?.string == "manual" {
            let pick = group["pick"]?.string.flatMap { members.contains($0) ? $0 : nil } ?? members.first ?? ""
            group["picked"] = .string(pick)
        }
        return group
    }

    // MARK: 实时路由

    private static func stamp(_ date: Date) -> WebJSON {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return .string(formatter.string(from: date))
    }

    /// 每 6 秒来一个新请求：前 0.4 秒路由还没选出谁（喜鹊先飞到 magpie 等），前 2.5 秒在路上，之后回答完；
    /// 每第 3 个请求先被第一个 Key 限流（429），改道到第二个。还有一个备用的订阅账号（名字是邮箱，「账号打码」用）。
    static func trace(elapsed: TimeInterval, now: Date) -> WebJSON {
        let period: TimeInterval = 6
        let current = Int(elapsed / period) + 12 // 先有 11 个已经回答完的（「最近的请求」默认只列 10 个）
        let phase = elapsed.truncatingRemainder(dividingBy: period)
        var routes: [WebJSON] = []
        var done = 0, rerouted = 0
        for number in max(1, current - 13)...current {
            let age = TimeInterval(current - number) * period + phase
            let start = now.addingTimeInterval(-age)
            let inFlight = number == current && phase < 2.5
            let failsFirst = number % 3 == 0
            let agent = number % 2 == 0 ? "claude" : "codex"
            let first: WebJSON = ["id": "relay-example#k1", "provider": "relay-example", "name": "示例中转", "who": "主 Key", "kind": "key",
                                  "model": "gpt-4.1", "routing": "", "used": 0]
            let second: WebJSON = ["id": "deepseek#k1", "provider": "deepseek", "name": "示例 DeepSeek", "who": "sk-d…EXMP", "kind": "key",
                                   "model": "deepseek-chat", "routing": "", "used": 0]
            let spare: WebJSON = ["id": "codex#demo", "provider": "codex", "name": "Codex", "who": "demo.user@example.com", "kind": "account",
                                  "plan": "plus", "model": "gpt-5", "routing": "", "known": true, "used": 41, "fallback": true]
            let picking = number == current && phase < 0.4
            var tries: [WebJSON] = []
            if picking {
                // 路由还没选出谁
            } else if failsFirst {
                tries.append(["id": "relay-example#k1", "model": "gpt-4.1", "start": stamp(start), "done": true, "status": 429, "ms": 380,
                              "fail": "rate", "rest": ["why": "rate", "status": 429, "until": stamp(start.addingTimeInterval(40)), "key": "relay-example#k1"]])
                tries.append(["id": "deepseek#k1", "model": "deepseek-chat", "start": stamp(start.addingTimeInterval(0.4)),
                              "done": .bool(!inFlight), "status": inFlight ? 0 : 200, "ms": inFlight ? 0 : 2100, "ttft": inFlight ? 0 : 1300])
            } else {
                tries.append(["id": "relay-example#k1", "model": "gpt-4.1", "start": stamp(start),
                              "done": .bool(!inFlight), "status": inFlight ? 0 : 200, "ms": inFlight ? 0 : 1800, "ttft": inFlight ? 0 : 790])
            }
            if !inFlight { done += 1 }
            if failsFirst { rerouted += 1 }
            routes.append(["id": .int(Int64(number)), "seq": .int(Int64(number * 2 + (inFlight ? 0 : 1))), "time": stamp(start),
                           "agent": .string(agent), "model": "group/smart", "provider": "relay-example",
                           "group": ["id": "smart", "name": "聪明组", "routing": "order", "members": ["relay-example/gpt-4.1", "deepseek/deepseek-chat"]],
                           "order": [first, second, spare], "tries": .array(tries), "done": .bool(!inFlight), "status": inFlight ? 0 : 200,
                           "ms": inFlight ? 0 : (failsFirst ? 2500 : 1800), "tokens": inFlight ? 0 : 1840, "out": inFlight ? 0 : 320,
                           "session": number % 2 == 0 ? "demo-session-a" : "demo-session-b",
                           "sessionTitle": number % 2 == 0 ? "修复登录页" : "整理周报", "cost": .double(0.0042), "priced": true])
        }
        let seq = Int64(current * 2 + (phase < 2.5 ? 0 : 1))
        return ["seq": .int(seq), "mine": true, "now": stamp(now), "routes": .array(routes),
                "ids": .array(routes.compactMap { $0["id"] }), "totals": ["requests": .int(Int64(done)), "rerouted": .int(Int64(rerouted)), "errors": 0]]
    }
}
