//
//  HermesAuthenticator.swift
//  Orchestrates authentication against a Hermes dashboard/gateway.
//
//  Supports three provider paths, matching the server-side auth gate:
//  1. **Basic** — username/password → HMAC session token
//  2. **Nous Portal OAuth** — authorization-code + PKCE → JWT access token
//  3. **Self-hosted OIDC** — same flow with a custom issuer
//
//  After login, the authenticator can mint single-use WebSocket tickets
//  by calling `GET /api/ws/ticket` on the authenticated dashboard. The
//  resulting `wss://…?ticket=<ticket>` URL is passed to `GatewayClient`
//  via its `ticketProvider` closure.
//

import Foundation

// MARK: - Errors

public enum AuthError: Error, LocalizedError {
    /// The server rejected the credentials.
    case signInFailed(String)
    /// No credentials available to authenticate.
    case noCredentials
    /// The OAuth flow was cancelled by the user.
    case cancelled
    /// The IDP returned an invalid or unexpected response.
    case invalidResponse(String)
    /// Network or transport failure.
    case networkError(Error)
    /// Token refresh failed; user must re-login.
    case refreshFailed(String)
    /// The OAuth client ID is not configured.
    case missingClientID
    /// The OIDC issuer is not configured.
    case missingIssuer
    /// The access token has expired and no refresh token is available.
    case tokenExpired

    public var errorDescription: String? {
        switch self {
        case .signInFailed(let msg):   return "Sign-in failed: \(msg)"
        case .noCredentials:           return "No credentials available"
        case .cancelled:               return "Authentication cancelled"
        case .invalidResponse(let msg):return "Invalid response: \(msg)"
        case .networkError(let e):     return "Network error: \(e.localizedDescription)"
        case .refreshFailed(let msg):  return "Token refresh failed: \(msg)"
        case .missingClientID:         return "OAuth client ID not configured"
        case .missingIssuer:           return "OIDC issuer not configured"
        case .tokenExpired:            return "Access token expired; please sign in again"
        }
    }
}

// MARK: - Gateway discovery

/// Metadata returned by `GET /api/status` about the auth gate.
public struct GatewayAuthInfo: Sendable {
    /// Whether auth is required for this gateway.
    public let authRequired: Bool
    /// Which providers are available (e.g. `["basic"]`, `["nous"]`, `["basic", "nous"]`).
    public let providers: [AuthProvider]
    /// The gateway's public URL (from `HERMES_DASHBOARD_PUBLIC_URL` or headers).
    public let publicURL: URL?

    public init(authRequired: Bool, providers: [AuthProvider], publicURL: URL? = nil) {
        self.authRequired = authRequired
        self.providers = providers
        self.publicURL = publicURL
    }
}

// MARK: - Authenticator configuration

/// Configuration for a specific gateway host.
public struct GatewayConfig: Sendable {
    /// The base URL of the dashboard (e.g. `http://192.168.1.100:9119`).
    public let baseURL: URL
    /// OAuth client ID for the Nous Portal provider (shape `agent:{id}`).
    public let nousClientID: String?
    /// OIDC issuer URL for the self-hosted provider.
    public let oidcIssuer: URL?
    /// OIDC client ID for the self-hosted provider.
    public let oidcClientID: String?
    /// OIDC scopes (defaults to `openid profile email`).
    public let oidcScopes: String

    public init(
        baseURL: URL,
        nousClientID: String? = nil,
        oidcIssuer: URL? = nil,
        oidcClientID: String? = nil,
        oidcScopes: String = "openid profile email"
    ) {
        self.baseURL = baseURL
        self.nousClientID = nousClientID
        self.oidcIssuer = oidcIssuer
        self.oidcClientID = oidcClientID
        self.oidcScopes = oidcScopes
    }
}

// MARK: - Authenticator

/// Manages authentication for a Hermes gateway.
///
/// Typical usage:
/// ```swift
/// let auth = HermesAuthenticator(config: gatewayConfig)
/// let info = try await auth.discover()
/// if info.authRequired {
///     let creds = try await auth.signInBasic(username: "admin", password: "…")
///     // or: let creds = try await auth.signInOAuth()
/// }
/// gateway.ticketProvider = { [weak auth] in await auth?.mintWSTicket() }
/// ```
@MainActor
public final class HermesAuthenticator {

    /// The gateway configuration.
    public let config: GatewayConfig

    /// Keychain-backed credential store.
    public var store: AuthStore = .shared

    /// The current credentials (also persisted in Keychain).
    public private(set) var credentials: GatewayCredentials?

    /// Active PKCE state (survives the OAuth round-trip).
    private var activePKCE: PKCE?
    /// Active OAuth provider (survives the OAuth round-trip).
    private var activeProvider: AuthProvider?

    /// URL session for HTTP requests.
    private let urlSession: URLSession

    public init(config: GatewayConfig) {
        self.config = config
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 15
        self.urlSession = URLSession(configuration: sessionConfig)

        // Try to restore credentials from Keychain.
        let host = config.baseURL.host ?? config.baseURL.absoluteString
        if let creds = try? store.retrieve(forHost: host) {
            self.credentials = creds
        }
    }

    // MARK: - Discovery

    /// Probe `GET /api/status` to discover auth requirements.
    public func discover() async throws -> GatewayAuthInfo {
        let url = config.baseURL.appendingPathComponent("api/status")
        let (data, httpResponse) = try await request(url)

        // If we get a 200, we can read auth_required + providers.
        // A 401 also tells us auth is required.
        if httpResponse.statusCode == 401 {
            return GatewayAuthInfo(authRequired: true, providers: [])
        }

        guard httpResponse.statusCode == 200 else {
            throw AuthError.invalidResponse("status \(httpResponse.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.invalidResponse("invalid JSON")
        }

        let authRequired = json["auth_required"] as? Bool ?? false
        let providerStrings = (json["providers"] as? [String]) ?? []
        let providers = providerStrings.compactMap { AuthProvider(rawValue: $0) }

        var publicURL: URL?
        if let publicURLStr = json["public_url"] as? String {
            publicURL = URL(string: publicURLStr)
        }

        return GatewayAuthInfo(authRequired: authRequired, providers: providers, publicURL: publicURL)
    }

    // MARK: - Basic auth sign-in

    /// Sign in with username and password against the `basic` provider.
    ///
    /// The dashboard endpoint is `POST /auth/password-login` which returns
    /// a `hermes_session_at` cookie (HMAC-signed, stateless). We extract
    /// the cookie value as the access token.
    public func signInBasic(username: String, password: String) async throws -> GatewayCredentials {
        let url = config.baseURL.appendingPathComponent("auth/password-login")
        let body: [String: String] = ["username": username, "password": password]
        let (_, httpResponse) = try await request(
            url,
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: try? JSONSerialization.data(withJSONObject: body)
        )
        guard httpResponse.statusCode == 200 else {
            throw AuthError.signInFailed("HTTP \(httpResponse.statusCode)")
        }

        // Extract the session cookie value.
        guard let cookieHeader = httpResponse.allHeaderFields["Set-Cookie"] as? String ??
                                  httpResponse.allHeaderFields["set-cookie"] as? String,
              let token = extractCookieValue(from: cookieHeader, name: "hermes_session_at") else {
            throw AuthError.invalidResponse("no session cookie in response")
        }

        // Parse expiry from cookie (if present).
        let expiresAt = parseCookieExpiry(from: cookieHeader)

        let creds = GatewayCredentials.basic(username: username, accessToken: token, expiresAt: expiresAt)
        try store(creds)
        self.credentials = creds
        return creds
    }

    // MARK: - OAuth sign-in

    /// Build the OAuth authorize URL for the Nous Portal provider.
    ///
    /// Call this, then present the URL via `ASWebAuthenticationSession`.
    /// When the callback fires, pass the URL to `completeOAuth(callbackURL:)`.
    public func startNousOAuth() throws -> URL {
        guard let clientID = config.nousClientID else {
            throw AuthError.missingClientID
        }

        let pkce = PKCE()
        self.activePKCE = pkce
        self.activeProvider = .nous

        let callbackPath = config.baseURL.appendingPathComponent("auth/callback").absoluteString
        var components = URLComponents(string: "https://portal.nousresearch.com/oauth/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: callbackPath),
            .init(name: "response_type", value: "code"),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: pkce.challengeMethod),
            .init(name: "scope", value: "openid profile email"),
        ]
        guard let url = components.url else {
            throw AuthError.invalidResponse("failed to build authorize URL")
        }
        return url
    }

    /// Build the OAuth authorize URL for the self-hosted OIDC provider.
    ///
    /// Discovers the IDP's `authorization_endpoint` from its
    /// `.well-known/openid-configuration` document.
    public func startOIDCAuth() async throws -> URL {
        guard let issuer = config.oidcIssuer else {
            throw AuthError.missingIssuer
        }
        guard let clientID = config.oidcClientID else {
            throw AuthError.missingClientID
        }

        // Discover the authorization endpoint.
        let discoveryURL = issuer.appendingPathComponent(".well-known/openid-configuration")
        let (data, _) = try await urlSession.data(from: discoveryURL)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authEndpoint = json["authorization_endpoint"] as? String,
              let authURL = URL(string: authEndpoint) else {
            throw AuthError.invalidResponse("OIDC discovery failed")
        }

        let pkce = PKCE()
        self.activePKCE = pkce
        self.activeProvider = .oidc

        let callbackPath = config.baseURL.appendingPathComponent("auth/callback").absoluteString
        var components = URLComponents(url: authURL, resolvingAgainstBaseURL: true)!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: callbackPath),
            .init(name: "response_type", value: "code"),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: pkce.challengeMethod),
            .init(name: "scope", value: config.oidcScopes),
        ]
        guard let url = components.url else {
            throw AuthError.invalidResponse("failed to build OIDC authorize URL")
        }
        return url
    }

    /// Complete an OAuth flow by exchanging the authorization code for tokens.
    ///
    /// The server-side `/auth/callback` endpoint handles the code exchange
    /// with the IDP, verifies the JWT, and sets the `hermes_session_at` cookie.
    /// We simply follow the callback URL on the dashboard to complete the flow
    /// and extract the session cookie.
    public func completeOAuth(callbackURL: URL) async throws -> GatewayCredentials {
        // The callback URL looks like:
        //   <dashboard>/auth/callback?code=…&state=…
        // The dashboard server handles the token exchange server-side.
        // We need to hit this URL and capture the Set-Cookie header.
        let (_, httpResponse) = try await request(callbackURL)

        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 302 else {
            throw AuthError.signInFailed("HTTP \(httpResponse.statusCode)")
        }

        // Extract the session cookie.
        let allHeaders = httpResponse.allHeaderFields
        guard let cookieHeader = allHeaders["Set-Cookie"] as? String ??
                                  allHeaders["set-cookie"] as? String,
              let token = extractCookieValue(from: cookieHeader, name: "hermes_session_at") else {
            throw AuthError.invalidResponse("no session cookie in OAuth callback response")
        }

        let expiresAt = parseCookieExpiry(from: cookieHeader)
        // Fallback to config-based inference only if flow wasn't tracked.
        let provider: AuthProvider = self.activeProvider ?? (config.oidcIssuer != nil ? .oidc : .nous)

        let creds = GatewayCredentials.oauth(
            accessToken: token,
            refreshToken: nil, // Contract v1: no refresh token
            expiresAt: expiresAt,
            provider: provider
        )
        try store(creds)
        self.activePKCE = nil
        self.activeProvider = nil
        self.credentials = creds
        return creds
    }

    // MARK: - WS ticket minting

    /// Mint a fresh single-use WebSocket ticket by calling the authenticated
    /// dashboard endpoint.  Returns the full `wss://…?ticket=<ticket>` URL.
    ///
    /// This is the closure to wire into `GatewayClient.ticketProvider`.
    public func mintWSTicket() async -> String? {
        guard let creds = credentials, !creds.isExpired,
              let accessToken = creds.accessToken else {
            return nil
        }

        let url = config.baseURL.appendingPathComponent("api/ws/ticket")
        do {
            let (data, httpResponse) = try await request(
                url,
                method: "POST",
                headers: ["Authorization": "Bearer \(accessToken)"]
            )
            guard httpResponse.statusCode == 200 else {
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            if let ticket = json["ticket"] as? String {
                // Build the full WS URL from the ticket.
                // The dashboard's WS endpoint is at /api/ws.
                var wsComponents = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: true)!
                wsComponents.scheme = (wsComponents.scheme == "https") ? "wss" : "ws"
                wsComponents.path = "/api/ws"
                wsComponents.queryItems = [.init(name: "ticket", value: ticket)]
                return wsComponents.string
            }
            // Fallback: the server may return a full wsUrl instead of a ticket.
            return json["url"] as? String
        } catch {
            return nil
        }
    }

    // MARK: - Logout

    /// Sign out: clear stored credentials and notify the server.
    public func signOut() async throws {
        guard let creds = credentials, let accessToken = creds.accessToken else { return }
        // Hit the logout endpoint to clear server-side session.
        let url = config.baseURL.appendingPathComponent("auth/logout")
        _ = try? await request(url, method: "POST", headers: ["Authorization": "Bearer \(accessToken)"])

        // Delete from Keychain.
        let host = config.baseURL.host ?? config.baseURL.absoluteString
        try? store.delete(forHost: host)
        self.credentials = nil
    }

    // MARK: - Current user

    /// Return the current session identity from `GET /api/auth/me`.
    public func currentUser() async throws -> AuthUser {
        guard let creds = credentials, !creds.isExpired,
              let accessToken = creds.accessToken else {
            throw AuthError.noCredentials
        }

        let url = config.baseURL.appendingPathComponent("api/auth/me")
        let (data, httpResponse) = try await request(
            url,
            headers: ["Authorization": "Bearer \(accessToken)"]
        )
        guard httpResponse.statusCode == 200 else {
            throw AuthError.invalidResponse("auth/me failed")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.invalidResponse("invalid JSON from auth/me")
        }

        return AuthUser(
            userID: json["user_id"] as? String ?? "unknown",
            displayName: json["display_name"] as? String,
            email: json["email"] as? String,
            provider: creds.provider
        )
    }

    // MARK: - Private helpers

    /// Perform an authenticated HTTP request and return the response body +
    /// HTTPURLResponse. Consolidates the URLRequest building, header setting,
    /// and non-HTTP guard shared by all auth flows.
    private func request(
        _ url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse("not HTTP")
        }
        return (data, httpResponse)
    }

    private func store(_ creds: GatewayCredentials) throws {
        let host = config.baseURL.host ?? config.baseURL.absoluteString
        try store.store(creds, forHost: host)
    }

    /// Extract a named cookie value from a `Set-Cookie` header.
    private func extractCookieValue(from header: String, name: String) -> String? {
        // Set-Cookie can contain multiple cookies separated by commas (rare)
        // but we just need the one named `hermes_session_at`.
        let parts = header.split(separator: ";")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(name)=") {
                return String(trimmed.dropFirst("\(name)=".count))
            }
        }
        return nil
    }

    /// Parse `Expires=…` from a `Set-Cookie` header.
    private func parseCookieExpiry(from header: String) -> Date? {
        let parts = header.split(separator: ";")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed.hasPrefix("expires=") || trimmed.hasPrefix("max-age=") {
                guard let equals = trimmed.firstIndex(of: "=") else { continue }
                let value = String(trimmed[trimmed.index(after: equals)...])
                if trimmed.hasPrefix("max-age="), let seconds = Int(value), seconds > 0 {
                    return Date().addingTimeInterval(Double(seconds))
                }
                // Parse HTTP-date for Expires. Hoisted formatter to avoid
                // re-initializing ICU/locale on every sign-in (hot path).
                return Self.cookieExpiryFormatter.date(from: value)
            }
        }
        // Default: access token TTL is 15 minutes (contract v1).
        return Date().addingTimeInterval(15 * 60)
    }

    /// Reusable HTTP-date formatter shared across sign-in paths.
    private static let cookieExpiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}

// MARK: - Auth user

/// The identity of the currently authenticated user.
public struct AuthUser: Sendable {
    public let userID: String
    public let displayName: String?
    public let email: String?
    /// The provider that issued the credential, if any (an open gateway has none).
    public let provider: AuthProvider?

    public init(userID: String, displayName: String? = nil, email: String? = nil, provider: AuthProvider? = nil) {
        self.userID = userID
        self.displayName = displayName
        self.email = email
        self.provider = provider
    }
}
