# HermesMobile

A native iOS client for the [`hermes serve`](https://hermes-agent.nousresearch.com/docs/user-guide/desktop) gateway, built as a Swift Package. It mirrors the Hermes Desktop three-party architecture — **Shell** (SwiftUI app) / **Renderer** (SwiftUI views) / **Backend** (the remote `hermes serve` process) — and speaks the `tui_gateway` JSON-RPC 2.0 protocol over a secure WebSocket.

> **Status:** scaffold, but it **builds and tests cleanly** as of 2026-10-16 (`swift build`, `swift test` 6/6, and `xcodebuild` for the iOS Simulator and macOS schemes — all pass with zero warnings). The transport, correlation, heartbeat, and reconnect-replay logic are implemented; the SwiftUI views are placeholders wired to a working `HermesClient`. Auth is still a placeholder and the transcript store is not yet subscribed to the transport — see [`fixes.md`](fixes.md) Round 2 and [`todo.md`](todo.md) for the open items and the full milestone plan.

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
| `HermesMobile` | `Sources/` | App shell, SwiftUI views, `HermesClient`, `GatewayClient`, `GatewayConnection`, `TranscriptStore` |
| `HermesCoreWebSocket` | `Sources/HermesCoreWebSocket/` | Standalone `URLSessionWebSocketTask` transport (**not used by the app**; `GatewayClient` drives `URLSessionWebSocketTask` directly) |
| `GeneratedModels` | `Sources/Generated/` | Machine-generated wire models (from the OpenRPC contract) |
| `HermesLogger` | `Sources/HermesLogger/` | Portable `os.Logger` / `print` logging shim |
| `HermesMobileTests` | `Tests/` | Unit tests |

`Scripts/` holds the Python code generators and is **not** a SwiftPM target.

### How the pieces fit

- **`GatewayClient`** owns the socket, request-id correlation, per-call timeouts, the `ping` heartbeat, event fan-out, and lossless reconnect replay via `session.events.since`. It is `@MainActor`-isolated.
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

> **This machine only:** the Command Line Tools ship the macOS 27 SDK, whose
> SwiftUI `@State` macro needs a `SwiftUIMacros` plugin the toolchain does not
> provide. Pin the macOS 26.5 SDK (plain property-wrapper `@State`, no plugin):
>
> ```bash
> export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
> swift build && swift test
> ```
>
> See [`AGENTS.md`](AGENTS.md) for the details.

To build the package with Xcode (there is no `.xcodeproj` — it builds the Swift package scheme directly):

```bash
# iOS Simulator (use a generic destination when no simulator runtime is installed)
xcodebuild -scheme HermesMobile -destination 'generic/platform=iOS Simulator' build
# macOS
xcodebuild -scheme HermesMobile -destination 'generic/platform=macOS' build
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

> **Auth is currently a placeholder.** The `ticketProvider` hook exists and is
> called before each dial, but `GatewayConnection.connect(to:with:)` currently
> feeds `ticket.wsUrl` into the `Authorization` header — there is no ticket
> *token* yet, and `WebSocketTicket` carries only `wsUrl`. Implementing the
> OAuth-PKCE / basic-auth minting and the TLS challenge handler is tracked in
> [`todo.md`](todo.md) (M3) and [`fixes.md`](fixes.md) F4/F6.

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
python3 Scripts/gen_models.py    # writes Sources/Generated/*.swift (repo-relative OUT_DIR)
```

`Scripts/gen_client.py` is **deprecated** — it emits a non-compiling
`HermesGatewayClient.swift` (a duplicate `HermesCoreWebSocket` and a `fatalError`
on connect) and its output directory no longer exists. `Sources/HermesClient.swift`
is the real typed facade; do not run `gen_client.py`.
`Tools/generate_swift_models.py` is an unwired alternate generator.

The generators read `gateway-contract.openrpc.json` from the repo root. Treat
that file as the source of truth and pin its version. After regenerating, verify
the diff is limited to the intended change before committing.

---

## Development conventions

- **Generated code is frozen** — edit `Scripts/gen_models.py`, not the output.
- **Open enums** for wire strings: `RawRepresentable` structs with typed constants plus raw passthrough, so unknown backend values decode without crashing.
- **`JSONValue`** for heterogeneous `anyOf`/`{}` shapes that Foundation can't synthesize.
- **Backward compatibility** — models tolerate missing/unknown fields; never remove a field from a generated struct.

---

## Review status (traffic-light severity)

Findings from the code review are tracked in [`fixes.md`](fixes.md). There are
two rounds: the original review (commit `96a23f0`) and a **Round 2** review
(2026-10-16) that re-audited the tree after the build was finally made to pass.

### Round 2 (current, 2026-10-16)

Verified this round: `swift build` (0 warnings), `swift build --build-tests`,
`swift test` (6/6), and `xcodebuild` for the iOS Simulator and macOS schemes —
all pass.

| Light | Meaning | Count | Status |
|:-----:|---|:-----:|:------:|
| 🔴 **RED** | Build-breakers (N1–N9): corrupted literals, missing imports, `++`, bad enum defaults, `Encodable` on `Any` types, UI type errors | 9 | ✅ fixed |
| 🟠 **AMBER** | Auth-close leak (F1), duplicate `.closed` (F2), `TranscriptStore` unwired (F3), auth placeholder (F4) | 4 | ⬜ open |
| 🟡 **YELLOW** | Cold-start replay (F5), TLS hardening (F6), dead logger (F7), dead param (F8), unused transport (F9), stale generator (F10), doc drift (F11) | 7 | ⬜ open |

The Round-1 table below reflects *intent*, not verified state: the tree did not
compile at the time, so most "✅ fixed" claims were unverified. The Round-2
`fixes.md` section records which of them were actually incomplete (R6, A4, A5,
A7, Y9).

### Round 1 (commit `96a23f0`, historical)

| Light | Meaning | Count | Round-2 verdict |
|:-----:|---|:-----:|:------:|
| 🔴 **RED** | Crashes, build failure, data corruption, or security vulnerability | 8 | mostly fixed; R6 partial |
| 🟠 **AMBER** | Real defect under specific conditions | 10 | A4 partial; A5/A7 open |
| 🟡 **YELLOW** | Latent risk, dead code, or incomplete | 11 | Y9 open (by design) |
| 🟢 **GREEN** | Verified-correct (noted because suspicious at a glance) | 8 | re-verified |

### Highlights of what the fix rounds addressed

- 🔴 **R1** — `swift build` failed on overlapping target sources; `Package.swift` now `exclude`s sibling-target directories and drops the Python-only `Scripts` target.
- 🔴 **R2/R4** — `fatalError` on the primary RPC path and a force-unwrap crash on non-OAuth connect; the dead `HermesGatewayClient` facade was removed in favour of `HermesClient`.
- 🔴 **R6** — unvalidated `ws://` URLs and a never-called ticket provider; `wss://` is now enforced. (Ticket *attachment* is still a placeholder — see **F4**.)
- 🔴 **R7** — conversation content was logged verbatim on decode failure; now logs byte count only.
- 🟠 **A2** — the receive loop keyed off `task.state == .open` (no such case), so the client was write-only; the loop now drives off `receive()`.
- 🟠 **A3** — event-handler cancellation compared boxed closures by identity; handlers are now keyed by a numeric id.
- 🟠 **A9** — `AnyCodable.encode` flattened nested arrays and encoded booleans as `1`/`0`; both fixed.
- 🔴 **N1–N9 (Round 2)** — the package did not actually compile until Round 2; see [`fixes.md`](fixes.md) for the full list.

Full details, including exact locations and reasoning, are in [`fixes.md`](fixes.md).

---

## License

See [`LICENSE.txt`](LICENSE.txt).
