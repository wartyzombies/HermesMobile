import SwiftUI

/// The message composer: a growing text field and a Send button.
///
/// Sends the prompt through `HermesClient.submitPrompt` for the active
/// session and clears the field on success. The Send button is disabled while
/// the text is empty or a send is in flight.
struct ComposerView: View {
    @Environment(\.hermesClient) private var client

    let sessionID: String

    @State private var text = ""
    @State private var sending = false

    var body: some View {
        HStack {
            TextField("Message Hermes…", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || sending
            )
        }
        .padding()
    }

    private func send() async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, let client else { return }
        sending = true
        defer { sending = false }
        do {
            _ = try await client.submitPrompt(sessionID: sessionID, text: prompt)
            text = ""
        } catch {
            // Keep the text so the user can retry; surface the failure (e.g. an alert).
        }
    }
}
