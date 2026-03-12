import XCTest
@testable import Claudio

final class HTTPTransportTests: XCTestCase {

    // MARK: - SSE Line Parsing Helpers

    /// Simulate parsing SSE lines the same way HTTPTransport does internally.
    /// Returns accumulated content tokens from a sequence of SSE lines.
    private func parseSSELines(_ lines: [String]) -> (deltas: [String], finished: Bool) {
        var accumulated = ""
        var deltas: [String] = []
        var finished = false

        for line in lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))

            if payload == "[DONE]" {
                finished = true
                break
            }

            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let choice = choices.first else {
                continue
            }

            if let finishReason = choice["finish_reason"] as? String, !finishReason.isEmpty {
                finished = true
                break
            }

            if let delta = choice["delta"] as? [String: Any],
               let content = delta["content"] as? String, !content.isEmpty {
                accumulated += content
                deltas.append(accumulated)
            }
        }

        return (deltas, finished)
    }

    // MARK: - Tests

    func testNormalStream() {
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}",
            "data: {\"choices\":[{\"delta\":{\"content\":\" world\"}}]}",
            "data: {\"choices\":[{\"delta\":{\"content\":\"!\"}}]}",
            "data: [DONE]"
        ]

        let result = parseSSELines(lines)
        XCTAssertEqual(result.deltas, ["Hello", "Hello world", "Hello world!"])
        XCTAssertTrue(result.finished)
    }

    func testFinishReasonStop() {
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}",
            "data: {\"choices\":[{\"finish_reason\":\"stop\",\"delta\":{}}]}",
        ]

        let result = parseSSELines(lines)
        XCTAssertEqual(result.deltas, ["Hi"])
        XCTAssertTrue(result.finished)
    }

    func testDoneMarker() {
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"OK\"}}]}",
            "data: [DONE]"
        ]

        let result = parseSSELines(lines)
        XCTAssertEqual(result.deltas, ["OK"])
        XCTAssertTrue(result.finished)
    }

    func testMalformedJSON() {
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"A\"}}]}",
            "data: {not valid json}",
            "data: {\"choices\":[{\"delta\":{\"content\":\"B\"}}]}",
            "data: [DONE]"
        ]

        let result = parseSSELines(lines)
        // Malformed line is skipped, accumulation continues
        XCTAssertEqual(result.deltas, ["A", "AB"])
        XCTAssertTrue(result.finished)
    }

    func testEmptyDeltas() {
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"X\"}}]}",
            "data: {\"choices\":[{\"delta\":{\"content\":\"\"}}]}",
            "data: {\"choices\":[{\"delta\":{}}]}",
            "data: {\"choices\":[{\"delta\":{\"content\":\"Y\"}}]}",
            "data: [DONE]"
        ]

        let result = parseSSELines(lines)
        // Empty content deltas are skipped
        XCTAssertEqual(result.deltas, ["X", "XY"])
        XCTAssertTrue(result.finished)
    }

    func testNonDataLinesIgnored() {
        let lines = [
            ": comment line",
            "",
            "event: message",
            "data: {\"choices\":[{\"delta\":{\"content\":\"Z\"}}]}",
            "data: [DONE]"
        ]

        let result = parseSSELines(lines)
        XCTAssertEqual(result.deltas, ["Z"])
        XCTAssertTrue(result.finished)
    }

    func testNoFinishSignal() {
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}",
        ]

        let result = parseSSELines(lines)
        XCTAssertEqual(result.deltas, ["partial"])
        XCTAssertFalse(result.finished)
    }

    func testEmptyStream() {
        let lines: [String] = [
            "data: [DONE]"
        ]

        let result = parseSSELines(lines)
        XCTAssertEqual(result.deltas, [])
        XCTAssertTrue(result.finished)
    }
}
