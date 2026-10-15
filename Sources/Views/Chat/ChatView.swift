import SwiftUI

/// The active session transcript with the message composer docked below.
///
/// Renders `TranscriptStore.messages` and forwards the composer's
/// send action to `HermesClient.submitPrompt`.
struct ChatView: View {
    @Environment(\.hermesClient) private var client
    @Environment(TranscriptStore.self) private var store

    var body: some View {
        VStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(store.messages) { message in
                        MessageBubble(message: message)
                    }
                }
                .padding()
            }
            ComposerView()
        }
    }
}

/// A single transcript bubble.
private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.text)
                .textSelection(.enabled)
            ForEach(message.toolCalls) { tool in
                ToolCallRow(tool: tool)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }
}

/// A collapsed tool invocation.
private struct ToolCallRow: View {
    let tool: ToolCall

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "wrench.and.screwdriver")
            Text(tool.name).font(.caption)
            if let result { Text("✓").foregroundStyle(.green) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
