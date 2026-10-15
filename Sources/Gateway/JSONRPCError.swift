//
//  JSONRPCError.swift
//  JSON-RPC error types matching apps/shared/src/json-rpc-channel.ts.
//

import Foundation

/// JSON-RPC error payload from the gateway.
public struct JSONRPCError: Error, Codable, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    enum CodingKeys: String, CodingKey { case code, message, data }
}

public enum JSONRPCErrorCode {
    /// "method not found" (tui_gateway dispatch).
    public static let methodNotFound = -32601
    /// "internal error" — a server→client request handler threw.
    public static let internalError = -32603
    /// A window-owned request's session is not shown by any window.
    public static let sessionNotShown = 4404
}
