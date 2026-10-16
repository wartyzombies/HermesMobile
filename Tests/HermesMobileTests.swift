import XCTest
@testable import HermesMobile
import GeneratedModels

/// Unit tests for the gateway transport and wire types.
///
/// Run with `swift test` (see `todo.md` for the full
/// macOS/Linux test-environment setup).
///
/// `@MainActor` because `GatewayClient` (and every type it drives) is
/// main-actor isolated, so its construction and teardown must happen there.
@MainActor
final class HermesMobileTests: XCTestCase {

    // MARK: - JSONID correlation key (Y9)

    /// A string id and the integer it came from normalise to
    /// distinct keys, but the same integer always maps to the
    /// same key so `pending` correlation is stable.
    func testJSONIDKeyIsStable() {
        let n = JSONRPCFrame.JSONID.number(42)
        XCTAssertEqual(n.key, JSONRPCFrame.JSONID.number(42).key)
        // Distinct forms produce distinct keys (no collision).
        XCTAssertNotEqual(n.key, JSONRPCFrame.JSONID.string("42").key)
    }

    // MARK: - JSONValue round-trip

    /// Nested arrays and mixed types survive an encode/decode cycle.
    func testJSONValueRoundTrip() {
        let value = JSONValue.array([.integer(1), .string("two"), .bool(true), .null])
        let data = try! JSONEncoder().encode(value)
        let decoded = try! JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value, decoded)
    }

    // MARK: - ReconnectBackoff (GREEN — verified correct)

    /// The backoff ladder is capped and never traps on edge inputs.
    func testReconnectBackoffIsBounded() {
        let backoff = ReconnectBackoff(baseDelayMs: 300, capMs: 15_000, jitter: true)
        for attempt in 0..<40 {
            let delay = backoff.delayMs(attempt: attempt)
            XCTAssertGreaterThanOrEqual(delay, 0)
            XCTAssertLessThanOrEqual(delay, 15_000)
        }
    }

    /// A zero base delay cannot trap the jitter range.
    func testReconnectBackoffZeroBaseIsSafe() {
        let backoff = ReconnectBackoff(baseDelayMs: 0, capMs: 1_000, jitter: true)
        XCTAssertGreaterThanOrEqual(backoff.delayMs(attempt: 1), 0)
    }

    // MARK: - GatewayClient construction

    /// The client starts idle and can be constructed and torn down.
    func testClientStartsIdle() {
        let client = GatewayClient()
        XCTAssertEqual(client.state, .idle)
        client.disconnect()
    }

    // MARK: - Frame decode

    /// A notification frame decodes and routes to the event dispatch.
    func testNotificationFrameDecodes() throws {
        let json = """
        {"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","seq":7,"session_id":"s1","text":"hi"}}
        """.data(using: .utf8)!
        let frame = try JSONDecoder().decode(JSONRPCFrame.self, from: json)
        XCTAssertEqual(frame.method, "event")
        guard case .object(let dict) = frame.params ?? .null else {
            return XCTFail("params should be an object")
        }
        XCTAssertEqual(dict["type"]?.stringValue, "message.delta")
        XCTAssertEqual(dict["seq"]?.intValue, 7)
    }
}
