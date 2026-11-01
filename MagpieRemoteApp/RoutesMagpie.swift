import Foundation
import SwiftUI

// 路由舞台上飞的喜鹊与 magpie 的标志：移植自 magpie 网页（MIT，Copyright (c) 2026 yetone，见 THIRD_PARTY_NOTICES.md）。
// - 标志：internal/gui/assets/index.html 里的 <path id="bird">（viewBox 0 0 44 44，fill-rule evenodd），网页的 .rt-hub 用它。
// - 喜鹊：internal/gui/assets/plugins/routing/client.js 的 FLIER 与 routing.css 的 .rt-flier / @keyframes rtflap / .rt-lift。
//   一只喜鹊把每个请求衔出去，另一只把回答衔回来——点就在它嘴尖上。它们沿线、从卡片下面飞过；
//   头朝飞的方向（向左飞时整只翻过来），倾斜不超过 24°，像鸟转弯那样慢慢转过去；翅膀从肩膀扇动：用力扇下，轻轻收起。

// MARK: - 纯几何（只用 Foundation，Linux 上可单独编译测试）

/// 网页里的原始 SVG 路径数据，一字未改。
enum MagpieArt {
    /// index.html 的 `#bird`。
    static let logo = """
        M1.5 5.5C1.3 5.7 1.2 6.5 1.2 6.9C1.2 6.9 1.2 7 1.2 7.1C1.1 7.4 1.3 8 1.4 8.3C1.4 8.4 1.5 8.5 1.5 8.7
        C1.5 8.9 1.7 9 1.8 9.3C2.2 9.9 2.2 10 2.3 10.1C2.4 10.2 2.5 10.3 2.6 10.5C2.8 10.8 3 11.1 3.2 11.3
        C3.3 11.3 3.4 11.6 3.6 11.8C3.8 12 4.1 12.4 4.2 12.5C4.7 13 5.2 13.7 5.4 13.9C6 14.5 6.5 15.1 6.7 15.3
        C6.7 15.4 6.9 15.5 6.9 15.7C7.3 15.9 7.7 16.5 7.9 16.8C7.9 16.8 8 16.9 8 16.9C8.1 16.9 8.2 17.2 8.2 17.3
        C8.2 17.3 8.1 17.2 8.1 17.1C7.9 16.9 7.9 16.9 7.6 16.6C7.5 16.5 7.4 16.5 7.4 16.3C7.2 16.2 6.7 15.7 6.3 15.2
        C6.1 15.1 6 14.9 6 14.9C5.9 14.8 5.7 14.7 5.7 14.6C5.6 14.5 5.4 14.3 5.3 14.2C5.1 14.1 4.9 13.8 4.7 13.5
        C4.5 13.3 4.2 13.1 4.1 12.9C4.1 12.9 3.8 12.7 3.8 12.5C3.5 12.3 3 11.8 2.8 11.4C1.8 10.5 0.9 9.6 0.7 9.6
        C0.6 9.7 0.6 9.8 0.5 10C0.5 10.1 0.6 10.2 0.5 10.3C0.5 10.4 0.6 10.5 0.6 10.6C0.5 10.7 0.5 10.9 0.6 11
        C0.5 11.1 0.6 11.4 0.6 11.5C0.9 12.9 1.3 13.8 2.8 14.9C2.9 15.1 3.3 15.3 3.4 15.4C3.4 15.5 3.6 15.6 3.7 15.7
        C4.2 16 6.4 17.8 7 18.4C7.4 18.8 7.4 18.8 7.5 18.9C7.6 19 7.7 19 7.7 19.1C7.7 19.2 7.8 19.2 7.9 19.2
        C7.9 19.3 8.1 19.4 8.1 19.5C8.2 19.6 8.2 19.7 8.3 19.7C8.3 19.7 8.3 19.7 8.2 19.7C8.2 19.6 8.1 19.6 8 19.6
        C7.9 19.5 7.9 19.4 7.8 19.4C7.7 19.3 7.6 19.2 7.6 19.2C7.6 19.1 7.5 19 7.3 18.9C7.2 18.9 6.9 18.6 6.7 18.4
        C6.1 17.8 4.5 16.6 3.5 16C3.4 15.8 3 15.6 2.9 15.5C2.6 15.3 1.5 14.6 0.9 14.3C0.7 14.1 0.6 14.1 0.6 14.2
        C0.5 14.5 0.8 15.9 0.9 16.1C0.9 16.2 1 16.2 0.9 16.3C1.2 16.8 1.9 17.6 2.7 18.3C2.8 18.5 4 19.2 4.7 19.5
        C6.2 20.5 6.6 20.7 7.4 21.5C8.2 22.2 8.7 22.7 9.3 23.6C9.5 24.1 9.9 24.4 10.3 25.3
        C10.4 25.5 10.5 25.8 10.5 25.8C10.7 25.8 10.8 25.7 11 25.4C11.6 25 11.9 24.6 12.3 24.3C12.8 24 13 23.8 13 23.7
        C13.1 23.7 13.1 23.8 13 24C12 24.8 11 26 10.2 26.9C10.1 27.1 9.9 27.5 9.7 27.7C9.5 27.8 9.4 28 9.4 28
        C9.4 28 9.3 28.3 9.1 28.5C8.6 29.2 7.7 30.8 7.7 30.9C7.7 31 7.8 31 8.3 30.8C9 30.4 9.5 30.2 10.4 30
        C11.7 29.6 12.5 29.6 11.6 30C10.5 30.2 9.7 30.6 9.2 31.2C8.8 31.7 8.8 31.7 9.3 31.7
        C10.1 31.8 10.9 31.9 11.6 32.2C12.8 32.7 13.5 33.1 15.5 34.8C16.4 35.5 17.3 36.2 17.8 36.4
        C17.9 36.5 18.1 36.7 18.2 36.8C19.1 37.3 21.2 38.1 22.3 38.3C22.4 38.3 22.7 38.3 22.8 38.3
        C22.8 38.5 23 38.5 23 38.5C23.1 38.5 23.2 38.5 23.3 38.5C23.6 38.6 25.9 38.6 26.1 38.5
        C26.2 38.5 26.3 38.5 26.4 38.5C26.5 38.5 26.6 38.5 26.7 38.3C26.7 38.3 27 38.3 27.1 38.3
        C28.3 38.1 30.2 37.3 31.4 36.7C31.5 36.7 31.7 36.4 31.8 36.4C32.2 36.2 33.2 35.4 33.4 35.2
        C34.2 34.5 35.5 33 35.8 32.6C35.8 32.5 36 32.2 36.1 32C36.4 31.8 36.6 31.4 36.6 31.2
        C36.7 31.1 36.8 30.9 36.9 30.8C37.2 30.4 37.5 29.6 37.7 29.2C37.7 29.1 37.8 28.7 37.9 28.7
        C38.1 28.5 38.4 27.1 38.5 26.8C39 25.2 39.1 23.7 39 22.4C39 22.2 38.9 21.9 38.9 21.8
        C38.9 21.7 38.9 21.6 38.9 21.4C38.6 20.5 38.5 19.9 38.2 19C37.9 18.5 37.5 17.5 37.3 17.2
        C37 16.8 36.8 15.8 36.8 15.2C36.8 13.8 37.7 12.7 39.6 12.2C40.1 12.1 41.3 11.8 42.1 11.7
        C43.5 11.5 43.5 11.5 43.4 11.3C42.9 10.7 40.9 9.9 39.2 9.7C37.9 9.5 38.1 9.5 37.6 9C37 8.6 36.4 8 36 7.9
        C36 7.8 35.8 7.8 35.7 7.7C35.1 7.3 34.2 7 33.1 6.9C32.6 6.7 31.6 6.9 31 7C29.6 7.3 28.3 8 27.3 9.2
        C26.7 9.8 26.2 10.8 25.7 11.7C25.5 12.1 24.8 13.4 24.7 13.7C24.6 13.9 24.5 14.1 24.1 14.7
        C23.5 15.7 22.1 16.9 20.6 17.8C20.5 18 20.3 18.2 20.1 18.3C19.7 18.5 19.4 18.8 19.1 19
        C18.9 19.1 18.7 19.3 18.5 19.4C18 19.8 17.2 20.3 17 20.5C16.9 20.5 16.8 20.6 16.7 20.7
        C16.3 20.8 16.1 20.9 16 20.9C15.5 20.8 14.9 20.5 14.2 20.2C13.7 19.8 12.7 18.9 12.4 18.6
        C12.3 18.5 12.2 18.4 12.1 18.2C11.9 18 11.2 17.1 11 16.6C10.9 16.5 10.8 16.4 10.7 16.3
        C10.7 16.2 10.6 16.1 10.6 15.9C10.5 15.9 10.4 15.7 10.4 15.6C10.3 15.5 10.2 15.2 10.1 15
        C10 14.8 9.8 14.4 9.7 14.2C9.6 14 9.5 13.7 9.4 13.6C9.4 13.4 9.3 13.2 9.2 13C9.2 12.8 9 12.6 9 12.5
        C8.9 12.3 8.7 12.1 8.7 12C8.7 12 8.5 11.7 8.5 11.7C8.3 11.2 8.2 10.9 7.5 10C6.4 8.3 4.2 6.4 2.7 5.8
        C2 5.5 1.6 5.4 1.5 5.5ZM28.4 16.7C29.2 16.9 29.7 17.2 29.9 17.7C30.1 18.2 30 18.9 29.6 19.4
        C29.2 19.9 28.2 20.9 27.6 21.2C26.8 21.7 25.3 22.4 24.2 22.7C23.9 22.8 23.6 22.9 23.5 22.9
        C22.8 23.2 20.7 23.7 19.6 24C19 24.2 18.4 24.3 18.1 24.4C17.9 24.4 16.1 24.9 15.3 25.1
        C14.6 25.2 14.7 25.1 15.7 23.6C16.4 22.7 18.5 20.6 19.4 19.9C20.8 18.8 21.4 18.4 23.2 17.6
        C23.8 17.4 25.6 16.8 25.9 16.8C25.9 16.8 26.3 16.8 26.6 16.7C26.8 16.7 28.2 16.7 28.4 16.7ZM30.4 20.2
        C30.5 20.3 30.6 20.6 30.6 20.7C31.7 23.1 33.4 24.6 35.6 25.3C36.1 25.5 36.7 25.7 37.2 25.8
        C37.7 25.8 37.8 25.9 37.8 26.1C37.7 26.2 37.7 26.3 37.7 26.5C37.7 26.6 37.7 26.8 37.6 27
        C37.4 28.5 36.8 29.9 36.1 31C36.1 31.2 35.9 31.4 35.9 31.6C35.7 31.9 35.2 32.6 34.7 33.3
        C32.6 35.6 29.7 37.3 26.6 37.8C26.5 37.8 26.3 37.9 26.2 37.9C25.8 37.9 23.7 37.9 23.3 37.9
        C23.2 37.9 23 37.8 22.9 37.8C21.1 37.6 19.3 36.8 18 35.7C17.7 35.4 17 34.7 16.8 34.5
        C16.3 33.8 16.1 33 16.3 32.5C16.5 31.8 16.8 31.6 17.9 31.1C19.1 30.5 19.4 30.4 20.2 30
        C21.4 29.4 23.2 28.4 23.9 27.9C23.9 27.8 24.2 27.7 24.5 27.6C26.3 26.3 28 24.6 28.9 22.9
        C29.5 22.2 29.7 21.6 29.9 20.7C30.1 20 30.2 19.9 30.4 20.2Z
        """

    // client.js 的 FLIER：面朝右，原点是嘴尖前点的位置（外层再套 scale(1.2) translate(-6.5 3.2)）。
    static let farWing = "M-14.5 -3.4C-16.5 -9.5 -14.2 -15 -8.6 -18.6C-9.4 -12.6 -9.6 -7.4 -9.2 -3.2Z"
    static let tail = "M-31.5 3.1L-18.6 -1.8L-17.4 1.2L-30.8 4.6Z"
    static let beak = "M-2.3 -4.8L1.4 -3.3L-2.3 -2.2Z"
    static let nearWing = "M-15.6 -3.2C-17.8 -10.2 -15.2 -16.4 -8.4 -20.4C-9.3 -13.6 -9.4 -7.8 -8.8 -2.8Z"
    static let bar = "M-14.6 -5.6C-15.4 -10.4 -13.8 -14.4 -10.4 -17.2"
    // <ellipse class="body" cx="-12.2" cy="-1.4" rx="7.6" ry="3.9"/>
    static var body: CGRect { CGRect(x: -12.2 - 7.6, y: -1.4 - 3.9, width: 7.6 * 2, height: 3.9 * 2) }
    // <ellipse class="belly" cx="-12.8" cy="0.4" rx="4.3" ry="1.6"/>
    static var belly: CGRect { CGRect(x: -12.8 - 4.3, y: 0.4 - 1.6, width: 4.3 * 2, height: 1.6 * 2) }
    // <circle class="body" cx="-4.9" cy="-3.7" r="3.1"/>
    static var head: CGRect { CGRect(x: -4.9 - 3.1, y: -3.7 - 3.1, width: 3.1 * 2, height: 3.1 * 2) }
}

enum SVGPathCommand {
    case move(CGPoint)
    case line(CGPoint)
    case quad(control: CGPoint, to: CGPoint)
    case cubic(control1: CGPoint, control2: CGPoint, to: CGPoint)
    case close
}

/// 只读网页里用到的绝对坐标命令：M L H V Q C Z（M 后面接着的坐标按 L 处理）。
enum SVGPathParser {
    private enum Token {
        case command(UInt8)
        case number(CGFloat)
    }

    private static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }

    private static func tokens(_ d: String) -> [Token] {
        let chars = Array(d.utf8)
        var out: [Token] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let letter = (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
            if letter && c != 101 && c != 69 { // e / E 只出现在数字的指数里
                out.append(.command(c))
                i += 1
                continue
            }
            if c == 45 || c == 43 || c == 46 || isDigit(c) {
                var j = i
                if chars[j] == 45 || chars[j] == 43 { j += 1 }
                var dot = false
                while j < chars.count {
                    let x = chars[j]
                    if isDigit(x) {
                        j += 1
                    } else if x == 46 && !dot {
                        dot = true
                        j += 1
                    } else {
                        break
                    }
                }
                if j < chars.count && (chars[j] == 101 || chars[j] == 69) {
                    var k = j + 1
                    if k < chars.count && (chars[k] == 45 || chars[k] == 43) { k += 1 }
                    if k < chars.count && isDigit(chars[k]) {
                        while k < chars.count && isDigit(chars[k]) { k += 1 }
                        j = k
                    }
                }
                if let value = Double(String(decoding: chars[i..<j], as: UTF8.self)) {
                    out.append(.number(CGFloat(value)))
                }
                i = max(j, i + 1)
                continue
            }
            i += 1 // 空格、逗号
        }
        return out
    }

    static func parse(_ d: String) -> [SVGPathCommand] {
        let tokens = tokens(d)
        var out: [SVGPathCommand] = []
        var i = 0
        var command: UInt8 = 0
        var current = CGPoint.zero
        var start = CGPoint.zero

        func numbers(_ n: Int) -> [CGFloat]? {
            guard i + n <= tokens.count else { return nil }
            var values: [CGFloat] = []
            for token in tokens[i..<(i + n)] {
                guard case .number(let value) = token else { return nil }
                values.append(value)
            }
            i += n
            return values
        }

        while i < tokens.count {
            if case .command(let c) = tokens[i] {
                command = c
                i += 1
                if c == 90 || c == 122 { // Z z
                    out.append(.close)
                    current = start
                }
                continue
            }
            switch command {
            case 77: // M
                guard let n = numbers(2) else { return out }
                current = CGPoint(x: n[0], y: n[1])
                start = current
                out.append(.move(current))
                command = 76
            case 76: // L
                guard let n = numbers(2) else { return out }
                current = CGPoint(x: n[0], y: n[1])
                out.append(.line(current))
            case 72: // H
                guard let n = numbers(1) else { return out }
                current = CGPoint(x: n[0], y: current.y)
                out.append(.line(current))
            case 86: // V
                guard let n = numbers(1) else { return out }
                current = CGPoint(x: current.x, y: n[0])
                out.append(.line(current))
            case 81: // Q
                guard let n = numbers(4) else { return out }
                current = CGPoint(x: n[2], y: n[3])
                out.append(.quad(control: CGPoint(x: n[0], y: n[1]), to: current))
            case 67: // C
                guard let n = numbers(6) else { return out }
                current = CGPoint(x: n[4], y: n[5])
                out.append(.cubic(control1: CGPoint(x: n[0], y: n[1]), control2: CGPoint(x: n[2], y: n[3]), to: current))
            default:
                return out
            }
        }
        return out
    }
}

/// CSS 的 cubic-bezier() 时间函数。
struct CubicTiming {
    let x1: Double, y1: Double, x2: Double, y2: Double

    static let ease = CubicTiming(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1)
    static let easeOut = CubicTiming(x1: 0, y1: 0, x2: 0.58, y2: 1)
    /// rtflap：cubic-bezier(.45, 0, .3, 1)
    static let flap = CubicTiming(x1: 0.45, y1: 0, x2: 0.3, y2: 1)
    /// .rt-lift 的 transition：cubic-bezier(.3, 0, .2, 1)
    static let lift = CubicTiming(x1: 0.3, y1: 0, x2: 0.2, y2: 1)

    private func curve(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let c = 3 * p1, b = 3 * (p2 - p1) - c, a = 1 - c - b
        return ((a * t + b) * t + c) * t
    }

    private func slope(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let c = 3 * p1, b = 3 * (p2 - p1) - c, a = 1 - c - b
        return (3 * a * t + 2 * b) * t + c
    }

    func callAsFunction(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        var t = x
        for _ in 0..<8 {
            let error = curve(t, x1, x2) - x
            if abs(error) < 1e-6 { return curve(t, y1, y2) }
            let d = slope(t, x1, x2)
            if abs(d) < 1e-6 { break }
            t -= error / d
            if t < 0 || t > 1 { break }
        }
        var lo = 0.0, hi = 1.0
        t = x
        for _ in 0..<50 {
            let value = curve(t, x1, x2)
            if abs(value - x) < 1e-7 { break }
            if value < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return curve(t, y1, y2)
    }
}

/// 喜鹊的动作（routing.css）。
enum MagpieMotion {
    /// 网页每帧（按 60 帧算）把头的倾角向目标转 12%。
    static let frame: TimeInterval = 1.0 / 60
    /// @keyframes rtflap：0.42 秒一次；0%/100% scaleY(1)，55% scaleY(-.62) skewX(-8deg)，每段 cubic-bezier(.45, 0, .3, 1)。
    static let flapPeriod: TimeInterval = 0.42
    /// 远侧的翅膀 animation-delay: -.03s（早 0.03 秒），opacity .45。
    static let farWingLead: TimeInterval = 0.03
    static let farWingOpacity: Double = 0.45
    /// rtcome 0.3 秒；.away 的 transition 0.45 秒（之后移除）。
    static let come: TimeInterval = 0.3
    static let away: TimeInterval = 0.45

    static func flap(_ time: TimeInterval) -> (scaleY: Double, skewDegrees: Double) {
        var phase = time.truncatingRemainder(dividingBy: flapPeriod) / flapPeriod
        if phase < 0 { phase += 1 }
        if phase < 0.55 {
            let u = CubicTiming.flap(phase / 0.55)
            return (1 + (-0.62 - 1) * u, -8 * u)
        }
        let u = CubicTiming.flap((phase - 0.55) / 0.45)
        return (-0.62 + (1 + 0.62) * u, -8 * (1 - u))
    }

    struct Lift {
        var dx: Double
        var dy: Double
        var scale: Double
        var opacity: Double
    }

    /// .rt-lift：出现时从 translate(-6px, -10px) scale(.85)、透明淡入（rtcome .3s ease-out）；
    /// 放下点后 .away：飞向 translate(14px, -16px) scale(.8) 并淡出（.45s）。nil = 已经飞走。
    static func lift(elapsed: TimeInterval, landed: TimeInterval) -> Lift? {
        if elapsed < 0 { return nil }
        if elapsed >= landed {
            let q = (elapsed - landed) / away
            if q >= 1 { return nil }
            let move = CubicTiming.lift(q)
            return Lift(dx: 14 * move, dy: -16 * move, scale: 1 - 0.2 * move, opacity: 1 - CubicTiming.ease(q))
        }
        if elapsed < come {
            let p = CubicTiming.easeOut(elapsed / come)
            return Lift(dx: -6 * (1 - p), dy: -10 * (1 - p), scale: 0.85 + 0.15 * p, opacity: p)
        }
        return Lift(dx: 0, dy: 0, scale: 1, opacity: 1)
    }

    /// 网页 frame()：每段飞行先慢后快再慢，像鸟滑翔着落下。
    static func glide(_ k: Double) -> Double {
        let k = min(max(k, 0), 1)
        return (1 - cos(Double.pi * k)) / 2
    }

    /// 头的倾角：atan2(vy, |vx|)，限制在 ±24°。
    static func aim(_ v: CGPoint) -> Double {
        let degrees = atan2(Double(v.y), abs(Double(v.x))) * 180 / Double.pi
        return max(-24, min(24, degrees))
    }
}

/// 一条飞行路线：把线压成相距不到 2 点的折线，记下到每点的长度（网页 flat()）。
struct FlightLine {
    private(set) var points: [CGPoint] = []
    private(set) var lengths: [CGFloat] = []

    init() {}

    init(_ commands: [SVGPathCommand]) {
        for command in commands {
            switch command {
            case .move(let p), .line(let p):
                add(p)
            case .quad(let c, let p):
                addQuad(control: c, to: p)
            case .cubic(let c1, let c2, let p):
                addCubic(control1: c1, control2: c2, to: p)
            case .close:
                if let first = points.first { add(first) }
            }
        }
    }

    var total: CGFloat { lengths.last ?? 0 }
    var isEmpty: Bool { points.count < 2 || total <= 0 }
    var start: CGPoint? { points.first }
    var end: CGPoint? { points.last }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func unit(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let n = distance(a, b)
        return n > 0 ? CGPoint(x: (b.x - a.x) / n, y: (b.y - a.y) / n) : CGPoint(x: 1, y: 0)
    }

    /// 起点处往哪飞。
    var startHeading: CGPoint {
        points.count < 2 ? CGPoint(x: 1, y: 0) : Self.unit(from: points[0], to: points[1])
    }

    /// 终点处往哪飞。
    var endHeading: CGPoint {
        points.count < 2 ? CGPoint(x: 1, y: 0) : Self.unit(from: points[points.count - 2], to: points[points.count - 1])
    }

    mutating func add(_ p: CGPoint) {
        if let last = points.last {
            let step = Self.distance(last, p)
            if step < 1e-6 { return }
            lengths.append(total + step)
        } else {
            lengths.append(0)
        }
        points.append(p)
    }

    mutating func addCubic(control1 c1: CGPoint, control2 c2: CGPoint, to p: CGPoint) {
        guard let a = points.last else { add(p); return }
        let hull = Self.distance(a, c1) + Self.distance(c1, c2) + Self.distance(c2, p)
        let steps = max(1, Int((hull / 2).rounded(.up)))
        for j in 1...steps {
            let t = CGFloat(j) / CGFloat(steps), u = 1 - t
            let w0 = u * u * u, w1 = 3 * u * u * t, w2 = 3 * u * t * t, w3 = t * t * t
            add(CGPoint(x: w0 * a.x + w1 * c1.x + w2 * c2.x + w3 * p.x,
                        y: w0 * a.y + w1 * c1.y + w2 * c2.y + w3 * p.y))
        }
    }

    mutating func addQuad(control c: CGPoint, to p: CGPoint) {
        guard let a = points.last else { add(p); return }
        let hull = Self.distance(a, c) + Self.distance(c, p)
        let steps = max(1, Int((hull / 2).rounded(.up)))
        for j in 1...steps {
            let t = CGFloat(j) / CGFloat(steps), u = 1 - t
            let w0 = u * u, w1 = 2 * u * t, w2 = t * t
            add(CGPoint(x: w0 * a.x + w1 * c.x + w2 * p.x, y: w0 * a.y + w1 * c.y + w2 * p.y))
        }
    }

    mutating func append(_ other: FlightLine) {
        for p in other.points { add(p) }
    }

    func reversed() -> FlightLine {
        var out = FlightLine()
        for p in points.reversed() { out.add(p) }
        return out
    }

    /// 沿线 s 处的点（超出两端时取端点）。
    func point(at s: CGFloat) -> CGPoint {
        guard let first = points.first else { return .zero }
        guard points.count > 1, total > 0 else { return first }
        let s = max(0, min(total, s))
        var lo = 0, hi = lengths.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if lengths[mid] <= s { lo = mid } else { hi = mid }
        }
        let span = lengths[hi] - lengths[lo]
        let f = span > 0 ? (s - lengths[lo]) / span : 0
        return CGPoint(x: points[lo].x + (points[hi].x - points[lo].x) * f,
                       y: points[lo].y + (points[hi].y - points[lo].y) * f)
    }

    /// 网页 via()：穿过 magpie 从一条线到下一条线的一段弧，沿来的方向进、沿下一条线的方向出；
    /// 两端几乎重合时（从同一边进出）在框里绕一个小圈。
    static func via(from a: CGPoint, heading at: CGPoint, to b: CGPoint, heading bt: CGPoint, hub: CGRect) -> FlightLine {
        let dx = b.x - a.x, dy = b.y - a.y
        let dist = (dx * dx + dy * dy).squareRoot()
        let c1: CGPoint, c2: CGPoint
        if dist < 4 {
            let k = min(hub.width, hub.height) * 0.42, m = k * 0.6
            let nx = at.y, ny = -at.x
            c1 = CGPoint(x: a.x + at.x * k - nx * m, y: a.y + at.y * k - ny * m)
            c2 = CGPoint(x: b.x - bt.x * k + nx * m, y: b.y - bt.y * k + ny * m)
        } else {
            let k = dist * 0.38, l = min(16, dist * 0.12), nx = dy / dist, ny = -dx / dist
            c1 = CGPoint(x: a.x + at.x * k + nx * l, y: a.y + at.y * k + ny * l)
            c2 = CGPoint(x: b.x - bt.x * k + nx * l, y: b.y - bt.y * k + ny * l)
        }
        var line = FlightLine()
        line.add(a)
        line.addCubic(control1: c1, control2: c2, to: b)
        return line
    }

    /// 网页 pose()：点在飞了 e（0…1）时的位置。线的两端都在卡片下面，所以起落都离卡片边一个点
    /// （最多 6 点），停在那里的点能看全。
    func distance(at e: CGFloat) -> CGFloat {
        let edge = min(6, total / 4)
        return edge + e * (total - 2 * edge)
    }

    func dot(at e: CGFloat) -> CGPoint { point(at: distance(at: e)) }

    /// 飞行方向：前后各 3 点的差。
    func velocity(at e: CGFloat) -> CGPoint {
        let d = distance(at: e)
        let p0 = point(at: d - 3), p1 = point(at: d + 3)
        return CGPoint(x: p1.x - p0.x, y: p1.y - p0.y)
    }
}

/// 一只喜鹊此刻的姿态。
struct MagpiePose {
    var point: CGPoint
    /// 向左飞：整只水平翻过来（scale(-1 1)）。
    var flip: Bool
    /// 倾角（度），在翻转之后旋转。
    var angle: Double

    /// 网页里倾角每帧向目标靠近 12%（转向时直接对准）；这里不留状态，按过去各帧的目标加权求同样的结果。
    /// - Parameters:
    ///   - line: 这段飞行的路线
    ///   - elapsed: 起飞后的秒数（落地后停在终点）
    ///   - duration: 这段飞行的秒数
    ///   - leftward: 方向读不出来时往哪边（回程默认向左）
    static func of(_ line: FlightLine, elapsed: TimeInterval, duration: TimeInterval, leftward: Bool) -> MagpiePose {
        let now = min(elapsed, duration)
        func sample(_ t: TimeInterval) -> (flip: Bool, aim: Double, first: Bool) {
            let e = CGFloat(MagpieMotion.glide(duration > 0 ? t / duration : 1))
            var v = line.velocity(at: e)
            if abs(v.x) + abs(v.y) < 0.01 { v = CGPoint(x: leftward ? -1 : 1, y: 0) }
            return (v.x < 0, MagpieMotion.aim(v), t <= 0)
        }
        let head = sample(now)
        var angle = 0.0, weight = 1.0, last = head.aim
        let count = 48
        for j in 0..<count {
            let s = j == 0 ? head : sample(now - Double(j) * MagpieMotion.frame)
            if s.flip != head.flip { break }
            last = s.aim
            if s.first || j == count - 1 { break }
            angle += 0.12 * weight * s.aim
            weight *= 0.88
        }
        angle += weight * last
        let e = CGFloat(MagpieMotion.glide(duration > 0 ? now / duration : 1))
        return MagpiePose(point: line.dot(at: e), flip: head.flip, angle: angle)
    }
}

// MARK: - SwiftUI

extension Path {
    init(svg d: String) {
        self.init()
        for command in SVGPathParser.parse(d) {
            switch command {
            case .move(let p): move(to: p)
            case .line(let p): addLine(to: p)
            case .quad(let c, let p): addQuadCurve(to: p, control: c)
            case .cubic(let c1, let c2, let p): addCurve(to: p, control1: c1, control2: c2)
            case .close: closeSubpath()
            }
        }
    }
}

extension FlightLine {
    init(_ path: Path) {
        var commands: [SVGPathCommand] = []
        path.forEach { element in
            switch element {
            case .move(let p): commands.append(.move(p))
            case .line(let p): commands.append(.line(p))
            case .quadCurve(let p, let c): commands.append(.quad(control: c, to: p))
            case .curve(let p, let c1, let c2): commands.append(.cubic(control1: c1, control2: c2, to: p))
            case .closeSubpath: commands.append(.close)
            }
        }
        self.init(commands)
    }
}

/// magpie 的标志（网页 .rt-hub 里的 `#bird`）。用 `.fill(style: FillStyle(eoFill: true))` 画。
struct MagpieLogo: Shape {
    static let base = Path(svg: MagpieArt.logo)

    func path(in rect: CGRect) -> Path {
        let transform = CGAffineTransform(a: rect.width / 44, b: 0, c: 0, d: rect.height / 44, tx: rect.minX, ty: rect.minY)
        return Self.base.applying(transform)
    }
}

/// 画一只飞着的喜鹊（client.js FLIER + routing.css .rt-flier）：身体、尾巴、头、嘴和翅膀用前景色，
/// 肚子和翅膀上的白条用卡片色；远侧翅膀淡一些、早 0.03 秒扇。
enum MagpieFlier {
    static let farWing = Path(svg: MagpieArt.farWing)
    static let tail = Path(svg: MagpieArt.tail)
    static let beak = Path(svg: MagpieArt.beak)
    static let nearWing = Path(svg: MagpieArt.nearWing)
    static let bar = Path(svg: MagpieArt.bar)
    static let body = Path(ellipseIn: MagpieArt.body)
    static let belly = Path(ellipseIn: MagpieArt.belly)
    static let head = Path(ellipseIn: MagpieArt.head)
    /// transform-box: fill-box; transform-origin: 50% 100%：翅膀从肩膀（自身外框的底边中点）扇。
    static var farShoulder: CGPoint { CGPoint(x: farWing.boundingRect.midX, y: farWing.boundingRect.maxY) }
    static var nearShoulder: CGPoint { CGPoint(x: nearWing.boundingRect.midX, y: nearWing.boundingRect.maxY) }

    static func draw(in gc: GraphicsContext, pose: MagpiePose, lift: MagpieMotion.Lift, flapTime: TimeInterval, ink: Color, card: Color) {
        var layer = gc
        layer.opacity = lift.opacity
        layer.drawLayer { ctx in
            // <g class="rt-flier" transform="translate(x y) scale(±1 1) rotate(a)">
            ctx.translateBy(x: pose.point.x, y: pose.point.y)
            ctx.scaleBy(x: pose.flip ? -1 : 1, y: 1)
            ctx.rotate(by: .degrees(pose.angle))
            // <g class="rt-lift">（以嘴尖前的原点为中心）
            ctx.translateBy(x: CGFloat(lift.dx), y: CGFloat(lift.dy))
            ctx.scaleBy(x: CGFloat(lift.scale), y: CGFloat(lift.scale))
            // <g transform="scale(1.2) translate(-6.5 3.2)">
            ctx.scaleBy(x: 1.2, y: 1.2)
            ctx.translateBy(x: -6.5, y: 3.2)

            var far = wing(ctx, shoulder: farShoulder, time: flapTime + MagpieMotion.farWingLead)
            far.opacity = MagpieMotion.farWingOpacity
            far.fill(farWing, with: .color(ink))
            ctx.fill(tail, with: .color(ink))
            ctx.fill(body, with: .color(ink))
            ctx.fill(belly, with: .color(card))
            ctx.fill(head, with: .color(ink))
            ctx.fill(beak, with: .color(ink))
            let near = wing(ctx, shoulder: nearShoulder, time: flapTime)
            near.fill(nearWing, with: .color(ink))
            near.stroke(bar, with: .color(card), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
        }
    }

    /// 翅膀此刻的变换：以肩膀为原点 scaleY(s) skewX(k)。
    private static func wing(_ ctx: GraphicsContext, shoulder o: CGPoint, time: TimeInterval) -> GraphicsContext {
        let flap = MagpieMotion.flap(time)
        var w = ctx
        w.translateBy(x: o.x, y: o.y)
        w.concatenate(CGAffineTransform(a: 1, b: 0, c: CGFloat(tan(flap.skewDegrees * Double.pi / 180)), d: CGFloat(flap.scaleY), tx: 0, ty: 0))
        w.translateBy(x: -o.x, y: -o.y)
        return w
    }
}
