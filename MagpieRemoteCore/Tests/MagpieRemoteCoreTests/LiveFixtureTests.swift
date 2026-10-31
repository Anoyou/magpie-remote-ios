import Foundation
import XCTest
@testable import MagpieRemoteCore

/// Fixtures/live 是 contract.yml 对真实 magpie（含 mock 上游）抓到的响应，已脱敏。
/// 这里先保证它们能被读到、是合法 JSON / SSE；模型的解码测试可以直接用 `LiveFixture.data(_:)`。
enum LiveFixture {
    static func url(_ name: String) throws -> URL {
        let base = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures/live")
        return base.appendingPathComponent(name)
    }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }

    static func names() throws -> [String] {
        let base = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures/live")
        return try FileManager.default.contentsOfDirectory(atPath: base.path).sorted()
    }
}

final class LiveFixtureTests: XCTestCase {
    func testEveryJSONFixtureParses() throws {
        let names = try LiveFixture.names().filter { $0.hasSuffix(".json") }
        XCTAssertGreaterThan(names.count, 20)
        for name in names {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: LiveFixture.data(name)), name)
        }
    }

    func testChatStreamFixtureEndsWithDone() throws {
        let text = try XCTUnwrap(String(data: LiveFixture.data("gw-chat-stream.sse"), encoding: .utf8))
        var parser = SSEParser()
        let events = parser.feed(chunk: text)
        XCTAssertEqual(events.last?.isDone, true)
        for event in events.dropLast() {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(event.data.utf8)))
        }
    }

    func testFixturesCarryNoRealKeys() throws {
        for name in try LiveFixture.names() {
            let text = String(decoding: try LiveFixture.data(name), as: UTF8.self)
            for line in text.components(separatedBy: "sk-magpie-key-").dropFirst() where !line.hasPrefix("EXAMPLE") && !line.hasPrefix("…") {
                XCTFail("\(name) 含有未脱敏的 gateway key")
            }
        }
    }

    func testVersionFixtureMeetsMinimum() throws {
        let object = try JSONSerialization.jsonObject(with: LiveFixture.data("gw-v1.json")) as? [String: Any]
        let version = try XCTUnwrap(object?["version"] as? String)
        XCTAssertNil(MagpieCompatibility.check(hostVersion: version), "抓取 fixture 的 magpie \(version) 应满足最低版本")
    }
}
