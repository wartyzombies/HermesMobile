import Foundation

/// A single-use ticket minted by the authenticated HTTP session and
/// passed to the WebSocket handshake. OAuth-gated gateways require a
/// fresh ticket for every dial; the ticket is bound to the dialing
/// session and is rejected (close code 4401) if reused or expired.
///
/// - Warning: Never log or persist a ticket. It grants a single
///   authenticated WebSocket dial and must be treated as a secret
///   for its short lifetime.
struct WebSocketTicket: Codable {
    /// The `wss://` URL the gateway handed back for this ticket.
    let wsUrl: String
}
