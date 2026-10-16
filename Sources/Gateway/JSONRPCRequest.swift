import Foundation
import GeneratedModels

/// JSON-RPC 2.0 request envelope used by the `tui_gateway` WebSocket API.
///
/// `params` is typed as `JSONValue?` rather than `Encodable?`: a
/// protocol-typed stored property cannot be `Codable`-synthesised, and
/// `GatewayClient` already models every param as a `JSONValue`.
struct JSONRPCRequest: Codable, Sendable {
    let jsonrpc: String = "2.0"
    let id: Int64?
    let method: String
    let params: JSONValue?

    enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
    }
}
