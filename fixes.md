# HermesMobile — Code Review Findings

Review date: 2026-10-13
Commit reviewed: `96a23f0 initial commit.` (entire codebase — no prior baseline)
Scope: hand-written Swift under `Sources/` excluding `Sources/Generated/` (machine-generated from `openrpc.json`), plus `Package.swift`.
Platform: Swift 6.4 toolchain, `swift-tools-version:5.10`, declared platforms iOS 17 / macOS 14.

## Severity legend

| Light | Meaning |
|:-----:|---------|
| 🔴 **RED** | Crashes, fails to build, corrupts data, or is a security vulnerability. Must fix before shipping. |
| 🟠 **AMBER** | Real bug or design defect under specific conditions; wrong results, resource leaks, broken cancellation. Fix soon. |
| 🟡 **YELLOW** | Latent risk, incomplete implementation, or dead/misleading code. No immediate failure. |
| 🟢 **GREEN** | Verified-correct. Noted because it looks suspicious at a glance, or to record what was checked and cleared. |

---

## 🔴 RED — must fix

### R1. `swift build` fails outright — overlapping target sources
**`Package.swift:16-17`**

```
error: target 'HermesCoreWebSocket' has overlapping sources:
       Sources/HermesCoreWebSocket/web_socket.swift
```

`HermesMobile` uses `path: "Sources"` (unqualified), which recursively claims every subdirectory, including `Sources/HermesCoreWebSocket/` and `Sources/Generated/`. SwiftPM rejects the package before compiling a single file.

Reproduced:
```
$ swift build
error: 'hermesmobile': target 'HermesCoreWebSocket' has overlapping sources: ...
```

**Fix** — enumerate explicit `exclude:` paths, or point each target at its own directory:
```swift
.target(name: "HermesMobile", path: "Sources", exclude: [
    "HermesCoreWebSocket", "Generated", "GatewayClient",
]),
```
Also note `Sources/GatewayClient/HermesGatewayClient.swift` redeclares `public struct HermesCoreWebSocket` (`HermesGatewayClient.swift:27`) which also exists as `public class HermesCoreWebSocket` (`web_socket.swift:8`). Two types, one name, different modules — see R3.

---

### R2. Force-unwrap crash on every non-OAuth connect
**`Sources/GatewayClient/HermesGatewayClient.swift:287`**

```swift
case .token:
    break            // ticket is never set
case .basic:
    break            // ticket is never set
...
_ = try await HermesCoreWebSocket.connect(to: baseUrl, ticket: ticket!)  // 💥
```

`ticket` is only assigned in the `.oauth` branch (line 277). `GatewayAuthMode` defaults to `.token` (line 267), so the default constructor path hits `ticket!` on `nil` and traps immediately. Same trap for `.basic`.

**Fix** — make the ticket non-optional in the path that needs it, or guard:
```swift
case .token, .basic:
    guard let ticket else { throw HermesGatewayClientError.authRequired }
    ...
```

---

### R3. Duplicate `HermesCoreWebSocket` declaration
**`Sources/HermesCoreWebSocket/web_socket.swift:8`** vs **`Sources/GatewayClient/HermesGatewayClient.swift:27`**

One is `public class HermesCoreWebSocket` with a real `connect(session:ticket:onMessage:...)`; the other is `public struct HermesCoreWebSocket` whose only method is a `fatalError`. Both are `public` and both are visible to `HermesGatewayClient.swift`, which imports the `HermesCoreWebSocket` module (line 4).

Per Swift's module-scoping rules, the local declaration shadows the imported one within that file — so `HermesGatewayClient.connect()` calls the `fatalError` stub, never the real implementation. This is the intended placeholder behaviour, but the name collision makes it silent: a future edit to `web_socket.swift` will appear to do nothing.

**Fix** — delete the stub struct in `HermesGatewayClient.swift:27-33` and call the real module type directly.

---

### R4. `fatalError` on the primary RPC path
**`Sources/GatewayClient/HermesGatewayClient.swift:335`**

```swift
private func execute(methodName: GeneratedModels.GWMethod, params: Encodable) async throws -> Any {
    fatalError("WebSocket dispatch not implemented")
}
```

Every public method on `HermesGatewayClient` — `listSessions`, `submitPrompt`, `eventsSince`, `resumeSession`, `modelOptions`, `approvalRespond`, `createSession` — routes through this and traps. Same for `mintTicket()` at line 342 (`fatalError("OAuth ticket minting not implemented")`), which `.oauth` mode calls from `connect()`.

Acceptable as a prototype marker, but a `fatalError` in a `public` API surface will be reached by any caller and crash the app rather than surfacing an error.

**Fix** — throw `HermesGatewayClientError.connectionFailed("not implemented")` so callers can handle it, or gate the whole type behind `#if DEBUG`.

---

### R5. Unhandled force-unwrap risk: type errors in `HermesGatewayClient` calls
**`Sources/GatewayClient/HermesGatewayClient.swift:298, 304, 322, 328, 310, 316`**

Several call sites use memberwise initializers that cannot compile as written — Swift's memberwise init requires *all* stored properties, and these structs declare optionals without defaults:

```swift
// SessionListParams declares 4 properties (lines 45-50), only 1 supplied:
let params = SessionListParams(profile: profile)
```
Verified against the compiler:
```
error: missing arguments for parameters 'b', 'c' in call
note: 'init(a:b:c:)' declared here
```

Affected: `SessionListParams(profile:)` (:292), `SessionEventsSinceParams(profile:sequence:)` (:304 — also uses a `sequence:` label the type does not declare), `SessionResumeParams(sessionId:profile:)` (:310), `ModelOptionsParams(profile:)` (:316), `ApprovalRespondParams(sessionId:toolCallId:choice:)` (:322), `SessionCreateParams(profile:)` (:328). Additionally `approvalRespond` passes `toolCallId:` but `ApprovalRespondParams` (:156-162) has no such property, and `eventsSince(sequence:)` passes `sequence:` where the type declares `last_seen`.

These will not compile once R1 is fixed and the package actually builds the module.

**Fix** — add `= nil` defaults to every optional stored property in the `*Params` structs, and align the argument labels with the declared property names.

---

### R6. Security: unvalidated `ws://` URL and unverified ticket transport
**`Sources/HermesCoreWebSocket/web_socket.swift:25-29`**, **`Sources/Gateway/GatewayClient.swift:119-132`**

```swift
guard let url = URL(string: ticket.wsUrl) else { throw .invalidURL }
let task = session.webSocketTask(with: url)
```

There is no scheme check. `URL(string:)` accepts `ws://` (cleartext) as readily as `wss://`. A gateway that hands back a `ws://` URL — or a MITM that rewrites the handshake — causes the entire session, including `prompt.submit` text and `approval.respond` decisions, to travel unencrypted. The `WebSocketTicket` doc comment (`WebSocketTicket.swift:4-6`) states tickets are single-use and minted by an authenticated HTTP session, but nothing enforces single-use or expiry, and `GatewayClient.ticketProvider` (line 115) is declared and **never called** — so the ticket is never attached to the handshake at all.

**Fix**
- Reject any scheme other than `wss` (allow `ws` only behind an explicit `#if DEBUG` escape hatch).
- Enforce TLS: `URLSessionDelegate` `didReceive challenge` → cancel on non-`.serverTrust` challenge.
- Actually invoke `ticketProvider` during `connect()` and attach the token as an `Authorization` header or `Sec-WebSocket-Protocol` value.

---

### R7. Security: prompt text and approval decisions logged / sent without redaction
**`Sources/Gateway/GatewayClient.swift:198`**

```swift
Self.logger.error("unparseable frame: \(text.prefix(200))")
```

An unparseable inbound frame is logged verbatim to the unified log (OSLog, `subsystem: com.nousresearch.hermes.mobile`). Gateway `event` frames carry full conversation content — user prompts, assistant output, tool arguments. Any decode failure (a new server field, a schema drift, one malformed byte) dumps up to 200 characters of that content into `log stream` / sysdiagnose, where it persists and is readable by any process with log access and by anyone collecting device logs.

Severity depends on the data: benign for a `ping` echo, a real disclosure for a chat transcript.

**Fix** — log frame metadata only (method name, byte count, generation), never payload bytes. Same applies to `dropSocket(reason:)` at :547, which embeds `error.localizedDescription` into log output.

---

### R8. `nonisolated(unsafe)` on a `@MainActor` property has no effect
**`Sources/Gateway/GatewayConnection.swift:8-9`**

```swift
@Observable @MainActor
final class GatewayConnection: Sendable {
  private nonisolated(unsafe) var task: URLSessionWebSocketTask?
  private nonisolated(unsafe) var nextId = 1
```

The compiler confirms this attribute is inert here:
```
warning: 'nonisolated(unsafe)' has no effect on property 'task', consider using 'nonisolated'
```

The author appears to intend to opt these mutable properties out of `@MainActor` isolation to allow cross-thread socket access. The attribute silently does nothing, so the properties remain `@MainActor`-isolated. Any future call site that touches `task` off the main actor will fail to compile in Swift 6 mode — which is the correct outcome, but the annotation misrepresents the current safety guarantees.

**Fix** — drop the attribute and keep the state main-actor-isolated (it is only mutated from `connect`/`disconnect`, which are main-actor methods). If genuine off-main access is needed, use a `Mutex`/`OSAllocatedUnfairLock` box rather than a misleading annotation.

---

## 🟠 AMBER — real defects

### A1. Two tautological guards that never filter anything
**`Sources/Gateway/GatewayClient.swift:612`** and **`:628`**

```swift
guard socketGeneration == socketGeneration else { return }
```

This compares a value to itself. It is always `true`, so the guard is dead code. It appears to be intended as a stale-socket check of the form `guard gen == socketGeneration else { return }` — but `didOpenWithProtocol` / `didCloseWith` capture no `gen`, so there is nothing to compare against.

The consequence is a real race. The delegate methods receive a `webSocketTask` parameter, which is the correct discriminator:

```swift
nonisolated public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocolName: String?) {
    Task { @MainActor in
        guard socketGeneration == socketGeneration else { return }   // never fires
```

Scenario: `connect()` at t=0 creates generation 1. That socket is slow; the connect timeout or the caller fires `disconnect()` and `connect()` again, creating generation 2. Generation 1's `didOpenWithProtocol` then arrives on the delegate queue. Because the guard is a no-op, it sets `state = .open`, stamps `openedAt`, starts a second heartbeat task (orphaning the first — `startHeartbeat` does `heartbeatTask?.cancel()` first, so the first is cancelled, but only if it was already assigned), and triggers `fetchReplay()` against the *wrong* generation. The `4401`/`4403` auth close-code branch has the identical problem, so a stale generation-1 close event will mark a healthy generation-2 connection as `.error`.

**Fix** — compare identity against the task the callback carries:
```swift
nonisolated public func urlSession(_: URLSession, webSocketTask task: URLSessionWebSocketTask, didOpenWithProtocol protocolName: String?) {
    Task { @MainActor in
        guard task === self.webSocketTask else { return }
        ...
```

---

### A2. `URLSessionWebSocketTask.state` has no `.open` case — receive loop never runs
**`Sources/Gateway/GatewayClient.swift:167`**

```swift
while gen == self.socketGeneration, case .open = task.state {
```

`URLSessionWebSocketTask.state` is inherited from `URLSessionTask` and its cases are `.running`, `.suspended`, `.canceling`, `.completed`. There is no `.open`. Verified directly against the SDK:

```
error: type 'URLSessionTask.State' has no member 'open'
```

So once R1 is fixed and this file compiles, this `while` condition never matches and the receive loop body never executes — no inbound frame is ever dispatched. The entire client is write-only.

**Fix** — drive the loop off `receive()` throwing, not off task state:
```swift
while gen == self.socketGeneration {
    do { let msg = try await task.receive(); ... } catch { ...; break }
}
```

---

### A3. Handler cancellation silently fails — closures are not reference-identical
**`Sources/Gateway/GatewayClient.swift:396`**, **`:404`**

```swift
self?.eventHandlers[eventType]?.removeAll { $0 as AnyObject === handler as AnyObject }
```

`as AnyObject` on a closure value performs a bridge **boxing** allocation, so each cast produces a *new* boxed object. Two casts of the same closure are never `===`. Verified:

```
after remove count: 1     // expected 0
```

`HandlerToken.cancel()` therefore never removes anything. Every `on(...)` / `onAny(...)` registration leaks its handler for the lifetime of the client. Scenario: a SwiftUI view registers a handler in `.task {}`, cancels it in `.onDisappear`; the token call is a no-op and the handler keeps firing, mutating state for a view that no longer exists.

**Fix** — return a cancellable token rather than matching closures by identity. Either store an explicit id:
```swift
private var handlerSeq: UInt64 = 0
public func on(_ eventType: String, handler: @escaping (JSONValue) -> Void) -> HandlerToken {
    handlerSeq += 1
    let id = handlerSeq
    eventHandlers[eventType, default: [:]][id] = handler
    return HandlerToken { [weak self] in self?.eventHandlers[eventType]?[id] = nil }
}
```
(change `[String: [(JSONValue) -> Void]]` to `[String: [UInt64: (JSONValue) -> Void]]`), or use a class box as the identity token.

---

### A4. Replay-hold gate parks events for the wrong sessions
**`Sources/Gateway/GatewayClient.swift:436-445`**

```swift
if let _ = replayHold {
    if case .object(let dict) = params {
        if case .string(let sid) = dict["session_id"] ?? .null {
            if replayHold?[sid] != nil {
                replayHold?[sid]?.append(params)
                return
            }
        }
    }
}
```

The outer gate tests `replayHold != nil`, which is global; the inner gate tests membership per session. That part is correct. The bug is that `replayHold` is only ever created in `fetchReplay()` (line 469), and `fetchReplay()` returns early unless `lastSeenSeq` is non-empty (line 462). On a **cold start with no prior watermark** — the first connection of a fresh app launch — `lastSeenSeq` is empty, so no hold is installed and no replay is requested. Any events the server emitted between session-create and socket-open are lost permanently, with no truncated/epoch signal to reveal the gap.

This is the lossless-replay guarantee failing exactly when the client is least able to detect it.

**Fix** — on cold start, request replay from `last_seen = 0` for the sessions you are about to subscribe to, or have the server send `gateway.ready` with the head `seq` so the client can detect the gap it missed.

---

### A5. Reconnect backoff is fully implemented but never called
**`Sources/Gateway/ReconnectBackoff.swift`** (whole file), **`Sources/Gateway/GatewayClient.swift:557-560`**

`ReconnectBackoff` is complete and correct in isolation — full-jitter exponential, capped, with the `isStableOpen` guard that the doc comment correctly identifies as the fix for a redial storm (#83134). But `GatewayClient` exposes it as `public var reconnectBackoff` (line 113) and **never invokes `delayMs(attempt:)` anywhere**. There is no attempt counter and no reconnect loop.

And the one place that looks like it would reset it is an empty block:
```swift
if wasOpen && ReconnectBackoff.isStableOpen(openedAt: openedAt) {
    // Stable connection was live long enough — reset backoff
    // The caller (reconnect loop) will handle re-dial
}
```
The condition is evaluated, both side effects are commented as the caller's job, and nothing happens. `ReconnectBackoff.isStableOpen` is called here and nowhere else.

The file header at `GatewayClient.swift:64-66` documents "lossless reconnect replay via `session.events.since`" and line 8-11 claims ownership of "the reconnect schedule (calling `connect` again on `.closed`/`.error`)" — but no caller of that contract exists in the codebase. `state` transitions to `.closed` / `.error` and stays there.

**Fix** — implement the reconnect loop that consumes `reconnectBackoff.delayMs(attempt:)`, maintaining an `attempt` counter that resets on `isStableOpen`. Until then, either delete the dead `if` block or mark the header comment as aspirational so the next reader does not assume the behaviour exists.

---

### A6. `PendingCall.timer` is dead — timeout lives in an untracked `Task`
**`Sources/Gateway/GatewayClient.swift:24`**, **:229**, **:307-315**, **:573**

`PendingCall` declares `var timer: Task<Void, Never>?` and three sites cancel it (lines 229, 573, and `:306` guard). It is never assigned. The actual timeout is `call.task`, set at line 307.

Consequence: the timeout `Task` is not reachable from the pending-call bookkeeping in the way the type implies, and `call.timer?.cancel()` is a no-op in all three cancel paths. The timeout does still fire correctly on its own (it re-looks-up `pending` by id), but `handleResponse` (line 228-230) cancels `call.task` — so the working field is the one that is unnamed, and the named one is dead. This is a correctness-neutral but high-confusion defect: anyone reading `rejectAllPending` sees two cancels and cannot tell which is load-bearing.

**Fix** — delete the unused `timer` property and its three `?.cancel()` calls, leaving `task`.

---

### A7. `openedAt` is never reset, so `isStableOpen` compares against a stale origin
**`Sources/Gateway/GatewayClient.swift:88`**, **`:613`**, **`:557`**

`openedAt` is assigned in `didOpenWithProtocol` (line 613) but never cleared in `dropSocket` (546-562) or `disconnect` (150-159). After a socket drops and a new one opens, it is re-stamped — so the window itself is fine — but between the drop and the next open, `openedAt` still holds the previous connection's timestamp. `isStableOpen(openedAt:)` at line 557 is evaluated *inside* `dropSocket`, after the socket is gone, where it correctly measures the connection that just died. That particular call site is right.

The gap is that A5's empty block means the measurement is discarded, so the whole mechanism is inert. Fixing A5 requires also clearing `openedAt = nil` in `dropSocket` so a subsequent `isStableOpen(nil)` correctly reports "not stable" rather than inheriting a previous session's uptime.

**Fix** — covered by A5; add `openedAt = nil` to `dropSocket`.

---

### A8. `transcriptStore` is created lazily but the `gateway` reference is `weak`
**`Sources/HermesMobileApp.swift:20-21`**, **`Sources/Store/TranscriptStore.swift:7`**

```swift
let gateway = GatewayConnection()
lazy var transcriptStore = TranscriptStore(gateway: gateway)

private weak var gateway: GatewayConnection?
```

`gateway` is held strongly by `AppDelegate` for the process lifetime, so the weak reference does not currently nil out. But the reference is also **never read**: `apply(notification:)` (TranscriptStore.swift:16-18) is a `// TODO` stub that does not touch `self.gateway`, and nothing else in the file uses the property.

The net effect is that `TranscriptStore` is wired to nothing. `RootView` renders hardcoded placeholder text (`ChatView.swift:7` "Transcript goes here", `SidebarView.swift:7-11`), `ComposerView`'s Send button is a `// TODO` (`ComposerView.swift:11`), and `GatewayConnection.connect(to:with:)` is a `// TODO` that never opens a socket (`GatewayConnection.swift:13-15`).

This is a scaffold, and the file headers say so. Flagging it because the *wiring* looks complete — `RootView` receives both objects via `.environment` (`HermesMobileApp.swift:13-14`) and reads as if data flows — while the entire data path is absent. No chat functionality exists yet.

**Fix** — either implement `GatewayConnection.connect` and `TranscriptStore.apply`, or reduce the app to a single placeholder view so the environment injection does not imply a working pipeline.

---

### A9. `AnyCodable.encode` silently corrupts nested arrays
**`Sources/HermesCoreWebSocket/web_socket.swift:127-133`**

```swift
} else if let arr = self.value as? [[Any]] {
    var flattened: [Any] = []
    for inner in arr { flattened.append(contentsOf: inner) }
    try container.encode(flattened)
}
```

A JSON array-of-arrays such as `[[1,2],[3,4]]` is re-encoded as `[1,2,3,4]`. Nested structure is destroyed, not preserved. Anything round-tripped through this type — notification payloads with nested lists, e.g. a tool-call `content` array containing arrays — comes back structurally wrong.

The branch order makes this worse: `as? NSNumber` at line 123 matches before `as? Bool` at line 125, so booleans encode as `1`/`0` rather than `true`/`false`. On the decode side, `decodedJSON()` (:140-149) tries `String` first, then `NSNumber`, then `Bool` — `Bool` is unreachable for any value `NSNumber` accepts, and a JSON `true` arrives as `NSNumber`.

**Fix** — remove the `[[Any]]` branch entirely (it is the corruption), and reorder the encode checks so `Bool` precedes `NSNumber`.

---

### A10. `connect()`'s timeout `Task` is never cancelled and can clobber a newer connection
**`Sources/Gateway/GatewayClient.swift:137-145`**

```swift
Task {
    let timeout = UInt64(connectTimeoutMs) * 1_000_000
    try? await Task.sleep(nanoseconds: timeout)
    if gen == socketGeneration && state == .connecting {
        task.cancel(with: .goingAway, reason: nil)
        setState(.error)
    }
}
```

The task is fire-and-forget; it is not stored on `self`, so `disconnect()` (150) and `dropSocket` (546) cannot cancel it. The `gen == socketGeneration` check does correctly prevent it from cancelling a *newer* socket, and `state == .connecting` prevents it from firing after a successful open — so the guard is doing real work.

The remaining issue is a leak: every `connect()` call spawns a Task that lives for the full `connectTimeoutMs` (15s default) even on instant success. Repeated reconnect cycling accumulates sleeping Tasks, each holding a strong reference to `self` (via `self.connectTimeoutMs` at line 141 and `self` at 143) and preventing deallocation.

**Fix** — store the task (e.g. `private var connectTimeoutTask: Task<Void, Never>?`) and cancel it in both `didOpenWithProtocol` and `disconnect()`.

---

## 🟡 YELLOW — latent risk, dead code, incomplete

### Y1. `outstandingPings` is populated but never used for timeout detection
**`Sources/Gateway/GatewayClient.swift:97`**, **:376**, **:382**

The set is cleared (349), inserted to (376), and removed on success (382). Nothing ever reads it. The comment at line 366 says "Check deadline" but the check at 367-372 is purely `Date().timeIntervalSince(lastLivenessAt)` — inbound-traffic liveness, per the header comment "heartbeatLiveness: 'any-inbound'" (line 202).

The set's evident intent — detect a ping that was sent but never answered — is unimplemented. As written, `sendHeartbeat` relies on `requestRaw`'s own timeout (line 381) to catch an unanswered ping, and calls `dropSocket` in the `catch` (385). That path works, so the set is redundant rather than load-bearing.

**Fix** — delete the set, or implement the unanswered-ping check the name implies.

---

### Y2. `replayed` parameter is accepted and ignored
**`Sources/Gateway/GatewayClient.swift:413`**, **:521**, **:540**

```swift
private func dispatchEvent(_ params: JSONValue, replayed: Bool) {
```

`replayed` is never read in the method body. It is passed `true` at 521 and 523 for replayed frames, `false` at 214 and 540 for live ones — then discarded. Meanwhile `ServerRequest.replayed` (line 46) is hardcoded `false` at line 258 and never propagated.

Meanwhile the actual replay signal reaches handlers by a different route: `fetchSessionReplay` injects `dict["replayed"] = .bool(true)` into the payload (line 520) before dispatching. So replay *is* distinguishable by consumers — via the payload, not the parameter. The parameter is dead weight that suggests an intent that was implemented elsewhere.

**Fix** — either drop the parameter, or use it (e.g. skip `lastSeenSeq` bookkeeping for replayed frames, which is currently updated identically for both).

---

### Y3. `dispatchEvent` advances `lastSeenSeq` before the replay-hold check
**`Sources/Gateway/GatewayClient.swift:427-433`**

```swift
if case .integer(let seq) = dict["seq"] ?? .null {
    if case .string(let sid) = dict["session_id"] ?? .null {
        lastSeenSeq[sid] = max(lastSeenSeq[sid] ?? 0, seq)
    }
}
```

This block runs before the replay-hold gate (line 436). During replay, a live frame parked in the hold still advances the watermark. Combined with A4, the watermark can advance past events that were never delivered to handlers.

`max` is the correct aggregation for a monotonic seq, and parking-then-flushing means the frame *is* eventually dispatched (line 540) — so ordering is preserved. The risk is narrow: it requires a live event to arrive for a session mid-replay, which is the normal case. Flagging as YELLOW because the correctness depends on `flushReplayHold` always running, and `flushReplayHold` returns early if `gen != replayGeneration` (line 535) — a superseded replay leaves the parked frames undelivered.

**Fix** — move the watermark update after the hold gate, or ensure superseded replays still flush their parked frames before returning.

---

### Y4. `ReplayGeneration` supersession drops parked events on the floor
**`Sources/Gateway/GatewayClient.swift:534-542`**

```swift
private func flushReplayHold(sid: String, generation gen: Int) {
    guard gen == replayGeneration else { return }      // superseded: parked frames dropped
    guard let parked = replayHold?.removeValue(forKey: sid) else { return }
```

If a second `fetchReplay()` starts (line 464, `++replayGeneration`) while a first is still in flight, the first's `flushReplayHold` returns at line 535 and its parked live frames are never dispatched. `fetchReplay()` at 469 also *replaces* `replayHold` wholesale, discarding whatever the in-flight replay had parked.

Scenario: reconnect twice in quick succession with a session actively streaming. Events arriving during the first replay window are dropped entirely — they appear in neither the replay fetch (which refetched from an older watermark) nor the live dispatch.

**Fix** — when replacing `replayHold` in `fetchReplay`, flush the previous hold's contents rather than discarding it, and let `flushReplayHold` dispatch even when superseded (the replay ordering concern is handled by the new replay's own fetch).

---

### Y5. `Scripts` is declared as a SwiftPM target containing only Python
**`Package.swift:19`**

```swift
.target(name: "Scripts", path: "Scripts"),
```

`Scripts/` contains `gen_client.py` and `gen_models.py` — no Swift. SwiftPM warns:
```
warning: Source files for target Scripts should be located under 'Sources/Scripts', ...
```
The target contributes nothing to the build and is not referenced by any other target. `Tools/generate_swift_models.py` is not wired in at all.

**Fix** — remove the target; invoke the generators directly (`python3 Scripts/gen_models.py`).

---

### Y6. `GeneratedModels` declares a resource glob that matches nothing
**`Package.swift:18`**

```swift
.target(name: "GeneratedModels", path: "Sources/Generated", resources: [.process("*.json")]),
```

`Sources/Generated/` contains five `.swift` files and no `.json`. Reproduced the warning with an equivalent manifest:
```
warning: Invalid Resource '*.json': File not found.
```

The generators read `openrpc.json` from the repo root; they do not emit it into the target directory. The resource declaration is vestigial.

**Fix** — drop `resources:` from this target.

---

### Y7. `Package.swift` declares iOS-only types in a cross-platform package
**`Sources/HermesMobileApp.swift:6-8`**, **`Package.swift:6`**

```swift
@main
struct HermesMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
```

`UIApplicationDelegateAdaptor` and `UIApplicationDelegate` are UIKit types, unavailable on macOS. The package declares `platforms: [.iOS(.v17), .macOS(.v14)]` and ships `HermesMobile` as a library product, so a macOS consumer resolves the target and hits `@main` + UIKit.

Additionally, `@main` in a library product is a packaging smell: an app entry point inside a library target means every consumer inherits a competing `@main`. This is the standard shape for a SwiftPM-hosted iOS app, but it should not ship in a library product alongside `HermesCoreWebSocket`.

**Fix** — guard the app shell with `#if canImport(UIKit)` / `#if os(iOS)`, or move `HermesMobileApp.swift` out of the library target into a proper app target.

---

### Y8. `GatewayConnection` declares `Sendable` while holding mutable non-isolated state
**`Sources/Gateway/GatewayConnection.swift:6-9`**

```swift
@Observable @MainActor
final class GatewayConnection: Sendable {
  private nonisolated(unsafe) var task: URLSessionWebSocketTask?
  private nonisolated(unsafe) var nextId = 1
```

`@MainActor` already implies `Sendable`, so the explicit conformance is redundant rather than wrong. But combined with R8, the two `nonisolated(unsafe)` properties are the only mutable state, they carry no compiler-enforced protection (the attribute is inert), and nothing reads or writes them outside the main actor anyway.

`nextId` is declared and never used — `GatewayClient.requestRaw` maintains its own `nextId` (line 91) and generates request ids there.

**Fix** — remove the unused `nextId`; drop the inert annotations per R8.

---

### Y9. `JSONRPCFrame.JSONID` accepts a JSON string id that looks like an integer
**`Sources/Gateway/JSONRPCFrame.swift:24-29`**

```swift
if let i = try? c.decode(Int64.self) { self = .number(i); return }
if let s = try? c.decode(String.self) { self = .string(s); return }
```

A server id of `"42"` decodes to `.string("42")`, while a client id of `42` decodes to `.number(42)`. `pending` is keyed by `JSONID` (line 92), so the two never match and `handleResponse` returns at line 228 without resolving — the request hangs until its timeout.

`handleServerRequest` (242-246) sidesteps this by stringifying both cases for `idStr`, which is why server→client requests correlate fine. Client→server correlation has no such normalisation.

Scenario: a gateway that echoes string ids while this client sends integer ids — a plausible mismatch given the spec permits both, and the backend reference implementation may differ.

**Fix** — normalise the lookup key, e.g. key `pending` by a `String(id)` description, or try both forms on response.

---

### Y10. Request timeout is stored but the send-failure path can double-resume the continuation
**`Sources/Gateway/GatewayClient.swift:298-341`**

Inside `withCheckedThrowingContinuation`, three paths can reject: the `catch` at 338 (`pending.removeValue(...)?.reject`), the send-completion error at 331-337, and the timeout task at 311-313. All three `removeValue` from `pending` before rejecting, so only one wins and the others no-op — that part is correct.

But the timeout task is created at line 307 *before* `pending[jsonId] = call` at line 317. With `timeoutMs` of 0 or 1ms, the task can run and `removeValue` a `pending` entry that does not yet exist, then fall through — leaving the continuation unresumed until a later frame arrives. The window is narrow (the `Task` cannot execute before the enclosing closure returns on the same actor), but `withCheckedThrowingContinuation` will trap on a leaked continuation if no frame ever arrives.

**Fix** — insert into `pending` before creating the timeout task.

---

### Y11. `HermesGatewayClient` is a `struct` with `private var` mutated from `async` methods
**`Sources/GatewayClient/HermesGatewayClient.swift:261-288`**

```swift
public struct HermesGatewayClient {
  private var ticket: WebSocketTicket?
  public func connect() async throws {
    ...
    self.ticket = try await mintTicket()
```

`connect()` mutates `self.ticket` but is not marked `mutating`. A `struct` method that mutates a stored property must be `mutating`, and it is called on a `let`-bound value from a consuming context. This will not compile.

Additionally, `ticket` is captured at line 287 (`ticket!`) *after* an `await` — a read of mutable state across a suspension point in a value type, which also requires exclusivity the compiler will reject under strict concurrency.

**Fix** — make this a `final class` (it owns connection lifecycle), or make `connect()` `mutating` and call it on a `var`.

---

## 🟢 GREEN — checked and correct

Recorded because each is superficially suspicious and was specifically verified.

| Item | Location | Why it is fine |
|------|----------|----------------|
| `ReconnectBackoff.delayMs` shift overflow | `ReconnectBackoff.swift:44-45` | `attempt` clamped to `max(0, ...)` and `min(..., 32)` before `1 << exp`. At 32 the shift is `Int64`, `baseDelayMs * (1<<32)` = ~1.3e12, well inside `Int64`, then `min`'d with `capMs`. No overflow. |
| `Int.random(in: 0..<max(1, ceiling))` | `ReconnectBackoff.swift:47` | `max(1, ...)` guards the empty-range precondition, so a zero or negative `baseDelayMs` cannot trap. Returns `[0, ceiling)`, matching the documented "lies in [0, ceiling)". |
| `sendRawFrame` error swallowing | `GatewayClient.swift:582-586` | `try?` on `JSONSerialization` plus a `guard let` on UTF-8, returning silently. These are all-optional-valued inputs (`JSONValue` and `Int`/`String` from `handleServerRequest`), so serialisation cannot fail. The silent return is acceptable for a best-effort reply path. |
| `jsonValueToAny` conversion | `GatewayClient.swift:590-600` | Exhaustive switch over all seven `JSONValue` cases with no `@unknown default` needed — `JSONValue` is a frozen enum in the same module family. `NSNull()` for `.null` is what `JSONSerialization` requires. |
| `JSONValue` decode ordering | `JSONValue.swift:19-29` | Order is `nil → Bool → Int64 → Double → String → Array → Object`. Checking `Bool` before `Int64` matters (JSON `true` would otherwise fail as a number, but Swift's `JSONDecoder` is strict here, so both orders are safe) and `Int64` before `Double` preserves integer fidelity. Object last, since it is the most permissive. |
| `handleServerRequest` id stringification | `GatewayClient.swift:242-246` | Both `JSONID` cases are handled in an exhaustive `switch`, so `idStr` is always bound. This is the correct pattern that `pending` correlation (Y9) lacks. |
| `@unknown default` on message switch | `GatewayClient.swift:177` | Correct use — `URLSessionWebSocketTask.Message` is a non-frozen enum over an SDK module, so future cases must not break the build. |
| `unhandled server→client request` → `-32601` | `GatewayClient.swift:265-267` | Good defensive behaviour. Replying with `JSONRPCErrorCode.methodNotFound` rather than staying silent prevents the backend from holding its own deadline open. |

---

## Cross-cutting: concurrency model

`GatewayClient` is `@MainActor` and `final`, which is the right shape for owning a socket plus a `pending` dictionary. Verified against the Swift 6 language mode:

- The `respond`/`fail` closures built in `handleServerRequest` (lines 249-255) are `@Sendable` and call `self?.sendRawFrame(...)` from a nonisolated context. Under `-swift-version 6` this is a hard error:
  ```
  error: call to main actor-isolated instance method 'sendRawFrame' in a
         synchronous nonisolated context [#ActorIsolatedCall]
  ```
  The package declares `swift-tools-version:5.10`, so it compiles today as a warning-class issue, but it is latent breakage for any Swift 6 migration. Wrap the bodies in `Task { @MainActor in ... }`, as `didOpenWithProtocol` already does correctly (line 611).
- `PendingCall` is `@unchecked Sendable` (line 20) with mutable `timer`/`task`. The unchecked annotation is justified only if all access stays on the main actor — which it does today, since the timeout `Task` inherits actor isolation from its enclosing `@MainActor` context. Adding a `nonisolated` accessor would invalidate the justification.
- `GatewayConnection`'s `nonisolated(unsafe)` properties (R8) currently produce compiler warnings, not errors, because the attribute is inert. They are not actually racing today.

## Cross-cutting: repo hygiene

Not a code defect, but it blocks review (see `git status` noise) and will cause merge conflicts.

Tracked build/tooling artifacts that should be gitignored:

| Path | Contents | Risk |
|------|----------|------|
| `.build/` | SwiftPM index DBs (`saved/data.mdb`, `lock.mdb`), `workspace-state.json`, `.lock` | Machine-specific binaries; `.lock` churns on every build, producing a permanent dirty tree |
| `.agentbridge/` | `conversation.db{,-shm,-wal}`, `memory/knowledge.sqlite3`, `memory/lucene-index/segments_1`, `write.lock`, `.current-session-id` | Local session state and a SQLite WAL; will conflict on every merge |
| `.idea/` | Per-developer IDE config | Not portable; conflicts on every merge |
| `.DS_Store` | Finder metadata | Untracked noise |

```
git rm -r --cached .build .agentbridge .idea
printf '.build/\n.agentbridge/\n.idea/\n.DS_Store\n' >> .gitignore
```

Also: `openrpc.json` and `gateway-contract.openrpc.json` are byte-identical (both 1,014,478 bytes). One is redundant — confirm which is authoritative and remove the duplicate, or make one a symlink.

---

## Summary

| Severity | Count | IDs |
|:--------:|:-----:|:-----|
| 🔴 RED | 8 | R1–R8 |
| 🟠 AMBER | 10 | A1–A10 |
| 🟡 YELLOW | 11 | Y1–Y11 |
| 🟢 GREEN | 8 | verified-correct |

**Blocking sequence:** R1 must be fixed first — until `swift build` succeeds, none of R5, Y5, Y6, Y10 or Y11 are verifiable, because the compiler never reaches those files. After R1, expect the compiler to surface R5 and Y11 directly.

**Highest-value non-build fixes:** A2 (receive loop never runs — client cannot receive at all), A1 (tautological guard allows stale sockets to clobber a healthy connection), A3 (handler cancellation silently no-ops), A4 (cold-start event loss breaks the lossless-replay guarantee the header advertises).

**Security posture:** R6 (no `wss` enforcement, `ticketProvider` never called) and R7 (conversation content written to the unified log on decode failure) are the two to address first. Neither is currently exploitable in production because R1/R4 mean the code cannot run — but both must be fixed before it can.
