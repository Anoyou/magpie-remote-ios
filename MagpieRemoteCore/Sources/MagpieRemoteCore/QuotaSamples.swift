import Foundation

/// fixture 模式（UI 测试、演示）用的示例额度数据：全部是假账号（@example.com），时间相对「现在」生成，
/// 并且故意走一遍 JSON 解码（RFC 3339 带纳秒，与真实 magpie 一致），保证示例和真实接口走同一条路径。
public enum QuotaSamples {
    public static func cards(now: Date = Date()) -> [QuotaCard] {
        let json = """
        {"object":"list","data":[
          {"provider":"claude","name":"Claude","icon":"claude","plan":"Max 5x","user":"work@example.com","alias":"工作 Claude",
           "windows":[{"name":"5 hours","used":37,"resetsAt":"\(rfc(now, 2 * 3600 + 18 * 60))"},
                      {"name":"Week","used":61.5,"resetsAt":"\(rfc(now, 3 * 86400 + 6 * 3600))"}],
           "readAt":"\(rfc(now, -90))","kind":"subscription"},
          {"provider":"claude","name":"Claude","icon":"claude","plan":"Pro","user":"me@example.com",
           "windows":[{"name":"5 hours","used":92,"resetsAt":"\(rfc(now, 47 * 60))"},
                      {"name":"Week","used":40,"resetsAt":"\(rfc(now, 5 * 86400))"}],
           "readAt":"\(rfc(now, -4 * 60))","kind":"subscription"},
          {"provider":"codex","name":"Codex","icon":"codex","plan":"Plus","user":"me@example.com",
           "windows":[{"name":"5 hours","used":100,"resetSecs":5400},
                      {"name":"Week","used":44,"resetsAt":"\(rfc(now, 2 * 86400 + 3 * 3600))"}],
           "readAt":"\(rfc(now, -10 * 60))","kind":"subscription"},
          {"provider":"zai","name":"Z.ai Coding Plan","icon":"zai","plan":"Pro",
           "windows":[{"name":"5 hours","used":12.4,"display":"248 / 2000","resetsAt":"\(rfc(now, 4 * 3600))"}],
           "until":"\(rfc(now, 44 * 86400))","renew":"auto","readAt":"\(rfc(now, -60))","kind":"plan"},
          {"provider":"deepseek","name":"DeepSeek","icon":"deepseek","windows":null,"balance":"¥ 23.71",
           "readAt":"\(rfc(now, -60))","kind":"balance"}
        ]}
        """
        return (try? JSONDecoder().decode(QuotaList<QuotaCard>.self, from: Data(json.utf8)).data) ?? []
    }

    /// 刷新后的卡片：读取时间更新为「现在」，用量略有变化。
    public static func refreshedCards(now: Date = Date()) -> [QuotaCard] {
        cards(now: now).map { card in
            var card = card
            card.readAt = now
            card.windows = card.windows.map { window in
                var window = window
                if let used = window.used, used < 100 { window.used = min(100, used + 1) }
                return window
            }
            return card
        }
    }

    /// 历史曲线：每个账号的每个窗口一条线，点的间隔随天数变化。
    public static func history(days: Int, now: Date = Date()) -> [QuotaHistorySeries] {
        let span = TimeInterval(min(max(days, 1), 45)) * 86400
        let accounts: [(String, String?, [(String, TimeInterval, Double)])] = [
            ("claude", "work@example.com", [("5 hours", 5 * 3600, 63), ("Week", 7 * 86400, 38.5)]),
            ("claude", "me@example.com", [("5 hours", 5 * 3600, 8), ("Week", 7 * 86400, 60)]),
            ("codex", "me@example.com", [("Week", 7 * 86400, 56)]),
            ("zai", nil, [("5 hours", 5 * 3600, 87.6)]),
        ]
        let step = max(span / 84, 1800)
        return accounts.enumerated().map { index, account in
            let lines = account.2.map { name, cycle, currentLeft in
                var points: [QuotaHistoryPoint] = []
                var t = now.addingTimeInterval(-span)
                while t < now {
                    let phase = (t.timeIntervalSince1970 + Double(index) * 3600).truncatingRemainder(dividingBy: cycle) / cycle
                    let depth = 100 - currentLeft
                    let left = max(0, 100 - phase * min(100, depth * 1.3 + 10))
                    points.append(QuotaHistoryPoint(at: t, left: (left * 10).rounded() / 10))
                    t = t.addingTimeInterval(step)
                }
                points.append(QuotaHistoryPoint(at: now, left: currentLeft))
                return QuotaHistoryLine(name: name, points: points)
            }
            return QuotaHistorySeries(provider: account.0, user: account.1, lines: lines)
        }
    }

    /// 受限密钥看到的自己的限额（形状同 live 抓包 held-limit.json）。
    public static func heldKeyLimit(now: Date = Date()) -> KeyLimit {
        let json = """
        {"expires":"\(rfc(now, 50 * 60))","key":"iPhone 临时密钥","limited":true,
         "limit":{"period":"hours","hours":1,"start":"\(rfc(now, -10 * 60))","reset":"\(rfc(now, 50 * 60))",
                  "calls":12,"tokens":6230,"cost":0,"unpriced":1,"tokenLimit":10000,"tokensLeft":3770,"costLeft":0,"spent":false},
         "limits":[{"period":"hours","hours":1,"start":"\(rfc(now, -10 * 60))","reset":"\(rfc(now, 50 * 60))",
                    "calls":12,"tokens":6230,"cost":0,"unpriced":1,"tokenLimit":10000,"tokensLeft":3770,"costLeft":0,"spent":false}],
         "issuerLimits":[{"period":"day","start":"\(rfc(now, -8 * 3600))","reset":"\(rfc(now, 16 * 3600))",
                    "calls":40,"tokens":44532,"cost":0.5172,"tokenLimit":200000,"costLimit":5,"tokensLeft":155468,"costLeft":4.4828,"spent":false}]}
        """
        return (try? JSONDecoder().decode(KeyLimit.self, from: Data(json.utf8))) ?? KeyLimit(limited: false)
    }

    /// RFC 3339，带 9 位小数与 +08:00，与 Go `time.Time` 的写法一致。
    static func rfc(_ now: Date, _ offset: TimeInterval) -> String {
        let date = now.addingTimeInterval(offset)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let whole = calendar.date(from: c) ?? date
        let nanos = max(0, min(999_999_999, Int((date.timeIntervalSince(whole) * 1e9).rounded())))
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let time = String(format: "%02d:%02d:%02d.%09d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0, nanos)
        return day + "T" + time + "+08:00"
    }
}
