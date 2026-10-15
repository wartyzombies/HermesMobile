//
//  ReconnectBackoff.swift
//  Port of apps/shared/src/reconnect-backoff.ts — full-jitter exponential.
//

import Foundation

/// Full-jitter exponential backoff for WebSocket reconnects.
///
/// Default is full jitter: a bare exponential still lets every client in a
/// fleet retry in lockstep — after a gateway restart, N clients that all
/// disconnected within the same instant all redial at the same instant too.
/// Full jitter (AWS "Exponential Backoff And Jitter") spreads that out.
public struct ReconnectBackoff: Sendable {
    /// Delay for the first retry (attempt 0) before jitter, in ms.
    public var baseDelayMs: Int
    /// Ceiling on the exponential delay before jitter, in ms.
    public var capMs: Int
    /// Full jitter (default) or the bare ceiling.
    public var jitter: Bool

    public init(baseDelayMs: Int = 300, capMs: Int = 15_000, jitter: Bool = true) {
        self.baseDelayMs = baseDelayMs
        self.capMs = capMs
        self.jitter = jitter
    }

    /// A socket that opens and dies inside this window counts as a FAILED
    /// attempt: resetting the ladder on every such "open" redials at attempt
    /// 0 forever (#83134: 55 sockets in 12s).
    public static let stableOpenMs: Int = 5_000

    /// True when a socket opened at `openedAt` stayed up long enough to reset
    /// the backoff ladder.
    public static func isStableOpen(openedAt: Date?, now: Date = Date()) -> Bool {
        guard let opened = openedAt else { return false }
        return now.timeIntervalSince(opened) * 1000 >= Double(stableOpenMs)
    }

    /// Delay (in milliseconds) before reconnect attempt number `attempt`
    /// (0-indexed). With jitter the value lies in [0, ceiling); without it,
    /// it IS the ceiling.
    public func delayMs(attempt: Int) -> Int {
        let exp = min(max(0, attempt), 32)
        let ceiling = min(capMs, baseDelayMs * (1 << exp))
        guard jitter else { return ceiling }
        return Int.random(in: 0..<max(1, ceiling))
    }
}
