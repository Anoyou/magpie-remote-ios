import Foundation

/// 一条 Server-Sent Events 事件。
public struct SSEEvent: Equatable, Sendable {
    public var event: String
    public var data: String
    public var id: String?
    public var retry: Int?

    public init(event: String = "message", data: String, id: String? = nil, retry: Int? = nil) {
        self.event = event
        self.data = data
        self.id = id
        self.retry = retry
    }

    /// OpenAI 风格流的结束标记 `data: [DONE]`。
    public var isDone: Bool { data == "[DONE]" }
}

/// 按 WHATWG 规范逐行解析 SSE：
/// - 空行派发事件；以 `:` 开头的是注释；
/// - `field: value` 只去掉冒号后的一个空格；没有冒号时整行是字段名、值为空；
/// - 多个 `data` 用换行拼接；没有任何 `data` 的事件不派发；
/// - 支持 `\n`、`\r\n`、`\r` 换行，以及跨网络分片的半行。
public struct SSEParser: Sendable {
    private var eventType = ""
    private var dataLines: [String] = []
    private var hasData = false
    private var lastEventID: String?
    private var retry: Int?
    private var buffer = ""
    private var pendingCR = false

    public init() {}

    /// 喂入一整行（不含换行符）。遇到空行时返回派发的事件。
    public mutating func feed(line rawLine: String) -> SSEEvent? {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }

        let field: String
        var value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[..<colon])
            value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
        } else {
            field = line
            value = ""
        }

        switch field {
        case "event": eventType = value
        case "data":
            dataLines.append(value)
            hasData = true
        case "id":
            if !value.contains("\u{0}") { lastEventID = value }
        case "retry":
            if !value.isEmpty, value.allSatisfy(\.isASCII), value.allSatisfy(\.isNumber), let ms = Int(value) { retry = ms }
        default: break
        }
        return nil
    }

    /// 喂入一段任意分片的文本，返回其中完整派发的事件；不完整的最后一行留到下次。
    public mutating func feed(chunk: String) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for scalar in chunk.unicodeScalars {
            if pendingCR {
                pendingCR = false
                if scalar == "\n" { continue }
            }
            if scalar == "\r" || scalar == "\n" {
                if scalar == "\r" { pendingCR = true }
                let line = buffer
                buffer = ""
                if let event = feed(line: line) { events.append(event) }
            } else {
                buffer.unicodeScalars.append(scalar)
            }
        }
        return events
    }

    /// 流结束：按规范，未以空行结束的最后一个事件丢弃。
    public mutating func finish() -> [SSEEvent] {
        buffer = ""
        pendingCR = false
        eventType = ""
        dataLines = []
        hasData = false
        return []
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            eventType = ""
            dataLines = []
            hasData = false
        }
        guard hasData else { return nil }
        return SSEEvent(event: eventType.isEmpty ? "message" : eventType,
                        data: dataLines.joined(separator: "\n"),
                        id: lastEventID,
                        retry: retry)
    }
}
