import XCTest
@testable import MagpieRemoteCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MagpieErrorTests: XCTestCase {
    private func body(_ text: String) -> Data { Data(text.utf8) }

    func test401IsInvalidKey() {
        XCTAssertEqual(MagpieError.from(status: 401, body: body(#"{"error":{"message":"bad key ending in EXMP"}}"#)), .invalidKey)
        XCTAssertEqual(MagpieError.invalidKey.title, "密钥无效")
    }

    func test403AllowListIsLanSharingOff() {
        let error = MagpieError.from(status: 403, body: body("magpie answers only the addresses on its allow list (MAGPIE_ALLOW_IPS), and this request came from 100.64.0.2: add it there to let it in"))
        guard case .lanSharingOff = error else { return XCTFail("\(error)") }
        XCTAssertEqual(error.title, "未开启局域网共享")
        XCTAssertTrue(error.hint?.contains("在局域网共享") ?? false)
    }

    func test403ModelIsModelNotAllowed() {
        let error = MagpieError.from(status: 403, body: body(#"{"error":{"message":"this key may not use model example-model"}}"#), model: "example-model")
        XCTAssertEqual(error, .modelNotAllowed(model: "example-model"))
        XCTAssertEqual(error.title, "模型不允许")
        XCTAssertTrue(error.message.contains("example-model"))
    }

    func testConnectionErrorsAreUnreachableWithTailscaleHint() {
        for code in [URLError.Code.cannotConnectToHost, .timedOut, .cannotFindHost, .networkConnectionLost] {
            let error = MagpieError.from(URLError(code))
            guard case .unreachable = error else { return XCTFail("\(code): \(error)") }
            XCTAssertEqual(error.title, "连不上主机")
            XCTAssertTrue(error.hint?.contains("Tailscale") ?? false)
            XCTAssertTrue(error.hint?.contains("不要把端口开放到公网") ?? false)
        }
        XCTAssertEqual(MagpieError.from(URLError(.timedOut)), .unreachable(.timedOut))
        XCTAssertEqual(MagpieError.from(URLError(.notConnectedToInternet)), .unreachable(.offline))
        XCTAssertEqual(MagpieError.from(URLError(.cancelled)), .cancelled)
    }

    func testMissingEndpointMeansIncompatibleHost() {
        guard case .incompatibleHost = MagpieError.from(status: 404, body: nil) else { return XCTFail() }
        XCTAssertEqual(MagpieError.incompatibleHost(found: "0.1.0", required: "0.2.0").title, "主机版本不兼容")
    }

    func testDecodingErrorIsIncompatible() {
        struct Thing: Decodable { let x: Int }
        do {
            _ = try JSONDecoder().decode(Thing.self, from: body("{}"))
            XCTFail("应当解码失败")
        } catch {
            guard case .decoding = MagpieError.from(error) else { return XCTFail() }
            XCTAssertEqual(MagpieError.from(error).title, "主机版本不兼容")
        }
    }

    func testErrorMessageExtraction() {
        XCTAssertEqual(MagpieError.errorMessage(from: body(#"{"error":{"message":"a"}}"#)), "a")
        XCTAssertEqual(MagpieError.errorMessage(from: body(#"{"error":"b"}"#)), "b")
        XCTAssertEqual(MagpieError.errorMessage(from: body(#"{"message":"c"}"#)), "c")
        XCTAssertEqual(MagpieError.errorMessage(from: body("  plain  ")), "plain")
        XCTAssertNil(MagpieError.errorMessage(from: body("")))
    }

    func testOtherStatusKeepsMessage() {
        XCTAssertEqual(MagpieError.from(status: 500, body: body(#"{"error":"boom"}"#)), .http(status: 500, message: "boom"))
    }
}
