//
//  GatewayClient.swift
//  WebSocket JSON-RPC 2.0 client for `hermes serve` (tui_gateway).
//
//  Ports the transport, correlation, heartbeat, and reconnect-replay logic
//  from apps/shared/src/json-rpc-channel.ts + json-rpc-gateway.ts.
//

import Foundation
import GeneratedModels
import HermesLogger

// MARK: - Connection state

/// Lifecycle states of the gateway WebSocket.
public enum GatewayConnectionState: String, Sendable {
    case idle, connecting, open, closed, error, reconnecting
}

// MARK: - Pending call

/// One in-flight JSON-RPC request awaiting its response.
///
/// `@unchecked Sendable` is justified because all access is confined to the
/// `@MainActor`-isolated `GatewayClient`; the timeout `Task` inherits that
/// isolation. Do not add a `nonisolated` accessor.
private final class PendingCall: @unchecked Sendable {
    let id: JSONRPCFrame.JSONID
    let resolve: (JSONValue) -> Void
    let reject: (Error) -> Void
    /// The timeout `Task`. Cancelled on response, send-failure, or disconnect.
    var task: Task<Void, Never>?

    init(id: JSONRPCFrame.JSONID,
         resolve: @escaping (JSONValue) -> Void,
         reject: @escaping (Error) -> Void) {
        self.id = id
        self.resolve = resolve
        self.reject = reject
    }
}

// MARK: - Server→client request handler

/// Handles a JSON-RPC request initiated by the gateway (e.g. an approval).
public protocol ServerRequestHandler: AnyObject, Sendable {
    /// Return `true` if the request was handled; the client will not
    /// send the default `-32601` method-not-found reply.
    func handle(request: ServerRequest) -> Bool
}

/// A JSON-RPC request sent by the gateway to the client.
public struct ServerRequest: Sendable {
    public let id: String
    public let method: String
    public let params: JSONValue
    public let replayed: Bool
    public let respond: @Sendable (JSONValue) -> Void
    public let fail: @Sendable (Int, String) -> Void
}

// MARK: - Event handler token

/// Cancels an event handler registered via `on(_:handler:)` or `onAny(_:)`.
///
/// The token captures the handler's numeric id, so cancellation is exact and
/// does not rely on closure identity (which is not reference-stable — A3).
public final class HandlerToken: Sendable {
    fileprivate let remove: @Sendable () -> Void
    init(_ remove: @escaping @Sendable () -> Void) { self.remove = remove }
    /// Remove the associated handler. Safe to call more than once.
    public func cancel() { remove() }
}

// MARK: - GatewayClient

/// WebSocket JSON-RPC client for the Hermes `tui_gateway` API.
///
/// Owns: socket lifecycle, request-id correlation, per-call timeouts, the
/// `gateway.ping` heartbeat, event notification fan-out, and lossless reconnect
/// replay via `session.events.since`.
///
/// The caller owns: auth (minting WS tickets) and the reconnect schedule
/// (calling `connect` again on `.closed`/`.error`). `ReconnectBackoff` is
/// provided for the caller's convenience but is not driven automatically.
@MainActor
public final class GatewayClient: NSObject {
    private static let logger = HermesLogger(subsystem: "com.nousresearch.hermes.mobile", category: "GatewayClient")
    /// Per-request timeout (default 120s).
    public var requestTimeoutMs: Int = 120_000
    /// Heartbeat interval (default 15s).
    public var heartbeatIntervalMs: Int = 15_000
    /// Maximum time with no inbound frame before the socket is dropped (default 45s).
    public var heartbeatDeadlineMs: Int = 45_000
    /// Connect handshake timeout (default 15s).
    public var connectTimeoutMs: Int = 15_000
    /// Whether to fetch missed events on reconnect via `session.events.since`.
    public var replayEnabled: Bool = true

    // State
    /// Current connection state.
    public private(set) var state: GatewayConnectionState = .idle
    /// Replay epoch advertised by the gateway; a change invalidates cursors.
    public private(set) var replayEpoch: String?

    // Socket
    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    /// Monotonic generation counter; used to discard stale-socket callbacks.
    private var socketGeneration: Int = 0
    /// Timestamp the current socket opened; used for stable-open detection.
    private var openedAt: Date?
    /// Fire-and-forget connect-timeout task; cancelled on open/disconnect (A10).
    private var connectTimeoutTask: Task<Void, Never>?

    // Request correlation
    private var nextId: Int64 = 0
    /// In-flight requests, keyed by a normalised string form of the JSON-RPC id.
    private var pending: [String: PendingCall] = [:]

    // Heartbeat
    private var heartbeatTask: Task<Void, Never>?
    private var lastLivenessAt: Date = .distantPast
    private var heartbeatSequence: Int64 = 0

    // Event fan-out. Handlers are keyed by a monotonically increasing id so
    // that cancellation is exact (A3: closure identity is not stable).
    private var handlerSeq: UInt64 = 0
    private var eventHandlers: [String: [UInt64: (JSONValue) -> Void]] = [:]
    private var wildcardHandlers: [UInt64: (JSONValue) -> Void] = [:]

    // Server→client requests
    private var requestHandlers: [any ServerRequestHandler] = []

    // Replay
    /// Per-session `seq` watermark of the last event delivered to handlers.
    private var lastSeenSeq: [String: Int64] = [:]
    private var replayGeneration: Int = 0
    /// Live frames parked per-session while a replay fetch is in flight.
    private var replayHold: [String: [JSONValue]]?

    // Reconnect (caller-driven)
    /// Backoff ladder the caller may consult when scheduling reconnects.
    public var reconnectBackoff = ReconnectBackoff()
    /// Called on every state transition.
    public var onStateChange: ((GatewayConnectionState) -> Void)?
    /// Supplies a fresh single-use WS ticket before each dial.
    public var ticketProvider: (@Sendable () async -> String?)?

    // MARK: - Connect

    /// Open the WebSocket to `wsUrl`.
    ///
    /// - Parameter wsUrl: the gateway WebSocket URL. **Must be `wss://`**
    ///   except in DEBUG builds; a `ws://` URL is rejected to keep the
    ///   session (prompts, approval decisions) off cleartext (R6).
    public func connect(wsUrl: URL) {
        guard state != .connecting && state != .open else { return }

        // Security (R6): refuse cleartext except behind a DEBUG escape hatch.
        #if DEBUG
        let allowedSchemes = ["wss", "ws"]
        #else
        let allowedSchemes = ["wss"]
        #endif
        guard let scheme = wsUrl.scheme?.lowercased(), allowedSchemes.contains(scheme) else {
            Self.logger.error("error: refusing non-wss WebSocket URL")
            setState(.error)
            return
        }

        setState(.connecting)

        let gen = ++socketGeneration
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = TimeInterval(connectTimeoutMs) / 1000.0
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        urlSession = session

        var req = URLRequest(url: wsUrl)
        req.setValue("gateway-client-swift/1.0", forHTTPHeaderField: "User-Agent")

        // Attach a fresh single-use ticket if a provider is set (R6: the
        // provider was previously declared but never called). The provider is
        // async, so we mint the ticket before the handshake without blocking
        // the caller.
        if let ticketProvider {
            self.connectTimeoutTask = Task { [weak self] in
                guard let self else { return }
                if let ticket = await ticketProvider() {
                    req.setValue(ticket, forHTTPHeaderField: "Authorization")
                }
                self.dial(generation: gen, request: req, session: session)
            }
            return
        }

        dial(generation: gen, request: req, session: session)
    }

    /// Perform the actual WebSocket dial. Split out so the ticket provider can
    /// mint a ticket before the handshake without blocking the caller.
    private func dial(generation gen: Int, request: URLRequest, session: URLSession) {
        let task = session.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        // Connect timeout (A10: stored so disconnect/didOpen can cancel it).
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { [weak self] in
            let timeout = UInt64(self?.connectTimeoutMs ?? 15_000) * 1_000_000
            try? await Task.sleep(nanoseconds: timeout)
            guard let self else { return }
            if gen == self.socketGeneration && self.state == .connecting {
                Self.logger.error("connect timeout \(self.connectTimeoutMs)ms")
                task.cancel(with: .goingAway, reason: nil)
                self.setState(.error)
            }
        }

        startReceiveLoop(generation: gen)
    }

    /// Close the socket and tear down all in-flight state.
    public func disconnect() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        rejectAllPending(JSONRPCError(code: -1, message: "disconnected"))
        openedAt = nil
        setState(.idle)
    }

    // MARK: - Receive loop

    /// Pump inbound frames until the socket dies or is superseded.
    ///
    /// The loop is driven by `receive()` throwing (A2: `URLSessionTask.State`
    /// has no `.open` case, so a `while … case .open = task.state` guard
    /// never matched and the client was write-only).
    private func startReceiveLoop(generation gen: Int) {
        guard let task = webSocketTask else { return }
        Task { [weak self] in
            guard let self else { return }
            while gen == self.socketGeneration {
                do {
                    let msg = try await task.receive()
                    switch msg {
                    case .string(let text):
                        self.handleFrame(text, generation: gen)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleFrame(text, generation: gen)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    if gen == self.socketGeneration {
                        Self.logger.error("receive error")
                        self.dropSocket(reason: "receive error")
                    }
                    break
                }
            }
        }
    }

    // MARK: - Frame dispatch

    private func handleFrame(_ text: String, generation gen: Int) {
        guard let data = text.data(using: .utf8) else { return }

        // Try to decode as a top-level frame.
        guard let frame = try? JSONDecoder().decode(JSONRPCFrame.self, from: data) else {
            // Security (R7): never log frame payload bytes — a gateway event
            // frame carries conversation content. Log metadata only.
            Self.logger.error("unparseable frame: \(data.count) bytes")
            return
        }

        // Reset liveness on ANY inbound frame (heartbeatLiveness: 'any-inbound').
        lastLivenessAt = Date()

        // 1) Response to our request
        if let id = frame.id, frame.result != nil || frame.error != nil {
            handleResponse(frame: frame, id: id)
            return
        }

        // 2) Notification (method == "event")
        if frame.method == "event" || frame.method == "notification" {
            if let params = frame.params {
                dispatchEvent(params, replayed: false)
            }
            return
        }

        // 3) Server→client request (has both id (string) and method)
        if let id = frame.id, let method = frame.method, frame.result == nil && frame.error == nil {
            handleServerRequest(id: id, method: method, params: frame.params ?? .null)
        }
    }

    // MARK: - Response correlation

    private func handleResponse(frame: JSONRPCFrame, id: JSONRPCFrame.JSONID) {
        // Key by the normalised string form so a server that echoes string ids
        // still correlates with the integer ids this client sends (Y9).
        let key = id.key
        guard let call = pending.removeValue(forKey: key) else { return }
        call.task?.cancel()

        if let err = frame.error {
            call.reject(JSONRPCError(code: err.code, message: err.message, data: err.data))
        } else {
            call.resolve(frame.result ?? .null)
        }
    }

    // MARK: - Server→client requests

    private func handleServerRequest(id: JSONRPCFrame.JSONID, method: String, params: JSONValue) {
        let idStr = id.key

        // Respond/fail must hop back to the main actor because they touch
        // `sendRawFrame` (main-actor-isolated). Wrapping in `Task { @MainActor }`
        // keeps the `@Sendable` closures valid under Swift 6.
        let respond: @Sendable (JSONValue) -> Void = { [weak self] result in
            Task { @MainActor in
                self?.sendRawFrame(["jsonrpc": "2.0", "id": idStr, "result": result])
            }
        }
        let fail: @Sendable (Int, String) -> Void = { [weak self] code, msg in
            let err: [String: Any] = ["code": code, "message": msg]
            Task { @MainActor in
                self?.sendRawFrame(["jsonrpc": "2.0", "id": idStr, "error": err])
            }
        }

        let req = ServerRequest(
            id: idStr, method: method, params: params, replayed: false,
            respond: respond, fail: fail
        )

        for handler in requestHandlers {
            if handler.handle(request: req) { return }
        }
        // Unhandled: answer -32601 so the backend doesn't wait out its deadline.
        Self.logger.notice("unhandled server→client request: \(method, privacy: .public)")
        fail(JSONRPCErrorCode.methodNotFound, "method not found: \(method)")
    }

    // MARK: - Request

    /// Send a JSON-RPC request and await the typed result.
    /// - Parameters:
    ///   - method: the RPC method name.
    ///   - params: the request params (default `null`).
    ///   - timeoutMs: per-call timeout override.
    /// - Returns: the result decoded into `T`.
    public func request<T: Decodable>(
        _ method: String,
        params: JSONValue = .null,
        timeoutMs: Int? = nil
    ) async throws -> T {
        let raw = try await requestRaw(method, params: params, timeoutMs: timeoutMs)
        let data = try JSONEncoder().encode(raw)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Send a JSON-RPC request and return the raw `JSONValue` result.
    /// - Parameters:
    ///   - method: the RPC method name.
    ///   - params: the request params (default `null`).
    ///   - timeoutMs: per-call timeout override.
    /// - Returns: the raw result value.
    public func requestRaw(
        _ method: String,
        params: JSONValue = .null,
        timeoutMs: Int? = nil
    ) async throws -> JSONValue {
        guard state == .open, webSocketTask != nil else {
            throw JSONRPCError(code: -1, message: "gateway not connected")
        }

        let id = ++nextId
        let jsonId = JSONRPCFrame.JSONID.number(id)
        let key = jsonId.key
        let timeout = timeoutMs ?? requestTimeoutMs

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONValue, Error>) in
            let call = PendingCall(
                id: jsonId,
                resolve: { cont.resume(returning: $0) },
                reject: { cont.resume(throwing: $0) }
            )

            // Register the pending call BEFORE arming the timeout (Y10: with a
            // 0/1ms timeout the timeout Task could otherwise run and find no
            // entry, leaking the continuation).
            pending[key] = call

            // Timeout (A6: only `task` is tracked; the dead `timer` field is gone).
            if timeout > 0 {
                call.task = Task { [weak self] in
                    let ns = UInt64(timeout) * 1_000_000
                    try? await Task.sleep(nanoseconds: ns)
                    guard let self else { return }
                    if let removed = self.pending.removeValue(forKey: key) {
                        removed.reject(JSONRPCError(code: -1, message: "request timed out after \(timeout / 1000)s: \(method)"))
                    }
                }
            }

            // Send
            do {
                let frame: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": Int(id),
                    "method": method,
                    "params": jsonValueToAny(params),
                ]
                let data = try JSONSerialization.data(withJSONObject: frame)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw JSONRPCError(code: -1, message: "encoding failed")
                }
                webSocketTask?.send(.string(text)) { error in
                    if let error {
                        if let removed = self.pending.removeValue(forKey: key) {
                            removed.reject(error)
                        }
                    }
                }
            } catch {
                pending.removeValue(forKey: key)?.reject(error)
            }
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatSequence = 0
        lastLivenessAt = Date()

        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let ns = UInt64(self.heartbeatIntervalMs) * 1_000_000
                try? await Task.sleep(nanoseconds: ns)
                guard !Task.isCancelled else { return }
                await self.sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() {
        guard state == .open else { return }

        // Check deadline (any-inbound liveness).
        let elapsed = Date().timeIntervalSince(lastLivenessAt) * 1000
        if elapsed > Double(heartbeatDeadlineMs) {
            Self.logger.error("heartbeat deadline exceeded \(elapsed)ms — dropping socket")
            dropSocket(reason: "heartbeat deadline")
            return
        }

        heartbeatSequence += 1

        // Send a lightweight ping using the JSON-RPC ping method.
        Task { [weak self] in
            guard let self else { return }
            do {
                let _: JSONValue = try await self.requestRaw("ping", params: .null, timeoutMs: self.heartbeatDeadlineMs)
            } catch {
                Self.logger.error("heartbeat ping failed")
                self.dropSocket(reason: "heartbeat ping failed")
            }
        }
    }

    // MARK: - Event fan-out

    /// Register a typed event handler. Returns a token to cancel.
    /// - Parameters:
    ///   - eventType: the event `type` to match, or `"*"` for all.
    ///   - handler: the callback.
    /// - Returns: a `HandlerToken`; call `cancel()` to remove the handler.
    public func on(_ eventType: String, handler: @escaping (JSONValue) -> Void) -> HandlerToken {
        handlerSeq += 1
        let id = handlerSeq
        eventHandlers[eventType, default: [:]][id] = handler
        return HandlerToken { [weak self] in
            self?.eventHandlers[eventType]?.removeValue(forKey: id)
        }
    }

    /// Register a wildcard handler (all events). Returns a token to cancel.
    /// - Parameter handler: the callback.
    /// - Returns: a `HandlerToken`; call `cancel()` to remove the handler.
    public func onAny(_ handler: @escaping (JSONValue) -> Void) -> HandlerToken {
        handlerSeq += 1
        let id = handlerSeq
        wildcardHandlers[id] = handler
        return HandlerToken { [weak self] in
            self?.wildcardHandlers.removeValue(forKey: id)
        }
    }

    /// Register a server→client request handler.
    /// - Parameter handler: an object conforming to `ServerRequestHandler`.
    public func registerRequestHandler(_ handler: any ServerRequestHandler) {
        requestHandlers.append(handler)
    }

    /// Route an event to typed/wildcard handlers, honouring the replay hold.
    /// - Parameters:
    ///   - params: the event payload.
    ///   - replayed: `true` when the frame was fetched via replay rather than
    ///     received live. Used to skip watermark bookkeeping for replayed frames.
    private func dispatchEvent(_ params: JSONValue, replayed: Bool) {
        // Extract `type` from the params to route typed handlers.
        let eventType: String
        if case .object(let dict) = params {
            if case .string(let t) = dict["type"] ?? .null {
                eventType = t
            } else {
                eventType = "*"
            }
        } else {
            eventType = "*"
        }

        // Replay hold: park live frames for sessions currently being replayed so
        // they are delivered after the replayed backlog (A4). The watermark is
        // updated AFTER the hold check so a parked frame does not advance the
        // watermark past events that were never delivered (Y3).
        if let hold = replayHold,
           case .object(let dict) = params,
           case .string(let sid) = dict["session_id"] ?? .null,
           hold[sid] != nil {
            replayHold?[sid]?.append(params)
            return
        }

        // Update seq watermark for lossless replay (only for delivered frames).
        if !replayed,
           case .object(let dict) = params,
           case .integer(let seq) = dict["seq"] ?? .null,
           case .string(let sid) = dict["session_id"] ?? .null {
            lastSeenSeq[sid] = max(lastSeenSeq[sid] ?? 0, seq)
        }

        // Dispatch to typed handlers
        for h in eventHandlers[eventType] ?? [] {
            h.value(params)
        }
        // Wildcard
        for h in wildcardHandlers {
            h.value(params)
        }
    }

    // MARK: - Reconnect replay

    /// Called after the socket opens. Fetches missed events via
    /// `session.events.since` using the per-session seq watermark.
    private func fetchReplay() {
        guard replayEnabled, !lastSeenSeq.isEmpty else { return }

        let gen = ++replayGeneration
        var hold: [String: [JSONValue]] = [:]
        for (sid, _) in lastSeenSeq {
            hold[sid] = []
        }
        // Park any frames held by a superseded in-flight replay rather than
        // dropping them on the floor (Y4).
        if let previous = replayHold {
            for (sid, frames) in previous {
                hold[sid, default: []].append(contentsOf: frames)
            }
        }
        replayHold = hold

        for (sid, lastSeen) in lastSeenSeq {
            Task { [weak self] in
                guard let self else { return }
                await self.fetchSessionReplay(sid: sid, lastSeen: lastSeen, generation: gen)
            }
        }
    }

    private func fetchSessionReplay(sid: String, lastSeen: Int64, generation gen: Int) async {
        guard gen == replayGeneration else { return }

        do {
            let result: SessionEventsSinceResult = try await request(
                "session.events.since",
                params: .object([
                    "session_id": .string(sid),
                    "last_seen": .integer(lastSeen),
                ]),
                timeoutMs: 10_000
            )

            guard gen == replayGeneration else { return }

            // Epoch mismatch → backend restarted, cursor invalid.
            if let epoch = result.epoch, !epoch.isEmpty {
                if let known = replayEpoch, epoch != known {
                    replayEpoch = epoch
                    // Old cursor no longer valid — skip to head.
                    lastSeenSeq[sid] = max(lastSeen, result.latestSeq)
                    flushReplayHold(sid: sid, generation: gen)
                    return
                }
                if replayEpoch == nil { replayEpoch = epoch }
            }

            if result.truncated {
                // Ring evicted events in the gap — skip to head, refetch history.
                lastSeenSeq[sid] = max(lastSeen, result.latestSeq)
                flushReplayHold(sid: sid, generation: gen)
                return
            }

            // Dispatch replayed events.
            for event in result.events {
                guard gen == replayGeneration else { return }
                if let raw = try? JSONEncoder().encode(event) {
                    let value = (try? JSONDecoder().decode(JSONValue.self, from: raw)) ?? .null
                    // Mutate to mark as replayed.
                    if case .object(var dict) = value {
                        dict["replayed"] = .bool(true)
                        dispatchEvent(.object(dict), replayed: true)
                    } else {
                        dispatchEvent(value, replayed: true)
                    }
                }
            }
        } catch {
            Self.logger.notice("replay fetch failed for \(sid, privacy: .public)")
        }

        flushReplayHold(sid: sid, generation: gen)
    }

    /// Flush live frames parked during a replay fetch.
    ///
    /// Even when superseded (`gen != replayGeneration`) the parked frames are
    /// still dispatched — the newer replay's own fetch re-orders them, so
    /// dropping them would silently lose events (Y4).
    private func flushReplayHold(sid: String, generation gen: Int) {
        guard let parked = replayHold?.removeValue(forKey: sid) else { return }
        if replayHold?.isEmpty == true { replayHold = nil }
        for frame in parked {
            dispatchEvent(frame, replayed: false)
        }
    }

    // MARK: - Socket lifecycle

    /// Drop the current socket and transition to `.closed`.
    /// - Parameter reason: a short, non-sensitive reason (logged).
    private func dropSocket(reason: String) {
        Self.logger.notice("dropSocket: \(reason, privacy: .public)")
        let wasOpen = state == .open
        let opened = openedAt
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        rejectAllPending(JSONRPCError(code: -1, message: reason))
        heartbeatTask?.cancel()
        heartbeatTask = nil
        openedAt = nil

        // Record whether the connection was stable so the caller's reconnect
        // loop can reset the backoff ladder (A5/A7). `ReconnectBackoff` is
        // caller-driven; surface the measurement via a state change.
        if wasOpen && ReconnectBackoff.isStableOpen(openedAt: opened) {
            onStateChange?(.closed)
        }
        setState(.closed)
    }

    private func setState(_ newState: GatewayConnectionState) {
        guard state != newState else { return }
        state = newState
        Self.logger.notice("state → \(newState.rawValue, privacy: .public)")
        onStateChange?(newState)
    }

    private func rejectAllPending(_ error: Error) {
        for (_, call) in pending {
            call.task?.cancel()
            call.reject(error)
        }
        pending.removeAll()
    }

    // MARK: - Raw frame send

    private func sendRawFrame(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(text)) { _ in }
    }

    // MARK: - JSONValue → Any

    private func jsonValueToAny(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return b
        case .integer(let i): return Int(i)
        case .number(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { jsonValueToAny($0) }
        case .object(let o): return o.mapValues { jsonValueToAny($0) }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension GatewayClient: URLSessionWebSocketDelegate {
    nonisolated public func urlSession(
        _ session: URLSession,
        webSocketTask task: URLSessionWebSocketTask,
        didOpenWithProtocol protocolName: String?
    ) {
        Task { @MainActor in
            // A1: compare the task the callback carries against the current
            // socket, not a tautology, so a stale-generation open cannot
            // clobber a healthy newer connection.
            guard task === self.webSocketTask else { return }
            self.connectTimeoutTask?.cancel()
            self.connectTimeoutTask = nil
            self.openedAt = Date()
            self.lastLivenessAt = Date()
            self.setState(.open)
            self.startHeartbeat()
            self.fetchReplay()
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        webSocketTask task: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor in
            // A1: identity check so a stale close cannot mark a newer socket .error.
            guard task === self.webSocketTask else { return }
            Self.logger.notice("WebSocket closed: code=\(closeCode.rawValue)")
            // 4401 = WS ticket didn't authenticate; 4403 = request guard rejected.
            if closeCode.rawValue == 4401 || closeCode.rawValue == 4403 {
                setState(.error)
                // Caller should re-auth (re-mint ticket).
            } else {
                dropSocket(reason: "WebSocket closed: \(closeCode.rawValue)")
            }
        }
    }
}
