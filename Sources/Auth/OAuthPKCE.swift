//
//  OAuthPKCE.swift
//  RFC 7636 PKCE helpers for OAuth authorization-code grants.
//
//  Generates a cryptographically random code verifier and its S256
//  code challenge, suitable for both the Nous Portal and self-hosted
//  OIDC providers.
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// PKCE (Proof Key for Code Exchange) parameters for an OAuth session.
///
/// Create one before starting the authorization redirect; persist the
/// `verifier` in a short-lived cookie or app state so it survives the
/// round-trip through the IDP.  Send `challenge` + `challengeMethod` in
/// the authorize URL; send `verifier` in the token exchange.
public struct PKCE: Sendable {
    /// The code verifier (43–128 chars, URL-safe base64).
    public let verifier: String
    /// The S256 code challenge (base64url, no padding).
    public let challenge: String
    /// Always "S256" — the Hermes dashboard requires it.
    public let challengeMethod: String = "S256"

    /// Generate a fresh PKCE pair.
    public init() {
        // RFC 7636 §4.1: 43–128 chars of [A-Z] / [a-z] / [0-9] / "-._~"
        // We use 32 bytes → 43 base64url chars (minimum length).
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        self.verifier = Self.base64urlEncode(Data(bytes))

        // S256: BASE64URL(SHA256(verifier))
        let verifierData = Data(self.verifier.utf8)
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: verifierData)
        self.challenge = Self.base64urlEncode(Data(digest))
        #else
        // Fallback for Linux without CryptoKit: use CommonCrypto via
        // C interop or fall back to a Foundation-based approach.
        // On Linux with Swift 5.10+, CryptoKit is available via swift-crypto.
        // For now, provide a CC fallback:
        var hash = [UInt8](repeating: 0, count: 32)
        verifierData.withUnsafeBytes { ptr in
            CC_SHA256(ptr.baseAddress, CC_LONG(verifierData.count), &hash)
        }
        self.challenge = Self.base64urlEncode(Data(hash))
        #endif
    }

    // MARK: - Internal

    /// Base64url encoding without padding (RFC 7636 Appendix B).
    static func base64urlEncode(_ data: Data) -> String {
        let str = data.base64EncodedString()
        return str
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Linux fallback for SHA-256

#if !canImport(CryptoKit)
/// On Linux without CryptoKit, we need CC_SHA256 from OpenSSL/CommonCrypto.
/// SwiftPM on Linux ships `CC_*` via the `Crypto` C module.
/// If unavailable, we use a pure-Swift SHA-256 from Foundation.
///
/// This is a minimal SHA-256 implementation for platforms where neither
/// CryptoKit nor CommonCrypto is available.
private func CC_SHA256(_ data: UnsafeRawPointer?, _ len: CC_LONG, _ md: UnsafeMutablePointer<UInt8>) {
    // Pure-Swift SHA-256 fallback.
    // This is a compact implementation sufficient for PKCE challenge generation.
    let input = Data(bytes: data!, count: Int(len))
    let digest = SHA256Fallback.hash(input)
    digest.withUnsafeBytes { ptr in
        md.initialize(from: ptr.baseAddress!, count: 32)
    }
}

private typealias CC_LONG = UInt32

/// Minimal SHA-256 for Linux fallback.
private enum SHA256Fallback {
    static func hash(_ data: Data) -> Data {
        // Pad the message
        var msg = [UInt8](data)
        let bitLen = msg.count * 8
        msg.append(0x80)
        while (msg.count % 64) != 56 { msg.append(0) }
        var lenBytes = withUnsafeBytes(of: UInt64(bigEndian: UInt64(bitLen))) { Array($0) }
        msg.append(contentsOf: lenBytes)

        // Initial hash values
        var h0: UInt32 = 0x6a09e667, h1: UInt32 = 0xbb67ae85
        var h2: UInt32 = 0x3c6ef372, h3: UInt32 = 0xa54ff53a
        var h4: UInt32 = 0x510e527f, h5: UInt32 = 0x9b05688c
        var h6: UInt32 = 0x1f83d9ab, h7: UInt32 = 0x5be0cd19

        // Round constants
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
            0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
            0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
            0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
            0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
            0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
            0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
            0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
            0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]

        func ch(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) ^ (~x & z) }
        func maj(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) ^ (x & z) ^ (y & z) }
        func rotR(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        func sig0(_ x: UInt32) -> UInt32 { rotR(x, 2) ^ rotR(x, 13) ^ rotR(x, 22) }
        func sig1(_ x: UInt32) -> UInt32 { rotR(x, 6) ^ rotR(x, 11) ^ rotR(x, 25) }
        func sig0small(_ x: UInt32) -> UInt32 { rotR(x, 7) ^ rotR(x, 18) ^ (x >> 3) }
        func sig1small(_ x: UInt32) -> UInt32 { rotR(x, 17) ^ rotR(x, 19) ^ (x >> 10) }

        // Process each 64-byte block
        var offset = 0
        while offset < msg.count {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                w[i] = UInt32(msg[offset + i * 4]) << 24
                      | UInt32(msg[offset + i * 4 + 1]) << 16
                      | UInt32(msg[offset + i * 4 + 2]) << 8
                      | UInt32(msg[offset + i * 4 + 3])
            }
            for i in 16..<64 {
                w[i] = sig1small(w[i-2]) &+ w[i-7] &+ sig0small(w[i-15]) &+ w[i-16]
            }

            var a = h0, b = h1, c = h2, d = h3
            var e = h4, f = h5, g = h6, hh = h7

            for i in 0..<64 {
                let t1 = hh &+ sig1(e) &+ ch(e, f, g) &+ k[i] &+ w[i]
                let t2 = sig0(a) &+ maj(a, b, c)
                hh = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }

            h0 &+= a; h1 &+= b; h2 &+= c; h3 &+= d
            h4 &+= e; h5 &+= f; h6 &+= g; h7 &+= hh

            offset += 64
        }

        var result = Data()
        for h in [h0, h1, h2, h3, h4, h5, h6, h7] {
            var bigH = h.bigEndian
            result.append(Data(bytes: &bigH, count: 4))
        }
        return result
    }
}
#endif
