//
//  JSONRPCFrame.swift
//  Wire-level JSON-RPC 2.0 frame types for the tui_gateway WebSocket.
//

import Foundation

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

        /// A normalised correlation key for the `pending` dictionary.
        ///
        /// The JSON-RPC spec permits either a string or an integer id, and a
        /// server may echo a string id back for a request the client sent with
        /// an integer id. Keying `pending` by the raw `JSONID` would then fail
        /// to correlate and the request would hang until its timeout (Y9).
        /// This property renders both cases to a canonical string so that a
        /// request correlates regardless of which form the server echoes.
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
