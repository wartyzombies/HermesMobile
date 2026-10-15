# HermesMobile

A native iOS client for the [`hermes serve`](https://hermes-agent.nousresearch.com/docs/user-guide/desktop) gateway, built as a Swift Package. It mirrors the Hermes Desktop three-party architecture — **Shell** (SwiftUI app) / **Renderer** (SwiftUI views) / **Backend** (the remote `hermes serve` process) — and speaks the `tui_gateway` JSON-RPC 2.0 protocol over a secure WebSocket.

> **Status:** scaffold. The transport, correlation, heartbeat, and reconnect-replay logic are implemented; the SwiftUI views are placeholders wired to a working `HermesClient`. See [`todo.md`](todo.md) for the full milestone plan.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  HermesMobile (iOS app / library)                            │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐   │
│  │ SwiftUI Shell│  │ HermesClient │  │  GatewayClient   │   │
│  │  (Views/)    │  │ (typed RPCs) │  │ (JSON-RPC, WS,   │   │
│  │              │──│              │──│  heartbeat,      │   │
│  │  AppDelegate │  │ session.…    │  │  replay)         │   │
│  │  RootView    │  │ prompt.…     │  └────────┬─────────┘   │
│  │  ChatView    │  │ approval.…   │           │              │
│  │  ComposerView│  └──────────────┘           │              │
│  │  SidebarView │        ▲                      ▼              │
│  └──────────────┘        │          event fan-out            │
│                  TranscriptStore ◄─────────────┘              │
└───────────────────────────────────┬──────────────────────────┘
                                    │  wss://…/api/ws?ticket=
                                    ▼
                       ┌───────────────────────────┐
                       │  hermes serve (gateway)   │
                       │  tui_gateway JSON-RPC 2.0 │
                       └───────────────────────────┘
```

### Target layout

| Target | Path | Role |
|---|---|---|
| `HermesMobile` | `Sources/` | App shell, SwiftUI views, `HermesClient`, `GatewayClient`, `TranscriptStore` |
| `HermesCoreWebSocket` | `Sources/HermesCoreWebSocket/` | Standalone `URLSessionWebSocketTask` transport |
| `GeneratedModels` | `Sources/Generated/` | Machine-generated wire models (from the OpenRPC contract) |
| `HermesMobileTests` | `Tests/` | Unit tests |

`Scripts/` holds the Python code generators and is **not** a SwiftPM target.

### How the pieces fit

- **`GatewayClient`** owns the socket, request-id correlation, per-call timeouts, the `gateway.ping` heartbeat, event fan-out, and lossless reconnect replay via `session.events.since`. It is `@MainActor`-isolated.
- **`HermesClient`** is the typed facade: one method per `tui_gateway` RPC, each decoding into the generated `Codable` struct.
- **`HermesCoreWebSocket`** is a thin, dependency-free WebSocket wrapper (optional; `GatewayClient` drives `URLSessionWebSocketTask` directly).
- **`GeneratedModels`** is produced from `gateway-contract.openrpc.json` — the authoritative protocol contract. Do not hand-edit.

---

## Requirements

- **Swift 5.10+** toolchain (`swift-tools-version:5.10`)
- **Xcode 15+** on macOS, or a Swift 5.10 toolchain on Linux for the portable modules
- **iOS 17 / macOS 14** deployment targets
- No external runtime dependencies — Foundation + SwiftUI only

---

## Build & test

### macOS (full app + tests)

```bash
cd HermesMobile
swift build             # debug build of all targets
swift build -c release  # release build
swift test              # run the unit-test suite
```

To build/run the iOS app UI, open the package in Xcode and select an iOS simulator, or use `xcodebuild`:

```bash
xcodebuild -scheme HermesMobile -destination 'platform=iOS Simulator,name=iPhone 15' build
```

### Linux (portable modules only — no SwiftUI/UIKit)

The `HermesMobile` target imports SwiftUI and UIKit, so it builds only on Apple platforms. On Linux you can build the portable modules:

```bash
swift build --target GeneratedModels
swift build --target HermesCoreWebSocket
swift test --filter HermesMobileTests   # tests that do not touch SwiftUI
```

> The full iOS app cannot be compiled on Linux; use macOS/Xcode for anything that imports SwiftUI or UIKit.

---

## Connecting to a gateway

1. **Authenticate** — OAuth (PKCE) via the Nous Portal for public gateways, or basic auth for trusted LAN/VPN gateways. Auth mints a **single-use WebSocket ticket**.
2. **Dial** — the ticket is attached to the handshake:
   `wss://<host>:9119/api/ws?ticket=<ticket>`
3. **Drive** — issue RPCs through `HermesClient`; listen for events with `GatewayClient.on(_:handler:)`.

```swift
let gateway = GatewayConnection()
gateway.connect(to: URL(string: "wss://gateway.example:9119")!,
                with: ticket)
let sessions = try await gateway.api.listSessions()
```

### Security model

- **TLS only.** `GatewayClient.connect` and `HermesCoreWebSocket.connect` reject any scheme other than `wss://` in release builds (`ws://` is allowed only in DEBUG).
- **No conversation content in logs.** On a decode failure the client logs the byte count, never the payload.
- **Single-use tickets.** A ticket is minted per dial and is rejected (close code `4401`) if reused or expired.

---

## Code generation

`Sources/Generated/` is committed so the package builds without Python. To regenerate after the contract changes:

```bash
python3 Scripts/gen_models.py    # writes Sources/Generated/*.swift
python3 Scripts/gen_client.py    # (optional) typed client stubs
```

The generators read `gateway-contract.openrpc.json` from the repo root. Treat that file as the source of truth and pin its version.

---

## Development conventions

- **Generated code is frozen** — edit `Scripts/gen_models.py`, not the output.
- **Open enums** for wire strings: `RawRepresentable` structs with typed constants plus raw passthrough, so unknown backend values decode without crashing.
- **`JSONValue`** for heterogeneous `anyOf`/`{}` shapes that Foundation can't synthesize.
- **Backward compatibility** — models tolerate missing/unknown fields; never remove a field from a generated struct.

---

## Review status (traffic-light severity)

Findings from the code review are tracked in [`fixes.md`](fixes.md) and applied as follows.

| Light | Meaning | Count | Status |
|:-----:|---|:-----:|:------:|
| 🔴 **RED** | Crashes, build failure, data corruption, or security vulnerability | 8 | ✅ fixed |
| 🟠 **AMBER** | Real defect under specific conditions | 10 | ✅ fixed |
| 🟡 **YELLOW** | Latent risk, dead code, or incomplete | 11 | ✅ fixed |
| 🟢 **GREEN** | Verified-correct (noted because suspicious at a glance) | 8 | ✅ confirmed |

### Highlights of what was fixed

- 🔴 **R1** — `swift build` failed on overlapping target sources; `Package.swift` now `exclude`s sibling-target directories and drops the Python-only `Scripts` target.
- 🔴 **R2/R4** — `fatalError` on the primary RPC path and a force-unwrap crash on non-OAuth connect; the dead `HermesGatewayClient` facade was removed in favour of the working `HermesClient`.
- 🔴 **R6** — unvalidated `ws://` URLs and a ticket provider that was never called; both the client and transport now enforce `wss://` and attach the ticket.
- 🔴 **R7** — conversation content was logged verbatim on decode failure; now logs byte count only.
- 🟠 **A2** — the receive loop keyed off `task.state == .open`, a case that doesn't exist on `URLSessionTask.State`, so the client was write-only; the loop now drives off `receive()`.
- 🟠 **A3** — event-handler cancellation compared boxed closures by identity (always unequal), so handlers leaked forever; handlers are now keyed by a numeric id.
- 🟠 **A9** — `AnyCodable.encode` flattened nested arrays (`[[1,2],[3,4]]` → `[1,2,3,4]`) and encoded booleans as `1`/`0`; both fixed.

Full details, including the exact code locations and reasoning, are in [`fixes.md`](fixes.md).

---

## License

See [`LICENSE.txt`](LICENSE.txt).
