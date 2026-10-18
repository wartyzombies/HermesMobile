//
//  AuthStore.swift
//  Keychain-backed credential storage for Hermes gateway auth.
//
//  Stores either basic-auth credentials (username + HMAC session token)
//  or OAuth tokens (access token + optional refresh token + expiry).
//  Credentials are persisted in the iOS Keychain with app-group isolation.
//

import Foundation

// MARK: - Credential types

/// The kind of authentication the gateway requires.
public enum AuthProvider: String, Codable, Sendable {
    /// Username/password login → HMAC-signed session token.
    case basic
    /// Nous Portal OAuth 2.0 + PKCE → JWT access token.
    case nous
    /// Self-hosted OIDC → ID token + access token.
    case oidc
}

/// Stored credentials for a single gateway host.
public enum GatewayCredentials: Sendable {
    /// Basic-auth session: the server returned an HMAC-signed session token
    /// after username/password login.
    case basic(username: String, accessToken: String, expiresAt: Date?)
    /// OAuth session: JWT access token (15-min TTL in v1), optional refresh.
    case oauth(accessToken: String, refreshToken: String?, expiresAt: Date?, provider: AuthProvider)

    /// The bearer token to send in `Authorization: Bearer <token>` or as a
    /// WS ticket query parameter.
    public var accessToken: String {
        switch self {
        case .basic(_, let token, _):      return token
        case .oauth(let token, _, _, _):   return token
        }
    }

    /// When the token expires, if known.
    public var expiresAt: Date? {
        switch self {
        case .basic(_, _, let d):          return d
        case .oauth(_, _, let d, _):       return d
        }
    }

    /// Whether the credential is expired (or absent when expiry is known).
    public var isExpired: Bool {
        guard let exp = expiresAt else { return false }
        // 30-second clock-skew margin.
        return exp.timeIntervalSinceNow < -30
    }

    /// The auth provider that issued this credential.
    public var provider: AuthProvider {
        switch self {
        case .basic:          return .basic
        case .oauth(_, _, _, let p): return p
        }
    }
}

// MARK: - Auth store errors

public enum AuthStoreError: Error, LocalizedError {
    case keychainError(OSStatus)
    case encodingError(Error)
    case decodingError(Error)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .keychainError(let s): return "Keychain error (OSStatus \(s))"
        case .encodingError(let e): return "Encoding error: \(e.localizedDescription)"
        case .decodingError(let e): return "Decoding error: \(e.localizedDescription)"
        case .notFound:             return "No credentials found for this host"
        }
    }
}

// MARK: - Keychain-backed store

/// Persists `GatewayCredentials` per gateway host in the iOS Keychain.
///
/// - Note: All operations are synchronous and main-actor-free so they can be
///   called from any isolation domain. Keychain calls are thread-safe.
public final class AuthStore: Sendable {

    /// Shared singleton. Replace via `AuthStore.shared = …` for testing.
    public nonisolated(unsafe) static var shared = AuthStore()

    /// Keychain service identifier. Change only if you need app-group isolation.
    public let service: String

    public init(service: String = "com.nousresearch.hermes.mobile.auth") {
        self.service = service
    }

    // MARK: - Public API

    /// Store credentials for a gateway host.
    public func store(_ credentials: GatewayCredentials, forHost host: String) throws {
        let key = hostKey(host)
        let data = try encode(credentials)
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        key,
            kSecValueData as String:          data,
            kSecAttrAccessible as String:     kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        // Delete any existing entry first (SecItemUpdate is finicky with
        // attribute changes; delete+add is reliable).
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AuthStoreError.keychainError(status)
        }
    }

    /// Retrieve stored credentials for a gateway host.
    public func retrieve(forHost host: String) throws -> GatewayCredentials {
        let key = hostKey(host)
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        key,
            kSecReturnData as String:         true,
            kSecMatchLimit as String:         kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { throw AuthStoreError.notFound }
            throw AuthStoreError.keychainError(status)
        }
        guard let data = result as? Data else { throw AuthStoreError.notFound }
        return try decode(data)
    }

    /// Delete stored credentials for a gateway host.
    public func delete(forHost host: String) throws {
        let key = hostKey(host)
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthStoreError.keychainError(status)
        }
    }

    /// Whether credentials exist for a host (without decoding them).
    public func contains(host: String) -> Bool {
        let key = hostKey(host)
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        key,
            kSecReturnData as String:         false,
            kSecMatchLimit as String:         kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - Private

    private func hostKey(_ host: String) -> String {
        // Normalise: strip scheme, trailing slash.
        var h = host.lowercased()
        if h.hasPrefix("https://") { h = String(h.dropFirst(8)) }
        else if h.hasPrefix("http://") { h = String(h.dropFirst(7)) }
        if h.hasSuffix("/") { h = String(h.dropLast()) }
        return "gw:\(h)"
    }

    private func encode(_ creds: GatewayCredentials) throws -> Data {
        let wrapper: [String: Any] = {
            switch creds {
            case .basic(let u, let t, let exp):
                return [
                    "type": "basic",
                    "username": u,
                    "accessToken": t,
                    "expiresAt": exp?.timeIntervalSince1970 as Any,
                ] as [String: Any]
            case .oauth(let t, let r, let exp, let p):
                return [
                    "type": "oauth",
                    "accessToken": t,
                    "refreshToken": r as Any,
                    "expiresAt": exp?.timeIntervalSince1970 as Any,
                    "provider": p.rawValue,
                ] as [String: Any]
            }
        }()
        do {
            return try JSONSerialization.data(withJSONObject: wrapper)
        } catch {
            throw AuthStoreError.encodingError(error)
        }
    }

    private func decode(_ data: Data) throws -> GatewayCredentials {
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = dict["type"] as? String else {
            throw AuthStoreError.decodingError(DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Missing type field")
            ))
        }
        let exp: Date? = {
            if let ts = dict["expiresAt"] as? TimeInterval { return Date(timeIntervalSince1970: ts) }
            return nil
        }()
        switch type {
        case "basic":
            guard let u = dict["username"] as? String,
                  let t = dict["accessToken"] as? String else {
                throw AuthStoreError.decodingError(DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "Missing basic fields")
                ))
            }
            return .basic(username: u, accessToken: t, expiresAt: exp)
        case "oauth":
            guard let t = dict["accessToken"] as? String,
                  let pRaw = dict["provider"] as? String,
                  let p = AuthProvider(rawValue: pRaw) else {
                throw AuthStoreError.decodingError(DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "Missing oauth fields")
                ))
            }
            let r = dict["refreshToken"] as? String
            return .oauth(accessToken: t, refreshToken: r, expiresAt: exp, provider: p)
        default:
            throw AuthStoreError.decodingError(DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Unknown credential type: \(type)")
            ))
        }
    }
}
