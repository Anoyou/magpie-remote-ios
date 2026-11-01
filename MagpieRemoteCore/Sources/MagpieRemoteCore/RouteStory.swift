import Foundation

// 「路由」页讲一个请求的话：舞台下的一句（caption）、卡片下「最近一个请求是怎么路由的」的每一步、列表行上的去向。
// 逐句移植自 magpie 的 internal/gui/assets/plugins/routing/client.js（firstWhy、trySaid、tryWhy、restHow、noneWhy、
// renderSteps、outcome、dur、took …），中文取自它的 i18n.js（RouteWords）。magpie 以 MIT 许可发布（Copyright (c) 2026 yetone）。
// 网关没给的字段（价格、近来的速度、会话保持的细节、规则……）这里讲不出来，就落到网页同一处的通用说法。

/// 网页的 `t()`：英文原句做键，换成中文并填上 {名字}。
func rt(_ key: String, _ args: [String: String] = [:]) -> String {
    var s = RouteWords.zh[key] ?? key
    for (k, v) in args { s = s.replacingOccurrences(of: "{\(k)}", with: v) }
    return s
}

public enum RouteWords {
    /// App 里用：英文原句换成网页的中文。
    public static func t(_ key: String, _ args: [String: String] = [:]) -> String { rt(key, args) }
    /// 网页 HUES 与 PALETTE（client.js hueOf）：十二个同明度的颜色，Claude 的陶土色在前；没有红色（红色只表示失败）。
    public static let palette = ["#d97757", "#bd8638", "#a59234", "#849e4a", "#5aa66c", "#25a98f", "#00a6b0", "#2e9fc9", "#5e95d7", "#858ad7", "#a47fca", "#bb77b1"]
    public static let hues: [String: Int] = [
        "claude": 0, "codex": 9, "gemini": 7, "copilot": 10, "cursor": 5, "opencode": 2, "crush": 11, "goose": 3, "pi": 4, "omp": 11, "omo": 10,
        "dsh": 6, "commandcode": 1, "mimocode": 8, "deveco": 7,
    ]

    /// 网页 FAIL 的中文。
    public static func failWord(_ why: String) -> String {
        let fail: [String: String] = [
            "rate": "rate limited", "credit": "out of credit", "quota": "quota used up", "other": "failed", "auth": "sign-in required",
            "canceled": "canceled", "foreign": "another account's reasoning", "floor": "reply too short", "verify": "needs verification",
            "refused": "refused (safety filter)", "shape": "request not understood", "sight": "images not taken", "proxy": "proxy not reachable",
            "offline": "network down", "effort": "reasoning effort not in its plan", "overflow": "too long for its model",
            "room": "reply asked past the window left", "slow": "slow to start", "prompt": "agent's prompt turned away",
            "restricted": "account restricted by the vendor",
        ]
        return rt(fail[why] ?? "failed")
    }
    static func knownFail(_ why: String) -> Bool {
        ["rate", "credit", "quota", "other", "auth", "canceled", "foreign", "floor", "verify", "refused", "shape", "sight", "proxy", "offline",
         "effort", "overflow", "room", "slow", "prompt", "restricted"].contains(why)
    }

    /// 网页 dur()：「12 秒」「3 分钟」「2 小时 5 分钟」「5 小时」「2 天」。
    public static func dur(_ seconds: TimeInterval) -> String {
        let s = max(1, Int((seconds).rounded()))
        if s < 60 { return rt("{n} s", ["n": "\(s)"]) }
        let m = Int((Double(s) / 60).rounded())
        if m < 60 { return rt("{n} min", ["n": "\(m)"]) }
        let h = m / 60, mm = m % 60
        if h < 10 && mm > 0 { return rt("{h} h {m} min", ["h": "\(h)", "m": "\(mm)"]) }
        if h < 48 { return rt("{n} h", ["n": "\(Int((Double(m) / 60).rounded()))"]) }
        return rt("{n} d", ["n": "\(Int((Double(m) / 1440).rounded()))"])
    }

    /// 网页 took()：不到 1 秒「380 毫秒」，否则「2.1 秒」（10 秒以上不带小数）。
    public static func took(_ ms: Int) -> String {
        if ms < 1000 { return rt("{n} ms", ["n": "\(ms)"]) }
        let s = Double(ms) / 1000
        return rt("{n} s", ["n": ms < 10_000 ? String(format: "%.1f", s) : String(format: "%.0f", s)])
    }

    /// 网页 tokens()：1.8k、2.3M。
    public static func tokens(_ n: Double) -> String {
        if n >= 1e6 { return String(format: "%.1fM", n / 1e6) }
        if n >= 1e3 { return String(format: "%.1fk", n / 1e3) }
        return "\(Int(n.rounded()))"
    }

    public static func pct(_ n: Double) -> String { "\(Int(n.rounded()))%" }

    /// 网页 modeOf()[0]：路由方式的名字。
    public static func modeName(_ routing: String) -> String {
        let names = ["": "Smart", "order": "In order", "drain": "Until used up", "rotate": "In turn", "usage": "Least used", "pace": "Weekly pace",
                     "manual": "Manual", "weight": "By weight", "free": "Free first", "cheap": "Cheapest first", "fast": "Speed first"]
        if let name = names[routing] { return rt(name) }
        return routing
    }
}

// MARK: 讲一个请求

public enum RouteStory {
    static func who(_ w: TraceSeat) -> String { w.kind == "provider" ? w.name : w.who }
    static func whereTo(_ w: TraceSeat) -> String {
        w.kind == "provider" || w.who.isEmpty ? (w.name.isEmpty ? w.provider : w.name) : "\(w.name.isEmpty ? w.provider : w.name) · \(w.who)"
    }

    static func clock(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        let hm = f.string(from: date)
        if Calendar.current.isDateInToday(date) { return hm }
        f.dateFormat = "EEE"
        return f.string(from: date) + " " + hm
    }

    /// 网页 restWhen()。
    public static func restWhen(_ rest: TraceRest, from: Date) -> String {
        let left = (rest.until ?? from).timeIntervalSince(from)
        return left < 3600 ? rt("back in {d}", ["d": RouteWords.dur(left)])
            : rt("back at {time} · in {d}", ["time": clock(rest.until), "d": RouteWords.dur(left)])
    }

    /// 网页 restSay()：行上「限流 · 37 秒后恢复」。
    public static func restSay(_ rest: TraceRest, now: Date) -> String {
        let prefix = !RouteWords.knownFail(rest.why) || rest.why == "other" ? (rest.status > 0 ? "\(rest.status) · " : "") : ""
        return prefix + RouteWords.failWord(rest.why) + " · " + restWhen(rest, from: now)
    }

    /// 网页 restHow()：失败的账号休息多久、谁说的。
    public static func restHow(_ rest: TraceRest, from: Date) -> String {
        let d = RouteWords.dur((rest.until ?? from).timeIntervalSince(from)), time = clock(rest.until)
        switch rest.by {
        case "retry-after": return rt("It rests {d}, as the vendor's Retry-After says", ["d": d])
        case "credit": return rt("It sits out half an hour, until someone tops it up")
        case "window": return rt("Its allowance is used up: it rests until that renews, at {time}", ["time": time])
        case "resets": return rt("It rests until {time}, when the vendor says the limit resets", ["time": time])
        case "quota": return rt("It rests 15 minutes: out of quota, with no word of when it resets")
        case "credits": return rt("It holds credits, so it rests only {d} and its usage is read again, not until its allowance renews", ["d": d])
        case "verify": return rt("The vendor wants the account verified first: it rests half an hour, or until you say it's verified")
        case "off": return rt("It doesn't rest: its provider is set to ask it again after an error like this")
        case "restricted": return rt("The vendor restricted the account: it rests {d}, as only the vendor lifting the restriction brings it back. Appeal with the vendor; once it's lifted, try it again here", ["d": d])
        case "backoff":
            if rest.why == "rate" { return rt("It was rate limited again as soon as it was back ({n} times in a row): it rests {d}, longer each time until it answers", ["n": "\(rest.failures)", "d": d]) }
            return rest.failures > 1 ? rt("It has failed {n} times in a row: it rests {d}, longer each time", ["n": "\(rest.failures)", "d": d])
                : rt("It rests {d}, longer if it fails again", ["d": d])
        case "cooldown":
            return rest.why == "rate" ? rt("It cools down {d}: the vendor didn't say for how long", ["d": d]) : rt("It rests {d}", ["d": d])
        default: return rt("It rests {d}", ["d": d])
        }
    }

    /// 网页 noneWhy()。
    public static func noneWhy(_ r: TraceRoute) -> String {
        if !r.done { return rt("magpie hasn't routed this request yet, so who takes it isn't picked yet.") }
        if !r.error.isEmpty { return rt("Nothing took this request: {error}", ["error": r.error]) }
        return rt("Nothing could take {model}.", ["model": r.model])
    }

    static func placeRouting(_ r: TraceRoute, _ x: TraceSeat) -> String {
        if let last = x.via.last { return r.groupSubs.first { $0.id == last }?.routing ?? "" }
        return r.groupID != nil ? r.groupRouting : ""
    }
    static func wholeMembers(_ r: TraceRoute, _ x: TraceSeat) -> Bool { r.groupID != nil && ["order", "weight"].contains(placeRouting(r, x)) }
    static func weighedWith(_ r: TraceRoute, _ x: TraceSeat) -> [TraceSeat] {
        let whole = wholeMembers(r, x)
        return r.order.filter { y in
            y.fallback == x.fallback && y.via == x.via
                && (!(x.fallback || whole) || (y.provider == x.provider && y.model == x.model && y.fixed == x.fixed && y.fast == x.fast))
        }
    }
    static func band(_ w: TraceSeat) -> String { w.used >= 98 ? "spent" : w.used >= 90 ? "low" : "fine" }

    /// 网页 firstWhy()：路由为什么把第一个排在那里。
    public static func firstWhy(_ r: TraceRoute) -> String {
        guard let f = r.order.first else { return noneWhy(r) }
        let w = who(f)
        if r.order.count == 1 {
            if f.rest != nil { return rt("{who} is the only one, so it's tried though it is resting.", ["who": w]) }
            return f.kind == "account" ? rt("{who} is the only account on for {model} — nothing to choose between.", ["who": w, "model": r.model])
                : rt("{name} has one key on — nothing to choose between.", ["name": f.name])
        }
        if f.rest != nil { return rt("Every one is resting after a failure, so {who}, first in line, is tried all the same.", ["who": w]) }
        if f.fallback {
            let name = r.order.first { !$0.fallback }?.name ?? r.provider
            return rt("{name} is resting, so its fallback {fb} goes first.", ["name": name, "fb": "\(f.provider)/\(f.model)"])
        }
        if wholeMembers(r, f) {
            let own = weighedWith(r, f)
            if own.count > 1 {
                var inner = r
                inner.order = own
                inner.groupID = nil
                inner.groupSubs = []
                return firstWhy(inner)
            }
            if placeRouting(r, f) == "weight" { return rt("By weight: it's {who}'s share — each model takes requests as the weight set beside it says.", ["who": w]) }
            let ahead = r.order.filter { $0 != f && $0.rest != nil }.map(who)
            return ahead.isEmpty ? rt("In order: {who} is first, and answers everything while it can.", ["who": w])
                : rt("In order: with {rested} resting after a failure, {who} is the first that can answer.", ["rested": ahead.joined(separator: ", "), "who": w])
        }
        let peers = r.order.filter { $0 != f && !$0.fallback && $0.rest == nil }
        let someKnown = r.order.contains(where: \.known)
        let rested = r.order.filter { $0 != f && !$0.fallback && $0.rest != nil }.map(who)
        func restedTo(_ s: String) -> String? {
            rested.isEmpty ? nil : rt("With {rested} resting after a failure, {who} goes first: ", ["rested": rested.joined(separator: ", "), "who": w]) + s
        }
        switch f.routing {
        case "order":
            return rested.isEmpty ? rt("In order: {who} is first, and answers everything while it can.", ["who": w])
                : rt("In order: with {rested} resting after a failure, {who} is the first that can answer.", ["rested": rested.joined(separator: ", "), "who": w])
        case "drain": return rt("Until used up: {who} is the one in use, and answers everything until it is used up.", ["who": w])
        case "rotate": return rt("In turn: it's {who}'s turn — each request starts one further along.", ["who": w])
        case "weight":
            return rt(f.kind == "account" ? "By weight: it's {who}'s share — each account takes requests as its weight says." : "By weight: it's {who}'s share — each key takes requests as its weight says.", ["who": w])
        case "usage":
            if f.balance != nil { return rt("{who} goes first.", ["who": w]) }
            if f.known { return rt("Least used first: {who} has the most of its allowance left — {n} used.", ["who": w, "n": RouteWords.pct(f.used)]) }
            if f.kind == "key" && !someKnown { return rt("Least used first: {who} served the fewest tokens lately — {n}.", ["who": w, "n": RouteWords.tokens(f.tokens)]) }
            return rt("Least used first: {who} goes first.", ["who": w])
        case "pace":
            if f.balance != nil { return rt("{who} goes first.", ["who": w]) }
            if f.known { return rt("Weekly pace: {who} has the most remaining allowance per hour until reset — {n} used.", ["who": w, "n": RouteWords.pct(f.used)]) }
            if f.kind == "key" && !someKnown { return rt("Weekly pace: {who} served the fewest tokens lately — {n}.", ["who": w, "n": RouteWords.tokens(f.tokens)]) }
            return rt("Weekly pace: {who} goes first.", ["who": w])
        default: break
        }
        if f.kind == "key" && !someKnown {
            return restedTo(rt("the others go in their order.")) ?? rt("{who} goes first: keys go in their order, those that suit the request first.", ["who": w])
        }
        if f.kind != "account" && !f.known { return rt("{who} goes first.", ["who": w]) }
        if !f.known && !peers.contains(where: \.known) { return rt("The vendor hasn't said yet what these accounts have left, so they go in their order: {who} first.", ["who": w]) }
        if band(f) == "spent" && f.credits { return rt("Every account is all but used up, so {who} goes first: it goes on on its credits, which the vendor spends once its allowance is used up.", ["who": w]) }
        if band(f) != "fine" {
            return r.order.contains { $0.kind != "account" && $0.known }
                ? rt("Every key and account here is at 90% or more of its allowance, so the one with the most left goes first: {who}, at {n}.", ["who": w, "n": RouteWords.pct(f.used)])
                : rt("Every account is at 90% or more of its allowance, so the one with the most left goes first: {who}, at {n}.", ["who": w, "n": RouteWords.pct(f.used)])
        }
        guard let next = peers.first(where: { $0.known && band($0) == "fine" }) else {
            return rt("{who} goes first: it has quota to spare, and the others are kept for last.", ["who": w])
        }
        let hour: (Date?) -> Int = { $0.map { Int($0.timeIntervalSince1970 / 3600) } ?? 0 }
        let a = hour(f.renews), b = hour(next.renews), start = r.time ?? Date()
        if a != 0 && (b == 0 || a < b), let renews = f.renews {
            return rt("{who} goes first: of those with quota to spare, its allowance renews soonest — in {d} — and what it has left then is lost. {other} renews later and keeps its own.",
                      ["who": w, "d": RouteWords.dur(renews.timeIntervalSince(start)), "other": who(next)])
        }
        if a != 0 { return rt("{who} and {other} renew within the same hour, so the order given stays — and the vendor's prompt cache stays warm.", ["who": w, "other": who(next)]) }
        return rt("{who} goes first, in the order given: when its allowance renews isn't known.", ["who": w])
    }

    /// 网页 trySaid()：一次尝试怎么样了。
    public static func trySaid(_ r: TraceRoute, _ i: Int, agentName: (String) -> String) -> String {
        let tr = r.tries[i], w = r.seat(of: tr), agent = agentName(r.agent)
        var name = w.map { "\(who($0)) (\($0.model))" } ?? tr.id
        if !tr.fixed.isEmpty && tr.fail != "prompt" { name += " " + rt("at {level} reasoning", ["level": tr.fixed]) }
        if !tr.done { return rt("{who} is answering…", ["who": name]) }
        let next = i + 1 < r.tries.count ? r.tries[i + 1] : nil
        let nw = next.flatMap { r.seat(of: $0) }
        let end = (tr.start ?? r.time ?? Date()).addingTimeInterval(Double(tr.ms) / 1000)
        let spent = tr.credits && tr.status < 400 ? rt("Its allowance had just run out and it was refused, so it was asked again at once to spend its credits.") + " " : ""
        if tr.status < 400 && !tr.fail.isEmpty {
            if let rest = tr.rest {
                return rt("{who} began answering, then broke off · {fail}. {agent} got what was said before the error; {how}, so {agent}'s next request goes to another first.",
                          ["who": name, "fail": RouteWords.failWord(tr.fail), "how": restHow(rest, from: end), "agent": agent])
            }
            return rt("{who} began answering, then broke off. {agent} got what was said before the error; the conversation isn't kept on {who} for its next request.", ["who": name, "agent": agent])
        }
        if tr.status < 400 {
            var tk = r.tokens > 0 ? " · " + rt("{n} tokens", ["n": RouteWords.tokens(Double(r.tokens))]) : ""
            if tr.ttft > 0 { tk += " · " + rt("first token in {ms}", ["ms": RouteWords.took(tr.ttft)]) }
            return spent + (i > 0
                ? rt("{who} answered in {ms}{tk}. {agent} got one clean reply and never saw the {n} that failed first.", ["who": name, "ms": RouteWords.took(tr.ms), "tk": tk, "agent": agent, "n": "\(i)"])
                : rt("{who} answered in {ms}{tk}.", ["who": name, "ms": RouteWords.took(tr.ms), "tk": tk]))
        }
        let base = ["who": name, "status": "\(tr.status)", "agent": agent, "fail": RouteWords.failWord(tr.fail)]
        func with(_ more: [String: String]) -> [String: String] { base.merging(more) { $1 } }
        if tr.credits { return rt("{who} answered {status}: its allowance had just run out, but the account holds credits, which the vendor spends once the allowance is used up, so it is asked again at once, before any of the reply reaches {agent}.", base) }
        switch tr.fail {
        case "canceled": return rt("{agent} canceled the request while {who} was answering: nobody failed, so nobody rests and nobody else is asked.", base)
        case "auth":
            return next != nil ? rt("{who} could not authenticate. Sign in again in magpie; this login is not retried. The request went to {next}.", with(["next": nw.map(who) ?? rt("the next")]))
                : rt("{who} could not authenticate. Sign in again in magpie; this login is not retried. No other account could answer.", base)
        case "foreign": return rt("{who} couldn't read the reasoning another account wrote earlier in this conversation, so it is asked again without it, before any of the reply reaches {agent}.", base)
        case "floor": return rt("{who} takes no request for a reply as short as this one asked for, so it is asked again for the shortest it gives, before any of the reply reaches {agent}.", base)
        case "refused":
            return next != nil ? rt("{who}'s safety filter refused the request before saying anything, so it goes on to the next before any of the reply reaches {agent}. Nothing is wrong with {who}, so it doesn't rest.", base)
                : rt("{who}'s safety filter refused the request before saying anything, and nobody is left to try, so {agent} gets an error saying so, not an empty reply to ask again for.", base)
        case "prompt":
            return next != nil ? rt("{who} answered {status}: the vendor turns away {agent}'s system prompt whichever account it goes to, so it goes on to the next before any of the reply reaches {agent}. Nothing is wrong with {who}, so it doesn't rest.", base)
                : rt("{who} answered {status}: the vendor turns away {agent}'s system prompt whichever account it goes to, and nobody else is left to try, so {agent} gets the error. Nothing is wrong with {who}, so it doesn't rest.", base)
        case "sight": return rt("{who} answered {status}: it takes no images, so it is asked again with the images described by the image recognition model, before any of the reply reaches {agent}. Later requests to it are described first. Nothing is wrong with {who}, so it doesn't rest.", base)
        case "shape": return rt("{who} answered {status}: its API couldn't read something in the request that another's may, so it goes on to the next before any of the reply reaches {agent}. Nothing is wrong with {who}, so it doesn't rest.", base)
        case "effort":
            return next != nil ? rt("{who} answered {status}: its plan doesn't take the reasoning effort asked for, so another account goes on with it before any of the reply reaches {agent}. {who} serves other efforts, so it doesn't rest.", base)
                : rt("{who} answered {status}: its plan doesn't take the reasoning effort asked for, and no account left that does could answer, so {agent} gets an error saying so.", base)
        case "slow":
            if next == nil && r.done { return rt("{who} hadn't begun answering after {ms}, and nobody is left to try, so {agent} gets the error.", with(["ms": RouteWords.took(tr.ms)])) }
            if let rest = tr.rest {
                return rt("{who} hadn't begun answering after {ms}, {n} times in a row, so the request went on to the next before any of it reached {agent}. It rests {d} for {model} alone, longer each time it is slow again; its other models answer as before.",
                          with(["ms": RouteWords.took(tr.ms), "n": "\(rest.failures)", "model": rest.model.isEmpty ? tr.model : rest.model, "d": RouteWords.dur((rest.until ?? end).timeIntervalSince(end))]))
            }
            return rt("{who} hadn't begun answering after {ms}, so the request went on to the next before any of it reached {agent}. Nothing is wrong with {who}, so it doesn't rest.", with(["ms": RouteWords.took(tr.ms)]))
        case "offline":
            return next != nil ? rt("{who}: this computer had no network, so the request never reached the vendor and goes on to the next. Nothing is wrong with {who}, so it doesn't rest: once the network is back it is asked first again.", base)
                : rt("{who}: this computer had no network, so the request never reached the vendor, and nobody is left to try: {agent} gets the error. Nothing is wrong with {who}, so it doesn't rest.", base)
        case "proxy":
            return next != nil ? rt("{who}: the proxy magpie goes through didn't take the connection, so the request never reached the vendor and goes on to the next. Nothing is wrong with {who}, so it doesn't rest: once the proxy is up it is asked first again.", base)
                : rt("{who}: the proxy magpie goes through didn't take the connection, so the request never reached the vendor, and nobody is left to try: {agent} gets the error. Start the proxy, or change it in Settings.", base)
        default: break
        }
        if tr.fail == "verify" && next == nil {
            return rt("{who} answered {status}: the vendor wants the account verified before it serves it again, and nobody is left to try, so {agent} gets the error with how to verify it. For a minute {agent}'s retries get the same answer without asking the vendor.", base)
        }
        if tr.gone { return rt("{who} answered {status} · {fail}, and was to be asked again in {d}, but {agent} canceled the request before then, so nobody is asked again.", with(["d": RouteWords.took(tr.again)])) }
        if tr.again > 0 { return rt("{who} answered {status} · {fail}, and nobody else is left to ask — a failure that may pass, so it is tried again in {d}, before any of the reply reaches {agent}.", with(["d": RouteWords.took(tr.again)])) }
        if tr.earlier && next == nil { return rt("{who} answered {status} and nobody is left to try. {agent} gets the error an earlier try gave, not this used-up allowance, so it doesn't stop as if every account were out.", base) }
        if next == nil && !r.done { return rt("{who} answered {status}.", base) }
        let how = tr.rest.map { restHow($0, from: end) } ?? ""
        if next != nil {
            return tr.rest != nil
                ? rt("{who} answered {status} · {fail}. {how}; the request goes on to {next} before any of the reply reaches {agent}.", with(["how": how, "next": nw.map(who) ?? rt("the next")]))
                : rt("{who} answered {status}, and the request goes on to {next} before any of the reply reaches {agent}. {who} doesn't rest for it.", with(["next": nw.map(who) ?? rt("the next")]))
        }
        if tr.rest != nil { return rt("{who} answered {status} · {fail}. {how}; nobody is left to try, so {agent} gets the error.", with(["how": how])) }
        return i >= r.order.count - 1 ? rt("{who} answered {status} and nobody is left to try, so {agent} gets the error.", base)
            : rt("{who} answered {status} — an error another account wouldn't fix, so {agent} gets it.", base)
    }

    /// 网页 treeText()：组的成员（没有子组时用 → 连起来的成员）。
    static func members(_ r: TraceRoute) -> String {
        var seen: [String] = []
        for w in r.order where !w.fallback {
            let name = "\(w.provider)/\(w.model)"
            if !seen.contains(name) { seen.append(name) }
        }
        return seen.joined(separator: ", ")
    }

    /// 一步（网页 rt-steps 的 li）。kind：asked（无点）、why、ok、bad、wait、aside、said。
    public struct Step: Hashable, Sendable {
        public enum Kind: Hashable, Sendable { case asked, why, ok, bad, wait, aside, said }
        public var text: String
        public var kind: Kind
        /// 这一步讲的是哪个座位（画它的标志）。
        public var seat: TraceSeat?
    }

    /// 网页 renderSteps()：这个请求是怎么路由的，一步一句。
    public static func steps(_ r: TraceRoute, agentName: (String) -> String) -> [Step] {
        var items: [Step] = []
        let agent = agentName(r.agent)
        let main = r.order.first { !$0.fallback }
        if let name = r.groupName, r.groupID != nil {
            items.append(Step(text: rt("{agent} asked for the routing group {name}: {members}", ["agent": agent, "name": name, "members": members(r)]), kind: .asked))
        } else if let main, main.model != r.model {
            items.append(Step(text: rt("{agent} asked for {model}: {name} serves it, and the vendor is asked for {sent}", ["agent": agent, "model": r.model, "name": main.name, "sent": main.model]), kind: .asked))
        } else {
            items.append(Step(text: rt("{agent} asked for {model}", ["agent": agent, "model": r.model]) + " → " + (main?.name ?? r.provider), kind: .asked))
        }
        items.append(Step(text: firstWhy(r), kind: .why, seat: r.order.first))
        for (i, tr) in r.tries.enumerated() {
            items.append(Step(text: trySaid(r, i, agentName: agentName), kind: tr.done ? (tr.ok ? .ok : .bad) : .wait, seat: r.seat(of: tr)))
            if tr.done && !tr.ok && !tr.error.isEmpty {
                let said = tr.error.count > 600 ? String(tr.error.prefix(600)) + "…" : tr.error
                items.append(Step(text: rt("It said: {error}", ["error": said]), kind: .said))
            }
        }
        if r.done && r.tries.isEmpty { items.append(Step(text: rt("Nothing was tried: {error}", ["error": r.error.isEmpty ? "\(r.status)" : r.error]), kind: .bad)) }
        return items
    }

    /// 网页 outcome()：列表行上的去向，和那一行的样子。
    public enum Outcome: Hashable, Sendable { case wait, ok, moved, bad }
    public static func outcome(_ r: TraceRoute) -> (said: String, how: Outcome) {
        if !r.done {
            if let tr = r.tries.last, let w = r.seat(of: tr) { return (rt("{who} is answering…", ["who": "\(who(w)) · \(w.model)"]), .wait) }
            return (rt("routing…"), .wait)
        }
        let ok = r.tries.first { $0.done && $0.ok }
        if r.status < 400 && (ok != nil || r.tries.isEmpty) {
            let w = ok.flatMap { r.seat(of: $0) }
            return (w.map { "\(who($0)) · \($0.model)" } ?? r.provider, r.tries.count > 1 ? .moved : .ok)
        }
        if let last = r.tries.last { return ("\(r.status) · \(RouteWords.failWord(last.gone ? "canceled" : last.fail))", .bad) }
        return ("\(r.status > 0 ? "\(r.status)" : "") \(r.error)".trimmingCharacters(in: .whitespaces), .bad)
    }

    /// 网页 failedRoute()：Agent 拿到了错误。
    public static func failed(_ r: TraceRoute) -> Bool { r.done && outcome(r).how == .bad }

    /// 舞台下那句话最先说的（网页 sync 后的 `say(affWhy || ruleWhy || firstWhy)`）。
    public static func lead(_ r: TraceRoute) -> String { firstWhy(r) }
}

// MARK: 颜色

/// 网页 hueOf()：每个 Agent 要它厂商的颜色（HUES 是 PALETTE 里的位置），或按 id 算一个，再从那里往后找第一个别的 Agent
/// 还没用过的；这一页开着时一直不变。同时在台上的（hues）彼此错开。
public final class AgentHues: @unchecked Sendable {
    public static let shared = AgentHues()
    private var given: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func hue(_ id: String, near: Set<String>? = nil) -> String {
        lock.lock(); defer { lock.unlock() }
        return hueLocked(id, near: near)
    }

    private func hueLocked(_ id: String, near: Set<String>?) -> String {
        if let c = given[id], !(near?.contains(c) ?? false) { return c }
        var h: Int
        if let pref = RouteWords.hues[id] { h = pref } else {
            var x: UInt32 = 0
            for unit in id.utf16 { x = x &* 31 &+ UInt32(unit) }
            h = Int(x % UInt32(RouteWords.palette.count))
        }
        let palette = RouteWords.palette
        let had = Set(given.values)
        func from(_ k: Int) -> String { palette[(h + k) % palette.count] }
        let ks = Array(palette.indices)
        let k = ks.first { !had.contains(from($0)) && !(near?.contains(from($0)) ?? false) } ?? ks.first { !(near?.contains(from($0)) ?? false) } ?? 0
        let c = from(k)
        given[id] = c
        return c
    }

    /// 网页 hues()：一起上台的 Agent 各用各的颜色。
    public func spread(_ ids: [String]) {
        lock.lock(); defer { lock.unlock() }
        var near = Set<String>()
        for id in ids { near.insert(hueLocked(id, near: near)) }
    }
}
