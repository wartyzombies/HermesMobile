import Foundation
import HermesLogger

/// Manages a single WebSocket connection to a `hermes serve` gateway,
/// including authentication, reconnection, and message correlation.
///
/// This is the `@Observable` view-model the SwiftUI shell binds to. It wraps
/// a `GatewayClient` (the JSON-RPC transport) and exposes a UI-friendly
/// connection state. All state is `@MainActor`-isolated, so the type is
/// implicitly `Sendable`; no `nonisolated(unsafe)` annotations are needed (R8).
@Observable @MainActor
final class GatewayConnection {
    /// The underlying JSON-RPC transport.
    private let client = GatewayClient()

    /// The typed API surface views use to issue RPCs.
    let api: HermesClient

    /// Current connection state, mirrored for the UI.
    var connectionState: ConnectionState = .disconnected

    init() {
        self.api = HermesClient(gateway: client)
        client.onStateChange = { [weak self] newState in
            self?.connectionState = ConnectionState(from: newState)
        }
    }

    /// Open the connection to `url` using `ticket`.
    /// - Parameters:
    ///   - url: the gateway WebSocket URL (must be `wss://`).
    ///   - ticket: a single-use WS ticket minted by an authenticated session.
    func connect(to url: URL, with ticket: WebSocketTicket) {
        // Supply the single-use ticket to the transport before each dial (R6).
        client.ticketProvider = { ticket.wsUrl.isEmpty ? nil : ticket.wsUrl }
        client.connect(wsUrl: url)
    }

    /// Close the connection.
    func disconnect() {
        client.disconnect()
    }
}

/// UI-facing connection state.
enum ConnectionState {
    case disconnected
    case connecting
    case connected
    case reconnecting

    /// Map a transport-level state onto the UI-facing enum.
    init(from state: GatewayConnectionState) {
        switch state {
        case .idle: self = .disconnected
        case .connecting: self = .connecting
        case .open: self = .connected
        case .closed: self = .disconnected
        case .error: self = .disconnected
        case .reconnecting: self = .reconnecting
        }
    }
}
