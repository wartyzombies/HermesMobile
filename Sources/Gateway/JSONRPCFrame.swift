//
//  JSONRPCFrame.swift
//  Wire-level JSON-RPC 2.0 frame types for the tui_gateway WebSocket.
//

import Foundation
import GeneratedModels

/// One JSON-RPC 2.0 frame on the wire. A frame is one of:
/// - a **response** (`id` + `result` or `error`),
/// - a **notification** (`method` = "event" + `params` carrying `{type, ...}`),
/// - a **server→client request** (`id` (string) + `method` + `params`).
public struct JSONRPCFrame: Codable, Sendable {
    public let jsonrpc: String?
    public let id: JSONID?
    public let method: String?
    public let result: JSONValue?
    public let error: JSONRPCError?
    public let params: JSONValue?

    public enum JSONID: Codable, Hashable, Sendable {
        case number(Int64)
        case string(String)

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int64.self) { self = .number(i); return }
            if let s = try? c.decode(String.self) { self = .string(s); return }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "id must be number or string")
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .number(let i): try c.encode(i)
            case .string(let s): try c.encode(s)
            }
        }

        /// A correlation key for the `pending` dictionary.
        ///
        /// The key is **type-tagged** (`n:` for a JSON number, `s:` for a JSON
        /// string), so `42` and `"42"` map to different keys. This is
        /// deliberate and matches JSON-RPC 2.0, which requires the server to
        /// echo the *same* id value it received: a number reply only
        /// correlates with a number request. (Earlier revisions of this
        /// comment claimed both forms normalised to one key; they do not, and
        /// the `HermesMobileTests.testJSONIDKeyIsStable` case pins the tagged
        /// behaviour. See `fixes.md` Y9.)
        public var key: String {
            switch self {
            case .number(let i): return "n:\(i)"
            case .string(let s): return "s:\(s)"
            }
        }
    }

    public enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, result, error, params
    }
}

/// A decoded gateway event notification (method = "event").
public struct GatewayEvent: Codable, Sendable {
    public let type: String
    public let seq: Int64?
    public let sessionID: String?
    public let replayed: Bool?

    enum CodingKeys: String, CodingKey {
        case type, seq
        case sessionID = "session_id"
        case replayed
    }

    /// Decode the full payload of this event as the given type.
    public func decodePayload<T: Decodable>(_ type: T.Type) -> T? {
        guard let raw = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(T.self, from: raw)
    }
}
