import Foundation

/// 任意 JSON 值。magpie Web 接口的对象字段很多（且随版本增减），
/// 管理页只读取需要的几个字段，同时保留整份原始对象：保存供应商 / 路由组时要「整份替换」，
/// 不能因为 App 不认识某个字段就把它丢掉。
public enum WebJSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([WebJSON])
    case object([String: WebJSON])

    public subscript(key: String) -> WebJSON? {
        get {
            if case .object(let object) = self { return object[key] }
            return nil
        }
        set {
            guard case .object(var object) = self else { return }
            object[key] = newValue
            self = .object(object)
        }
    }

    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    public var int: Int? {
        switch self {
        case .int(let value): Int(value)
        case .double(let value) where value.rounded() == value: Int(value)
        default: nil
        }
    }
    public var double: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }
    public var array: [WebJSON]? { if case .array(let value) = self { return value }; return nil }
    public var object: [String: WebJSON]? { if case .object(let value) = self { return value }; return nil }
    public var isNull: Bool { self == .null }

    /// 字符串数组；不是数组时为空。
    public var strings: [String] { array?.compactMap(\.string) ?? [] }

    /// 去掉若干键（不是对象时原样返回）。
    public func removing(_ keys: [String]) -> WebJSON {
        guard case .object(var object) = self else { return self }
        for key in keys { object[key] = nil }
        return .object(object)
    }

    public static func strings(_ values: [String]) -> WebJSON { .array(values.map(WebJSON.string)) }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> WebJSON {
        try JSONDecoder().decode(WebJSON.self, from: data)
    }
}

extension WebJSON: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([WebJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: WebJSON].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension WebJSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(arrayLiteral elements: WebJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, WebJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}
