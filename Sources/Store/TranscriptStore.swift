import Foundation

/// In-memory model of the chat transcript, driven by server notifications.
///
/// It does not own truth — it paints the latest server state. The store holds
/// a weak reference to its `GatewayConnection` so it never extends the
/// connection's lifetime (A8); the app shell owns the connection strongly.
@Observable @MainActor
final class TranscriptStore {
    /// The connection this store renders. Weak to avoid a retain cycle.
    private weak var gateway: GatewayConnection?

    /// The transcript, oldest first.
    var messages: [ChatMessage] = []
    /// The `seq` watermark of the last applied event.
    var latestWatermark: Int = 0

    /// Create a store bound to a connection.
    /// - Parameter gateway: the connection whose events drive the transcript.
    init(gateway: GatewayConnection) {
        self.gateway = gateway
    }

    /// Apply a server notification to the transcript.
    ///
    /// Dispatches on `notification.name` (e.g. `"message.delta"`,
    /// `"message.complete"`, `"tool.start"`) and updates `messages`
    /// and `latestWatermark` accordingly. Unknown notification names are
    /// ignored so a backend schema addition cannot crash the UI.
    /// - Parameter notification: the notification to apply.
    func apply(notification: ServerNotification) {
        switch notification.name {
        case "message.delta":
            appendOrUpdate(delta: notification.payload)
        case "message.complete":
            finalizeMessage(payload: notification.payload)
        case "tool.start":
            appendToolCall(payload: notification.payload)
        case "tool.complete":
            updateToolCall(payload: notification.payload)
        default:
            break
        }
    }

    // MARK: - Private

    private func appendOrUpdate(delta: [String: Any]) {
        guard let text = delta["text"] as? String else { return }
        if let id = delta["message_id"] as? String,
           let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].text += text
        } else {
            let id = delta["message_id"] as? String ?? UUID().uuidString
            messages.append(ChatMessage(id: id, text: text, role: .assistant))
        }
    }

    private func finalizeMessage(payload: [String: Any]) {
        // A complete message is already accumulated via deltas; nothing to do
        // beyond advancing the watermark.
        advanceWatermark(payload)
    }

    private func appendToolCall(payload: [String: Any]) {
        guard let sessionId = payload["session_id"] as? String,
              let idx = messages.firstIndex(where: { $0.id == sessionId })
        else { return }
        let id = payload["tool_call_id"] as? String ?? UUID().uuidString
        let name = payload["name"] as? String ?? "tool"
        let arguments = payload["arguments"] as? String ?? ""
        messages[idx].toolCalls.append(ToolCall(id: id, name: name, arguments: arguments))
    }

    private func updateToolCall(payload: [String: Any]) {
        guard let toolCallId = payload["tool_call_id"] as? String,
              let result = payload["result"] as? String
        else { return }
        for i in messages.indices {
            if let j = messages[i].toolCalls.firstIndex(where: { $0.id == toolCallId }) {
                messages[i].toolCalls[j].result = result
            }
        }
    }

    private func advanceWatermark(_ payload: [String: Any]) {
        if let seq = payload["seq"] as? Int {
            latestWatermark = max(latestWatermark, seq)
        }
    }
}

/// A single chat message in the transcript.
struct ChatMessage: Identifiable {
    let id: String
    var text: String
    var role: Role
    var toolCalls: [ToolCall] = []
    var reasoning: String?

    enum Role { case user, assistant, tool }
}

/// A tool invocation attached to a message.
struct ToolCall: Identifiable {
    let id: String
    var name: String
    var arguments: String
    var result: String?
}

/// A notification delivered over the gateway.
struct ServerNotification {
    let name: String
    let payload: [String: Any]
}
