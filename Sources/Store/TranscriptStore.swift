import Foundation
import SwiftUI

/// In-memory model of the chat transcript, driven by server notifications.
///
/// It does not own truth — it paints the latest server state. The store holds
/// a weak reference to its `GatewayConnection` so it never extends the
/// connection's lifetime (A8); the app shell owns the connection strongly.
///
/// Wire events arrive as `GatewayEvent`/`JSONValue` payloads and are converted
/// into app-side `ChatMessage` values here.
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

    /// Replace the transcript with a resumed session's history.
    func replace(messages: [ChatMessage]) {
        self.messages = messages
    }

    /// Apply a server notification to the transcript.
    /// - Parameter notification: the notification to apply.
    func apply(notification: ServerNotification) {
        guard case .object(let dict) = notification.payload else { return }
        switch notification.name {
        case GWNotification.Message_delta:
            applyDelta(dict)
        case GWNotification.Message_complete:
            advanceWatermark(dict)
        case GWNotification.Tool_start:
            appendToolCall(dict)
        case GWNotification.Tool_complete:
            updateToolCall(dict)
        default:
            break
        }
    }

    // MARK: - Private

    private func applyDelta(_ dict: [String: JSONValue]) {
        let text = dict["text"]?.stringValue ?? ""
        guard !text.isEmpty else { return }
        let id = dict["message_id"]?.stringValue ?? UUID().uuidString
        let role = ChatMessage.Role(rawValue: dict["role"]?.stringValue ?? "assistant") ?? .assistant
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].text += text
        } else {
            messages.append(ChatMessage(id: id, text: text, role: role))
        }
    }

    private func appendToolCall(_ dict: [String: JSONValue]) {
        let id = dict["tool_call_id"]?.stringValue ?? UUID().uuidString
        let name = dict["name"]?.stringValue ?? "tool"
        let arguments = dict["arguments"]?.stringValue ?? ""
        // Attach to the most recent assistant message.
        if let idx = messages.lastIndex(where: { $0.role == .assistant }) {
            guard messages[idx].toolCalls.contains(where: { $0.id == id }) == false else { return }
            messages[idx].toolCalls.append(ToolCall(id: id, name: name, arguments: arguments))
        } else {
            messages.append(ChatMessage(id: id, text: "", role: .tool,
                toolCalls: [ToolCall(id: id, name: name, arguments: arguments)]))
        }
    }

    private func updateToolCall(_ dict: [String: JSONValue]) {
        guard let id = dict["tool_call_id"]?.stringValue,
              let result = dict["result"]?.stringValue else { return }
        for i in messages.indices {
            if let j = messages[i].toolCalls.firstIndex(where: { $0.id == id }) {
                messages[i].toolCalls[j].result = result
            }
        }
    }

    private func advanceWatermark(_ dict: [String: JSONValue]) {
        if let seq = dict["seq"]?.intValue {
            latestWatermark = max(latestWatermark, Int(seq))
        }
    }
}

/// A single chat message in the transcript.
struct ChatMessage: Identifiable, Equatable {
    let id: String
    var text: String
    var role: Role
    var toolCalls: [ToolCall] = []
    var reasoning: String? = nil

    enum Role: String, CaseIterable { case user, assistant, tool }
}

/// A tool invocation attached to a message.
struct ToolCall: Identifiable, Equatable {
    let id: String
    var name: String
    var arguments: String
    var result: String? = nil
}

/// A notification delivered over the gateway.
struct ServerNotification {
    let name: String
    let payload: JSONValue
}
