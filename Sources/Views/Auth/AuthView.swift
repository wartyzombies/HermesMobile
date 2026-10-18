//
//  AuthView.swift
//  SwiftUI sign-in flow for Hermes gateway auth.
//
//  Supports basic-auth (credential form) and OAuth (ASWebAuthenticationSession).
//  The view auto-detects the required provider by probing `/api/status`.
//

#if canImport(UIKit)
import SwiftUI
import AuthenticationServices

/// SwiftUI view for signing into a Hermes gateway.
///
/// ```swift
/// NavigationStack {
///     AuthView(config: gatewayConfig) { credentials in
///         // Authenticated! Wire up GatewayClient.
///     }
/// }
/// ```
@MainActor
public struct AuthView: View {
    /// Gateway configuration (base URL, OAuth client IDs).
    let config: GatewayConfig
    /// Called on successful authentication with the stored credentials.
    let onAuthenticated: (GatewayCredentials) -> Void

    @State private var authInfo: GatewayAuthInfo?
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var errorMessage: String?
    @State private var isAuthenticating: Bool = false
    @State private var authenticator: HermesAuthenticator?

    public init(config: GatewayConfig, onAuthenticated: @escaping (GatewayCredentials) -> Void) {
        self.config = config
        self.onAuthenticated = onAuthenticated
    }

    public var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)
                Text("Hermes Gateway")
                    .font(.title2.bold())
                if let host = config.baseURL.host {
                    Text(host)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 32)

            // Error message
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            if let info = authInfo {
                if !info.authRequired {
                    // No auth required — connect directly.
                    ContentUnavailableView(
                        "No Authentication Required",
                        systemImage: "lock.open",
                        description: Text("This gateway is on a trusted network.")
                    )
                    Button("Connect") {
                        onAuthenticated(.basic(username: "", accessToken: "", expiresAt: nil))
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    // Show sign-in options based on available providers.
                    providerButtons(info: info)
                }
            } else {
                ProgressView("Detecting authentication requirements…")
                    .task { await discoverAuth() }
            }

            Spacer()
        }
        .padding()
        .onAppear {
            if authenticator == nil {
                authenticator = HermesAuthenticator(config: config)
            }
        }
    }

    // MARK: - Provider buttons

    @ViewBuilder
    private func providerButtons(info: GatewayAuthInfo) -> some View {
        VStack(spacing: 16) {
            // Basic auth form
            if info.providers.contains(.basic) {
                basicAuthForm
            }

            // Nous OAuth button
            if info.providers.contains(.nous) {
                nousOAuthButton
            }

            // Self-hosted OIDC button
            if info.providers.contains(.oidc) {
                oidcOAuthButton
            }
        }
    }

    @ViewBuilder
    private var basicAuthForm: some View {
        VStack(spacing: 12) {
            Text("Sign in with credentials")
                .font(.headline)

            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
                .textContentType(.username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)

            Button {
                Task { await signInBasic() }
            } label: {
                if isAuthenticating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Sign In")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(username.isEmpty || password.isEmpty || isAuthenticating)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var nousOAuthButton: some View {
        Button {
            signInNousOAuth()
        } label: {
            Label("Sign in with Nous Research", systemImage: "person.badge.key.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(isAuthenticating)
    }

    @ViewBuilder
    private var oidcOAuthButton: some View {
        Button {
            Task { await signInOIDC() }
        } label: {
            Label("Sign in with SSO", systemImage: "key.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(isAuthenticating)
    }

    // MARK: - Discovery

    private func discoverAuth() async {
        guard let auth = authenticator else { return }
        do {
            authInfo = try await auth.discover()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Basic auth

    private func signInBasic() async {
        guard let auth = authenticator else { return }
        isAuthenticating = true
        errorMessage = nil
        do {
            let creds = try await auth.signInBasic(username: username, password: password)
            onAuthenticated(creds)
        } catch {
            errorMessage = error.localizedDescription
        }
        isAuthenticating = false
    }

    // MARK: - Nous OAuth

    private func signInNousOAuth() {
        guard let auth = authenticator else { return }
        isAuthenticating = true
        errorMessage = nil

        do {
            let authorizeURL = try auth.startNousOAuth()
            presentOAuth(authorizeURL: authorizeURL) { callbackURL in
                Task {
                    do {
                        let creds = try await auth.completeOAuth(callbackURL: callbackURL)
                        onAuthenticated(creds)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    isAuthenticating = false
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            isAuthenticating = false
        }
    }

    // MARK: - OIDC OAuth

    private func signInOIDC() async {
        guard let auth = authenticator else { return }
        isAuthenticating = true
        errorMessage = nil

        do {
            let authorizeURL = try await auth.startOIDCAuth()
            presentOAuth(authorizeURL: authorizeURL) { callbackURL in
                Task {
                    do {
                        let creds = try await auth.completeOAuth(callbackURL: callbackURL)
                        onAuthenticated(creds)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    isAuthenticating = false
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            isAuthenticating = false
        }
    }

    // MARK: - OAuth session presentation

    /// Present an `ASWebAuthenticationSession` for `authorizeURL` and hand the
    /// callback URL to `onCallback` (run on `@MainActor`). Handles canceled
    /// login and missing-callback errors inline so callers don't repeat them.
    private func presentOAuth(authorizeURL: URL, onCallback: @escaping (URL) -> Void) {
        let callbackScheme = config.baseURL.scheme ?? "http"

        let session = ASWebAuthenticationSession(
            url: authorizeURL,
            callbackURLScheme: callbackScheme
        ) { [self] callbackURL, error in
            Task { @MainActor in
                if let error {
                    if let asError = error as? ASWebAuthenticationSessionError,
                       asError.code == .canceledLogin {
                        isAuthenticating = false
                        return
                    }
                    errorMessage = error.localizedDescription
                    isAuthenticating = false
                    return
                }
                guard let callbackURL else {
                    errorMessage = "No callback URL received"
                    isAuthenticating = false
                    return
                }
                onCallback(callbackURL)
            }
        }
        session.start()
    }
}
#endif
