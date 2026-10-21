import Foundation
import SwiftUI
import GeneratedModels

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
    let transcriptStore = TranscriptStore()

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
        self.api = HermesClient(gateway: client)
        // Every stored property is initialised at this point, so the store can
        // be bound to the connection (it holds it weakly).
        transcriptStore.attach(gateway: self)
        client.onStateChange = { [weak self] newState in
            self?.connectionState = ConnectionState(from: newState)
        }
        // Forward every gateway event to the transcript store, hopping back to
        // the main actor.
        _ = client.onAny { [weak self] params in
            Task { @MainActor in
                self?.handleEvent(params)
            }
        }
        // Approvals arrive as gateway-initiated JSON-RPC requests, not as
        // event notifications (contract: `x-server-requests`).
        client.registerRequestHandler(self)
    }

    /// Open the connection to `url` using `ticket`.
    /// - Parameters:
    ///   - url: the gateway WebSocket URL (must be `wss://`).
    ///   - ticket: a single-use WS ticket minted by an authenticated session.
    /// - Note: When `ticket` is nil (unauthenticated gateway), the
    ///   transport dials without a ticket.
    func connect(to url: URL, with ticket: WebSocketTicket?) {
        // Supply the single-use ticket to the transport before each dial (R6).
        client.ticketProvider = { ticket?.wsUrl.isEmpty == false ? ticket?.wsUrl : nil }
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
    }

    private func approvalRequest(
        from dict: [String: JSONValue],
        respond: ((String) -> Void)? = nil
    ) -> ApprovalRequest? {
        guard let requestId = dict["request_id"]?.stringValue else { return nil }
        let sessionId = dict["session_id"]?.stringValue ?? ""
        // Decode into the generated Codable PendingApproval instead of
        // hand-extracting each field from the JSONValue object.
        guard let data = try? JSONEncoder().encode(dict),
              let approval = try? JSONDecoder().decode(PendingApproval.self, from: data) else {
            return nil
        }
        return ApprovalRequest(id: requestId, approval: approval, sessionId: sessionId, respond: respond)
    }
}

// MARK: - Server-initiated requests

/// Method names for gateway-initiated (server→client) JSON-RPC requests.
///
/// The contract lists these under `x-server-requests`; the model generator
/// does not emit them, so they are declared here.
enum GatewayServerRequest {
    /// "A dangerous command awaits the user's decision."
    static let approval = "approval"
}

extension GatewayConnection: ServerRequestHandler {
    /// Handle a gateway-initiated request.
    /// - Parameter request: the inbound server→client request.
    /// - Returns: `true` when the request was handled, so the client does not
    ///   reply with `-32601`.
    func handle(request: ServerRequest) -> Bool {
        guard request.method == GatewayServerRequest.approval else { return false }
        // Answer the gateway-initiated request with the user's decision.
        let responder: (String) -> Void = { choice in
            request.respond(.object(["choice": .string(choice)]))
        }
        guard case .object(let dict) = request.params,
              let approval = approvalRequest(from: dict, respond: responder) else {
            // The method is ours, so answer it — a malformed payload is an
            // internal error, not "method not found".
            request.fail(JSONRPCErrorCode.internalError, "malformed approval payload")
            return true
        }
        approvalManager.pending = approval
        approvalTrigger += 1

        // Tell the backend the card is on screen so its timeout clock starts.
        let sessionId = approval.sessionId
        let requestId = approval.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await self.api.acknowledgeApproval(
                sessionID: sessionId,
                requestID: requestId
            )
        }
        return true
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
    /// Answers the gateway-initiated JSON-RPC request this approval arrived
    /// on. `nil` when the approval was surfaced by polling instead.
    let respond: ((String) -> Void)?

    init(
        id: String,
        approval: PendingApproval,
        sessionId: String,
        respond: ((String) -> Void)? = nil
    ) {
        self.id = id
        self.approval = approval
        self.sessionId = sessionId
        self.respond = respond
    }

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

    init() {}
}
