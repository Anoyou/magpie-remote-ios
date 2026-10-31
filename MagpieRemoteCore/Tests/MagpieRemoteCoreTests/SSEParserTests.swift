import XCTest
@testable import MagpieRemoteCore

final class SSEParserTests: XCTestCase {
    func testSingleEventDispatchesOnBlankLine() {
        var parser = SSEParser()
        XCTAssertNil(parser.feed(line: "data: hello"))
        XCTAssertEqual(parser.feed(line: ""), SSEEvent(data: "hello"))
    }

    func testMultipleDataLinesJoinWithNewline() {
        var parser = SSEParser()
        let events = parser.feed(chunk: "data: 第一行\ndata: 第二行\n\n")
        XCTAssertEqual(events, [SSEEvent(data: "第一行\n第二行")])
    }

    func testEventTypeIdRetryAndComments() {
        var parser = SSEParser()
        let events = parser.feed(chunk: ": keep-alive\nevent: delta\nid: 7\nretry: 1500\ndata: {\"x\":1}\n\n")
        XCTAssertEqual(events, [SSEEvent(event: "delta", data: "{\"x\":1}", id: "7", retry: 1500)])
    }

    func testOnlyOneLeadingSpaceIsStripped() {
        var parser = SSEParser()
        XCTAssertEqual(parser.feed(chunk: "data:  two spaces\n\ndata:none\n\n"),
                       [SSEEvent(data: " two spaces"), SSEEvent(data: "none")])
    }

    func testFieldWithoutColonAndEmptyData() {
        var parser = SSEParser()
        XCTAssertEqual(parser.feed(chunk: "data\n\n"), [SSEEvent(data: "")])
    }

    func testEventWithoutDataIsNotDispatched() {
        var parser = SSEParser()
        XCTAssertEqual(parser.feed(chunk: "event: ping\n\ndata: after\n\n"), [SSEEvent(data: "after")])
    }

    func testEventTypeResetsAfterDispatch() {
        var parser = SSEParser()
        let events = parser.feed(chunk: "event: a\ndata: 1\n\ndata: 2\n\n")
        XCTAssertEqual(events.map(\.event), ["a", "message"])
    }

    func testCRLFAndCRLineEndings() {
        var parser = SSEParser()
        XCTAssertEqual(parser.feed(chunk: "data: a\r\n\r\ndata: b\r\rdata: c\n\n"),
                       [SSEEvent(data: "a"), SSEEvent(data: "b"), SSEEvent(data: "c")])
    }

    func testChunksSplitAcrossLinesAndCRLF() {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for piece in ["da", "ta: hel", "lo\r", "\n", "\r", "\ndata: [DONE]\n", "\n"] {
            events += parser.feed(chunk: piece)
        }
        XCTAssertEqual(events, [SSEEvent(data: "hello"), SSEEvent(data: "[DONE]")])
        XCTAssertTrue(events[1].isDone)
    }

    func testUnterminatedEventIsDroppedOnFinish() {
        var parser = SSEParser()
        XCTAssertEqual(parser.feed(chunk: "data: partial\n"), [])
        XCTAssertEqual(parser.finish(), [])
        XCTAssertEqual(parser.feed(chunk: "data: next\n\n"), [SSEEvent(data: "next")])
    }

    func testInvalidRetryIgnoredAndIdPersists() {
        var parser = SSEParser()
        let events = parser.feed(chunk: "id: 1\nretry: soon\ndata: a\n\ndata: b\n\n")
        XCTAssertEqual(events, [SSEEvent(data: "a", id: "1"), SSEEvent(data: "b", id: "1")])
    }

    func testOpenAIStyleStream() {
        var parser = SSEParser()
        let stream = """
        data: {"choices":[{"delta":{"content":"你"}}]}

        data: {"choices":[{"delta":{"content":"好"}}]}

        data: [DONE]


        """
        let events = parser.feed(chunk: stream)
        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(events.last?.isDone ?? false)
    }
}
