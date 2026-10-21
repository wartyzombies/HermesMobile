import SwiftUI
import Foundation

/// Entry point before a connection exists: collect the gateway URL, run the
/// auth flow (OAuth/PKCE or basic auth), then mint a WS ticket and dial.
struct AuthGateView: View {
    @Environment(\.gatewayConnection) private var gateway

    @State private var baseURL = ""
    @State private var showingAuth = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(.blue)
            Text("Hermes Gateway")
                .font(.title2.bold())
            Text("Connect to your hermes serve gateway")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            TextField("Gateway URL (e.g. https://gateway.example:9119)", text: $baseURL)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .padding(.horizontal)

            Button("Continue") {
                guard URL(string: baseURL) != nil, !baseURL.isEmpty else {
                    errorMessage = "Enter a valid gateway URL"
                    return
                }
                errorMessage = nil
                showingAuth = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(baseURL.isEmpty)

            Spacer()
        }
        .padding()
        .sheet(isPresented: $showingAuth) {
            if let url = URL(string: baseURL) {
                let config = GatewayConfig(baseURL: url)
                AuthView(config: config) { credentials in
                    Task { await authenticate(credentials: credentials, config: config) }
                }
                .presentationDetents([.large])
            }
        }
    }

    /// Store the freshly-stored credentials, mint a single-use WS ticket and
    /// dial the gateway. Credentials are persisted by AuthView via the shared
    /// AuthStore, so restoring them here re-hydrates the authenticator.
    private func authenticate(credentials: GatewayCredentials, config: GatewayConfig) async {
        let auth = HermesAuthenticator(config: config)
        guard let ticketUrlString = await auth.mintWSTicket(),
              let _ = URL(string: ticketUrlString) else {
            errorMessage = "Failed to mint WebSocket ticket"
            return
        }
        gateway?.connect(to: URL(string: ticketUrlString)!, with: WebSocketTicket(wsUrl: ticketUrlString))
    }
}
