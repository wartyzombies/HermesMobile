import SwiftUI

/// The message composer: a growing text field and a Send button.
///
/// Sends the prompt through `HermesClient.submitPrompt` and clears
/// the field on success. The Send button is disabled while the text
/// is empty or a send is in flight.
struct ComposerView: View {
    @Environment(\.hermesClient) private var client
    @State private var text = ""
    @State private var sending = false

    var body: some View {
        HStack {
            TextField("Message Hermes…", text: $text, axis: .vertical)
                .lineLimit(1...6)
            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
        }
        .padding()
    }

    private func send() async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, let client else { return }
        sending = true
        defer { sending = false }
        // TODO: bind to the active session id (session.create / session.resume).
        let sessionID = ""
        do {
            _ = try await client.submitPrompt(sessionID: sessionID, text: prompt)
            text = ""
        } catch {
            // Keep the text so the user can retry; surface the failure (e.g. an alert).
        }
    }
}
