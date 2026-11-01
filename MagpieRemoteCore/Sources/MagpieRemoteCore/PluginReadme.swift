import Foundation

/// 插件 README 的一块（标题、段落、代码、列表、引用、表格、分隔线）。行内文字是 Markdown（粗体、斜体、`代码`、链接），
/// App 用 `AttributedString(markdown:)` 显示。与 magpie 网页 plugins.js 的 markdown() 一样：不显示 HTML 与图片
///（README 里的徽章、截图来自任何地方），链接只留 http(s) 与页内锚点。
public enum ReadmeBlock: Hashable, Sendable {
    case heading(level: Int, text: String, slug: String)
    case paragraph(String)
    case code(language: String, text: String)
    case list(ordered: Bool, items: [String])
    case quote(String)
    case table(rows: [[String]])
    case rule
}

public enum PluginReadme {
    public static func blocks(_ source: String) -> [ReadmeBlock] {
        var text = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        text = replace(text, #"<!--[\s\S]*?-->"#, "")
        text = replace(text, #"<(script|style)\b[\s\S]*?</\1\s*>"#, "", caseInsensitive: true)
        // 链接里套图片的徽章
        text = replace(text, #"\[\s*!\[[^\]]*\]\([^)]*\)\s*\]\([^)]*\)"#, "")
        let lines = text.components(separatedBy: "\n")

        var out: [ReadmeBlock] = []
        var paragraph: [String] = []
        var listItems: [String] = []
        var listOrdered = false
        func flushParagraph() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty, !plain(joined).trimmingCharacters(in: .whitespaces).isEmpty { out.append(.paragraph(joined)) }
            paragraph = []
        }
        func flushList() {
            if !listItems.isEmpty { out.append(.list(ordered: listOrdered, items: listItems)) }
            listItems = []
        }
        func flush() { flushParagraph(); flushList() }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmedStart = String(line.drop(while: { $0 == " " || $0 == "\t" }))
            if trimmedStart.hasPrefix("```") || trimmedStart.hasPrefix("~~~") {
                flush()
                let fence = String(trimmedStart.prefix(3))
                let language = trimmedStart.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].drop(while: { $0 == " " || $0 == "\t" }).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                out.append(.code(language: language, text: code.joined(separator: "\n")))
                continue
            }
            if let heading = match(line, #"^(#{1,6})\s+(.*?)\s*#*\s*$"#) {
                flush()
                let body = inline(heading[2])
                let shown = plain(body).trimmingCharacters(in: .whitespaces)
                if !shown.isEmpty { out.append(.heading(level: heading[1].count, text: body, slug: slug(shown))) }
                i += 1
                continue
            }
            if match(line, #"^\s*\|.*\|\s*$"#) != nil, i + 1 < lines.count, match(lines[i + 1], #"^\s*\|?\s*:?-{2,}"#) != nil {
                flush()
                var rows = [cells(line)]
                i += 2
                while i < lines.count, match(lines[i], #"^\s*\|.*\|\s*$"#) != nil {
                    rows.append(cells(lines[i]))
                    i += 1
                }
                out.append(.table(rows: rows))
                continue
            }
            if let item = match(line, #"^\s*([-*+]|\d+[.)])\s+(.*)$"#) {
                flushParagraph()
                let ordered = item[1].first?.isNumber ?? false
                if !listItems.isEmpty, ordered != listOrdered { flushList() }
                listOrdered = ordered
                var body = item[2]
                if body.hasPrefix("[ ] ") { body = "☐ " + body.dropFirst(4) }
                else if body.lowercased().hasPrefix("[x] ") { body = "✓ " + body.dropFirst(4) }
                listItems.append(inline(body))
                i += 1
                continue
            }
            if match(line, #"^\s*>\s?(.*)$"#) != nil {
                flush()
                var parts: [String] = []
                while i < lines.count, let q = match(lines[i], #"^\s*>\s?(.*)$"#) {
                    parts.append(q[1])
                    i += 1
                }
                var joined = parts.joined(separator: " ")
                if let callout = match(joined, #"^\[!(\w+)\]\s*(.*)$"#) { joined = callout[1].uppercased() + ": " + callout[2] }
                out.append(.quote(inline(joined)))
                continue
            }
            if match(line, #"^\s*([-*_])\s*\1\s*\1[\s\-*_]*$"#) != nil {
                flush()
                out.append(.rule)
                i += 1
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
                i += 1
                continue
            }
            // 列表项的续行
            if !listItems.isEmpty, match(line, #"^\s{2,}\S"#) != nil {
                listItems[listItems.count - 1] += " " + inline(line.trimmingCharacters(in: .whitespaces))
                i += 1
                continue
            }
            flushList()
            paragraph.append(inline(line.trimmingCharacters(in: .whitespaces)))
            i += 1
        }
        flush()
        return out
    }

    /// 行内：去掉图片和 HTML 标签，`<a href>` 与 `<https://…>` 换成 Markdown 链接，只留 http(s) 与 `#锚点` 链接。
    public static func inline(_ text: String) -> String {
        var s = text
        s = replace(s, #"!\[[^\]]*\]\([^)]*\)"#, "")
        s = replace(s, #"<a\s[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a\s*>"#, "[$2]($1)", caseInsensitive: true)
        s = replace(s, #"<(https?://[^>\s]+)>"#, "[$1]($1)")
        s = replace(s, #"</?[a-zA-Z][^>]*>"#, "")
        s = replaceLinks(s)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// 去掉 Markdown 记号后的文字（判断是否为空、做锚点）。
    public static func plain(_ text: String) -> String {
        var s = replace(text, #"\[([^\]]*)\]\([^)]*\)"#, "$1")
        s = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "`", with: "")
        return s
    }

    /// GitHub 的标题锚点：小写、去掉标点和表情、空格换成 -。
    public static func slug(_ text: String) -> String {
        let lowered = text.trimmingCharacters(in: .whitespaces).lowercased()
        var out = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) || scalar == "_" || scalar == "-" {
                out.unicodeScalars.append(scalar)
            } else if CharacterSet.whitespaces.contains(scalar) {
                out.append("-")
            }
        }
        return out
    }

    // MARK: 工具

    static func cells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { inline($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func replaceLinks(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)\s]+)[^)]*\)"#) else { return text }
        let ns = text as NSString
        var out = ""
        var at = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at))
            let label = ns.substring(with: m.range(at: 1))
            let href = ns.substring(with: m.range(at: 2))
            if href.hasPrefix("http://") || href.hasPrefix("https://") || (href.hasPrefix("#") && href.count > 1) {
                out += "[\(label)](\(href))"
            } else {
                out += label
            }
            at = m.range.location + m.range.length
        }
        out += ns.substring(from: at)
        return out
    }

    static func match(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
    }

    static func replace(_ text: String, _ pattern: String, _ template: String, caseInsensitive: Bool = false) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
