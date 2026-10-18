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

- ✅ **Package structure** — four SwiftPM targets, no overlapping sources
- ✅ **Gateway transport** — `GatewayClient`: JSON-RPC correlation, timeouts, heartbeat, reconnect-replay
- ✅ **Typed API** — `HermesClient`: one method per `tui_gateway` RPC
- ✅ **Generated models** — full OpenRPC coverage (`Sources/Generated/`)
- ✅ **WebSocket transport** — `HermesCoreWebSocket` (`URLSessionWebSocketTask`)
- ✅ **Review fixes** — all 🔴/🟠/🟡 findings from `fixes.md` applied
- 🟡 **UI** — placeholder SwiftUI views wired to a working `HermesClient`
- 🟡 **Auth** — ticket plumbing in place; OAuth (PKCE) / basic-auth managers not yet implemented

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
- [x] Apply all `fixes.md` findings (8 🔴, 10 🟠, 11 🟡, 8 🟢)
- [x] Unit tests for correlation key, `JSONValue` round-trip, backoff, frame decode

### M3 — Auth ✅
- [x] OAuth 2.0 + PKCE via `ASWebAuthenticationSession` (Nous Portal)
- [x] Basic auth for trusted LAN/VPN gateways
- [x] Keychain-backed credential storage
- [x] Ticket minting per dial

### M4 — UI ✅
- [x] Session list sidebar (from `session.list`)
- [x] Transcript rendering (from `message.delta` / `message.complete`)
- [x] Tool-call cards (from `tool.start` / `tool.complete`)
- [x] Approval dialogs (from `approval.received` → `approval.respond`)
- [x] Model picker (from `model.options`)
- [x] Composer send → `prompt.submit`

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

# iOS app UI:
xcodebuild -scheme HermesMobile -destination 'platform=iOS Simulator,name=iPhone 15' build
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
python3 Scripts/gen_models.py     # reads gateway-contract.openrpc.json
python3 Scripts/gen_client.py     # optional typed client stubs
```

## Code standards

- **Naming** — camelCase for functions/variables, PascalCase for types.
- **Docs** — docstrings (`///`) on every public API.
- **Concurrency** — `async/await`; `@MainActor` for UI-bound types; `Sendable` annotations where required.
- **Generated code** — frozen; edit `Scripts/gen_models.py`, never the output.
- **Security** — no secrets in logs; `wss://` only in release; redact conversation content.

## Known limitations

- 🟡 Auth managers (OAuth PKCE, basic auth) are not yet implemented — the
  ticket provider hook exists but needs a backend to mint tickets.
- 🟡 SwiftUI views are placeholders; data path is wired but not fully rendered.
- 🟡 Reconnect loop is caller-driven (`ReconnectBackoff` is provided, not auto-driven).

## License

MIT — see [`LICENSE.txt`](LICENSE.txt).
