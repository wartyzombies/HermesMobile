import Foundation
import HermesLogger
import SwiftUI

/// Manages a single WebSocket connection to a `hermes serve` gateway,
/// including authentication, reconnection, and message correlation.
///
/// This is the `@Observable` view-model the SwiftUI shell binds to. It wraps
/// a `GatewayClient` (the JSON-RPC transport) and exposes a UI-friendly
/// connection state. All state is `@MainActor`-isolated.
///
/// The connection owns a `TranscriptStore` that consumes gateway events and
/// surfaces `approval.received` events via `approvalManager` / `approvalTrigger`.
@Observable @MainActor
final class GatewayConnection {
    /// The underlying JSON-RPC transport.
    private let client = GatewayClient()

    /// The transcript store that consumes gateway events.
    let transcriptStore: TranscriptStore

    /// The typed API surface views use to issue RPCs.
    let api: HermesClient

    /// Current connection state, mirrored for the UI.
    var connectionState: ConnectionState = .disconnected

    /// Approvals pending user action, surfaced by the UI.
    let approvalManager = ApprovalManager()

    /// Bumped whenever a new approval arrives, so SwiftUI can re-present the alert.
    var approvalTrigger = 0

    /// The id of the currently selected session (sidebar → chat selection).
    var activeSession: String?

    init() {
        self.transcriptStore = TranscriptStore(gateway: self)
        self.api = HermesClient(gateway: client)
        client.onStateChange = { [weak self] newState in
            self?.connectionState = ConnectionState(from: newState)
        }
        // Forward every gateway event to the transcript store and the
        // approval manager, hopping back to the main actor.
        client.onAny { [weak self] params in
            Task { @MainActor in
                self?.handleEvent(params)
            }
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

    // MARK: - Event dispatch

    private func handleEvent(_ params: JSONValue) {
        guard case .object(let dict) = params,
              let type = dict["type"]?.stringValue else { return }

        // Drive the transcript from message/tool events.
        transcriptStore.apply(notification: ServerNotification(name: type, payload: params))

        // Surface approval requests to the UI.
        if type == GWNotification.Approval_received {
            if let request = approvalRequest(from: dict) {
                approvalManager.pending = request
                approvalTrigger += 1
            }
        }
    }

    private func approvalRequest(from dict: [String: JSONValue]) -> ApprovalRequest? {
        guard let requestId = dict["request_id"]?.stringValue else { return nil }
        let sessionId = dict["session_id"]?.stringValue ?? ""
        let choices: [String]? = dict["choices"]?.arrayValue?.compactMap { $0.stringValue }
        let approval = PendingApproval(
            requestId: requestId,
            command: dict["command"]?.stringValue,
            description: dict["description"]?.stringValue,
            patternKey: nil,
            patternKeys: nil,
            allowPermanent: dict["allow_permanent"]?.boolValue,
            allowSession: dict["allow_session"]?.boolValue,
            smartDenied: nil,
            choices: choices,
            toolName: dict["tool_name"]?.stringValue
        )
        return ApprovalRequest(id: requestId, approval: approval, sessionId: sessionId)
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

/// An approval the gateway is asking the user to act on.
struct ApprovalRequest: Identifiable, Equatable {
    /// Stable identity (the server's request id).
    let id: String
    /// The decoded approval payload.
    let approval: PendingApproval
    /// The session the approval belongs to (needed to respond).
    let sessionId: String

    static func == (lhs: ApprovalRequest, rhs: ApprovalRequest) -> Bool {
        lhs.id == rhs.id
    }
}

/// Shared approval inbox. The connection writes pending approvals here; the UI
/// reads and presents them.
@Observable
final class ApprovalManager {
    /// The approval currently awaiting a decision, or `nil`.
    var pending: ApprovalRequest?

    static let shared = ApprovalManager()
    private init() {}
}
