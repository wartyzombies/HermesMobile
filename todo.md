# HermesMobile — Development Tasks

Roadmap and task tracker for the native iOS Hermes gateway client.
Severity legend (traffic-light system, matching [`fixes.md`](fixes.md)):

| Light | Meaning |
|:-----:|---|
| 🔴 **RED** | Crashes, build failure, data corruption, or security vulnerability — must fix before shipping |
| 🟠 **AMBER** | Real defect under specific conditions — fix soon |
| 🟡 **YELLOW** | Latent risk, dead code, or incomplete — no immediate failure |
| 🟢 **GREEN** | Verified-correct (noted because suspicious at a glance) |

---

## Project overview

Swift Package for a native iOS Hermes gateway client, mirroring the Hermes
Desktop three-party architecture (Shell / Renderer / Backend) over the
`tui_gateway` JSON-RPC 2.0 protocol.

## Current status

- ✅ **Package structure** — five SwiftPM targets, no overlapping sources
- ✅ **Build** — `swift build` / `swift build --build-tests` pass with zero warnings (verified 2026-10-16)
- ✅ **Tests** — `swift test` 6/6 pass
- ✅ **Xcode build** — iOS Simulator and macOS package schemes `BUILD SUCCEEDED`
- ✅ **Gateway transport** — `GatewayClient`: JSON-RPC correlation, timeouts, heartbeat, reconnect-replay
- ✅ **Typed API** — `HermesClient`: one method per `tui_gateway` RPC
- ✅ **Generated models** — full OpenRPC coverage (`Sources/Generated/`)
- ⚠️ **WebSocket transport** — `HermesCoreWebSocket` compiles but is **unused**; `GatewayClient` drives `URLSessionWebSocketTask` directly
- ⚠️ **Review** — Round 1 findings addressed; Round 2 (`fixes.md`) fixed 9 build-breakers (N1–N9) and left 11 open items (F1–F11)
- 🟡 **UI** — placeholder SwiftUI views wired to a working `HermesClient`; `TranscriptStore` is **not yet subscribed** to the transport (F3)
- 🟡 **Auth** — ticket plumbing is a placeholder; OAuth (PKCE) / basic-auth managers not yet implemented (F4), and the `Authorization` header currently receives the ws URL

## Milestones

### M1 — Transport core ✅
- [x] `GatewayClient`: socket lifecycle, request-id correlation, per-call timeouts
- [x] `gateway.ping` heartbeat with any-inbound liveness
- [x] Event fan-out with exact-cancellation handler tokens
- [x] Lossless reconnect replay via `session.events.since`
- [x] `wss://`-only enforcement + single-use ticket attach
- [x] `HermesCoreWebSocket` standalone transport
- [x] `GeneratedModels` from `gateway-contract.openrpc.json`

### M2 — Typed API + review fixes ✅
- [x] `HermesClient` typed facade (session, prompt, approval, model, config, slash)
- [x] Round 1 fixes applied (see `fixes.md`)
- [x] Round 2 build repair — N1–N9 (`fixes.md`); package builds and tests cleanly
- [x] Unit tests for correlation key, `JSONValue` round-trip, backoff, frame decode
- [ ] Round 2 open items F1–F11 (`fixes.md`)

### M3 — Auth (in progress)
- [ ] OAuth 2.0 + PKCE via `ASWebAuthenticationSession` (Nous Portal)
- [ ] Basic auth for trusted LAN/VPN gateways
- [ ] Keychain-backed credential storage
- [ ] Ticket minting per dial (F4 — `WebSocketTicket` currently carries only `wsUrl`; the `Authorization` header gets the URL)
- [ ] TLS challenge handler rejecting non-`.serverTrust` challenges (F6)

### M4 — UI (in progress)
- [ ] Subscribe `TranscriptStore` to `GatewayClient` events (F3 — currently unwired)
- [ ] Session list sidebar (from `session.list`)
- [ ] Transcript rendering (from `message.delta` / `message.complete`)
- [ ] Tool-call cards (from `tool.start` / `tool.complete`)
- [ ] Approval dialogs (from `approval.received` → `approval.respond`); register a `ServerRequestHandler` (F3)
- [ ] Model picker (from `model.options`)
- [ ] Composer send → `prompt.submit` (bind the active session id; currently `""`)

### M5 — Polish
- [ ] Dark mode / dynamic color
- [ ] iPad multitasking
- [ ] Accessibility (VoiceOver, Dynamic Type)
- [ ] File attachment

## Test environment

### macOS (full app + tests)

```bash
# prerequisites: Xcode 15+, Swift 5.10+
xcode-select --install
swift --version            # confirm Swift 5.10+

cd HermesMobile
swift build                # debug
swift build -c release     # release
swift test                 # unit tests
swift test --filter HermesMobileTests

# iOS Simulator (use a generic destination when no simulator runtime is installed):
xcodebuild -scheme HermesMobile -destination 'generic/platform=iOS Simulator' build
# macOS:
xcodebuild -scheme HermesMobile -destination 'generic/platform=macOS' build
```

### Linux (portable modules only)

The `HermesMobile` target imports SwiftUI/UIKit, so it builds only on Apple
platforms. On Linux, build the portable modules and run the non-UI tests:

```bash
# install Swift 5.10+ toolchain (https://www.swift.org/download/)
swift --version

cd HermesMobile
swift build --target GeneratedModels
swift build --target HermesCoreWebSocket
swift test --filter HermesMobileTests
```

> The full iOS app cannot be compiled on Linux. Use macOS/Xcode for anything
> that imports SwiftUI or UIKit.

### Regenerating models

```bash
python3 Scripts/gen_models.py     # reads gateway-contract.openrpc.json → Sources/Generated
```

`Scripts/gen_client.py` is deprecated and must not be run (it emits a
non-compiling `HermesGatewayClient.swift`). `Sources/HermesClient.swift` is the
real typed facade.

## Code standards

- **Naming** — camelCase for functions/variables, PascalCase for types.
- **Docs** — docstrings (`///`) on every public API.
- **Concurrency** — `async/await`; `@MainActor` for UI-bound types; `Sendable` annotations where required.
- **Generated code** — frozen; edit `Scripts/gen_models.py`, never the output.
- **Security** — no secrets in logs; `wss://` only in release; redact conversation content.

## Known limitations

- 🟡 Auth managers (OAuth PKCE, basic auth) are not yet implemented — the
  ticket provider hook exists but `GatewayConnection` puts `ticket.wsUrl` into
  the `Authorization` header (F4), and there is no ticket token type.
- 🟡 `TranscriptStore` is not subscribed to `GatewayClient` events, so the
  transcript never updates from the server (F3).
- 🟡 The 4401/4403 auth-close path leaks the socket/session and leaves pending
  calls to time out (F1).
- 🟡 Cold-start replay is skipped — `fetchReplay` returns early on an empty
  watermark (F5).
- 🟡 `ReconnectBackoff` is provided but caller-driven; the "stable open" signal
  is emitted twice and is not currently actionable (F2).
- 🟡 `HermesCoreWebSocket` compiles but is unused and duplicates the app
  transport (F9).
- 🟡 SwiftUI views are placeholders; the data path exists but is not fully
  rendered.
- 🟡 `JSONID.key` is type-tagged (`n:`/`s:`), so a server that echoes a string
  id for an integer request will not correlate — deliberate per JSON-RPC 2.0,
  documented at `fixes.md` Y9.

## License

MIT — see [`LICENSE.txt`](LICENSE.txt).
