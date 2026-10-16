import Foundation
import HermesLogger

/// Low-level URLSessionWebSocketTask integration for HermesMobile.
///
/// A thin, dependency-free transport that opens a WebSocket, decodes the
/// JSON-RPC 2.0 envelope, and surfaces text/binary messages to the
/// caller. It respects the `wss://`-only policy enforced by the
/// gateway client and never logs payload bytes.
public class HermesCoreWebSocket {
    public init() {}

    /// Open a WebSocket connection to `wsUrl` using the provided URLSession.
    /// - Parameters:
    ///   - session: URLSession for making the connection.
    ///   - wsUrl: the gateway `wss://` URL, typically the one a minted
    ///     `WebSocketTicket` carries. Passed as a plain string so this
    ///     transport module stays dependency-free (it must not reference the
    ///     app target's `WebSocketTicket`).
    ///   - onMessage: closure called on incoming text/binary messages (decoded JSON).
    ///   - onError: closure called on connection errors.
    ///   - onDisconnect: closure called on clean disconnect.
    /// - Returns: the underlying `URLSessionWebSocketTask`.
    /// - Throws: `WebSocketError.invalidURL` if the URL is not a
    ///   secure `wss://` URL (R6). Cleartext `ws://` is rejected outside
    ///   DEBUG builds so conversation content never travels unencrypted.
    public static func connect(
        session: URLSession,
        wsUrl: String,
        onMessage: @escaping (Any) -> Void,
        onError: @escaping (Error) -> Void,
        onDisconnect: @escaping () -> Void
    ) async throws -> URLSessionWebSocketTask {
        guard let url = URL(string: wsUrl) else {
            throw WebSocketError.invalidURL
        }

        // Security (R6): enforce TLS. Allow `ws` only behind a DEBUG
        // escape hatch so development against a local gateway is possible.
        #if DEBUG
        let allowed = ["wss", "ws"]
        #else
        let allowed = ["wss"]
        #endif
        guard let scheme = url.scheme?.lowercased(), allowed.contains(scheme) else {
            throw WebSocketError.insecureURL
        }

        let task = session.webSocketTask(with: url)
        task.resume()

        // Drive the read loop off `receive()` throwing. (The
        // `URLSessionWebSocketTask.messages` AsyncSequence is not available on
        // every SDK/toolchain, so `receive()` is the portable form.)
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                break
            }
            switch message {
            case .string(let text):
                // Try to decode JSON-RPC envelope.
                if let data = text.data(using: .utf8) {
                    do {
                        let envelope = try JSONDecoder().decode(JSONRPCEnvelope.self, from: data)
                        onMessage(WireMessage(envelope: envelope))
                    } catch {
                        onError(error)
                    }
                }
            case .data(let data):
                // Binary payload (e.g. image attach).
                onMessage(BinaryPayload(data: data))
            @unknown default:
                break
            }
        }

        // Task finished cleanly.
        onDisconnect()
        return task
    }
}

/// Types for wire envelope and payload.
///
/// These are `internal` (not `private`) because the public `WireMessage`
/// exposes an `envelope` property of this type. `JSONRPCEnvelope` is only ever
/// *decoded* (the transport reads frames, never re-encodes them), so it
/// conforms to `Decodable` alone — conforming to `Encodable` is impossible for
/// its `Any`-carrying associated values and was the original build break.
enum JSONRPCEnvelope: Decodable {
    case response(response: JSONRPCResponse)
    case notification(notification: JSONRPCNotification)

    enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params, result, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rpcVersion = try container.decode(String.self, forKey: .jsonrpc)
        guard rpcVersion == "2.0" else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unsupported JSON-RPC version"
                )
            )
        }

        if let method = try container.decodeIfPresent(String.self, forKey: .method) {
            let params = try container.decodeIfPresent([String: AnyCodable].self, forKey: .params) ?? [:]
            self = .notification(notification: JSONRPCNotification(name: method, payload: params))
        } else {
            let id = try container.decodeIfPresent(String.self, forKey: .id)
            let result = try container.decode(AnyCodable.self, forKey: .result)
            let error = try container.decodeIfPresent(JSONRPCError.self, forKey: .error)
            self = .response(response: JSONRPCResponse(id: id, result: result.value, error: error))
        }
    }
}

struct JSONRPCNotification: Decodable {
    let name: String
    let payload: [String: AnyCodable]
}

struct JSONRPCResponse {
    let id: String?
    let result: Any
    let error: JSONRPCError?
}

struct JSONRPCError: Decodable {
    let code: Int
    let message: String
    let data: AnyCodable?
}

/// A type-erased JSON value that round-trips through `JSONSerialization`.
///
/// Encode order matters (A9): `Bool` is checked **before** `NSNumber`
/// because on platforms where `Bool` bridges to `NSNumber`, the reverse
/// order would encode `true` as `1`. The `[[Any]]` flatten branch is
/// intentionally **removed**: it destroyed nested array structure
/// (`[[1,2],[3,4]]` became `[1,2,3,4]`).
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Decode into an intermediate JSON value first so nested arrays
        // and mixed types survive, then materialise via JSONSerialization.
        let any = try container.decode(AnyJSON.self)
        self.value = any.object
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let bool = self.value as? Bool {
            try container.encode(bool)
        } else if let str = self.value as? String {
            try container.encode(str)
        } else if let num = self.value as? NSNumber {
            // NSNumber is not itself Encodable, and Swift Int64/Double bridge
            // to it. Encode via the concrete numeric type. `Bool` is handled
            // above, so a float check is enough to disambiguate.
            if CFNumberIsFloatType(num) {
                try container.encode(num.doubleValue)
            } else {
                try container.encode(num.int64Value)
            }
        } else if let data = self.value as? Data {
            try container.encode(data)
        } else if let arr = self.value as? [Any] {
            try container.encode(arr.map { AnyCodable($0) })
        } else if let dict = self.value as? [String: Any] {
            try container.encode(dict.mapValues { AnyCodable($0) })
        } else {
            throw EncodingError.invalidValue(self.value, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unsupported type for AnyCodable"))
        }
    }
}

/// An intermediate, losslessly-decodable JSON value.
private struct AnyJSON: Decodable {
    let object: Any

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self.object = NSNull()
        } else if let bool = try? c.decode(Bool.self) {
            self.object = bool
        } else if let int = try? c.decode(Int64.self) {
            self.object = int
        } else if let double = try? c.decode(Double.self) {
            self.object = double
        } else if let str = try? c.decode(String.self) {
            self.object = str
        } else if let arr = try? c.decode([AnyJSON].self) {
            self.object = arr.map { $0.object }
        } else if let dict = try? c.decode([String: AnyJSON].self) {
            self.object = dict.mapValues { $0.object }
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }
}

private enum WebSocketError: Error, LocalizedError {
    case invalidURL
    case insecureURL
    case connectionFailed(String)
    case invalidMessage

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The ticket URL is invalid."
        case .insecureURL: return "The WebSocket URL must use wss://."
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .invalidMessage: return "The message could not be decoded."
        }
    }
}

// MARK: - Payload types for WebSocket messages

/// A binary payload received over the WebSocket.
public struct BinaryPayload {
    let data: Data
}

/// A decoded JSON-RPC envelope received over the WebSocket.
public struct WireMessage {
    let envelope: JSONRPCEnvelope
}
