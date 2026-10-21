# AGENTS.md

Swift Package (`swift-tools-version:5.10`) for **HermesMobile**, a native iOS
client for a `hermes serve` gateway. It speaks the `tui_gateway` JSON-RPC 2.0
protocol over a `wss://` WebSocket. Shell / Renderer / Backend split — see
`README.md`.

- `gateway-contract.openrpc.json` (repo root) is the **source of truth** for the wire format.
- `fixes.md` (code-review findings R1–R8, A1–A10, Y1–Y11 **plus Round 2**, N1–N9/F1–F11)
  and `todo.md` (roadmap) are the project history/status docs; the README mirrors them.
- No external runtime dependencies — Foundation + SwiftUI only.

## Verify the build before trusting any status claim

**As of 2026-10-16 `swift build`, `swift test`, and `xcodebuild` all pass with
zero warnings.** Round 2 of `fixes.md` is the record of getting it there; the
code on `master` before that round did **not** compile. Re-run `swift build`
before trusting any ✅ table — the ✅ marks in `README.md`/`todo.md` were
aspirational before Round 2 and are now accurate for build/test only.

Things that were broken and are now fixed (do not regress them):

- `Sources/Generated/Models.swift` emitted `.string("...")` defaults on open-enum
  structs (`BrowserAction`, `CronAction`, …) with no `.string` member. Fixed in
  `Scripts/gen_models.py` (`_default_literal` now emits `Enum(rawValue:)`).
- `Sources/Gateway/*.swift` used `JSONValue` without `import GeneratedModels`.
- `GatewayClient.swift` used the removed `++` operator and declared a
  `HermesLogger` it never imported; `Package.swift` didn't depend on `HermesLogger`.
- `HermesCoreWebSocket/web_socket.swift` referenced the app-target
  `WebSocketTicket`, forced `Encodable` on `Any`-carrying types, exposed private
  types on a public struct, and used `URLSessionWebSocketTask.messages` (absent
  on this SDK) — it now takes `wsUrl: String` and reads via `receive()`.
- `Views/Chat/{ChatView,ComposerView}.swift` had `if let` on a non-optional,
  `await` inside a sync `Button` action, and an unbound `if let result`.

## Layout & SwiftPM gotchas

- One target per `Sources/` subdirectory, **except** `HermesMobile`, which uses
  `path: "Sources"` plus an explicit `exclude:` list. Any new top-level
  `Sources/<Dir>` must be added to that `exclude:` list (and given its own
  `.target`) or SwiftPM aborts with `target '...' has overlapping sources`
  (fixes.md R1). Do **not** add a path to `exclude:` that doesn't exist — SwiftPM
  warns (`Invalid Exclude … File not found`).
- **Dependency direction** (enforced by the build):
  - `HermesMobile → GeneratedModels`, `HermesMobile → HermesLogger`
  - `HermesCoreWebSocket → HermesLogger`
  - `GeneratedModels`, `HermesLogger`, `HermesCoreWebSocket` must stay
    dependency-free and portable — **never reference app-target types**
    (`Sources/Auth`, `Sources/Gateway`, `Sources/Store`, `Sources/Views`) from
    them. That coupling is what broke `HermesCoreWebSocket`.
  - Any file that uses `JSONValue` / `GWMethod` / generated models must
    `import GeneratedModels`; any file that uses `HermesLogger` must import it
    **and** the target must list the dependency.
- `HermesMobile` imports SwiftUI/UIKit → Apple platforms only. Portable targets:
  `GeneratedModels`, `HermesLogger`, `HermesCoreWebSocket`.
- `HermesCoreWebSocket` is **not used by the app** — `GatewayClient` drives
  `URLSessionWebSocketTask` directly. Treat it as a standalone/reference transport.
- `Package 2.swift` and `Package 3.swift` are leftover scaffolds (staged, unused).
  `Tools/generate_swift_models.py` is an unwired alternate generator.

## Commands

```bash
swift build                       # debug build of all targets
swift build -c release
swift build --build-tests         # build tests too (catches test-target errors)
swift test                        # XCTest suite (Tests/HermesMobileTests.swift)
swift test --filter HermesMobileTests.HermesMobileTests          # one case class
swift test --filter HermesMobileTests.HermesMobileTests/testReconnectBackoffIsBounded
swift build --target GeneratedModels   # build a single portable target
xcodebuild -scheme HermesMobile -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme HermesMobile -destination 'generic/platform=macOS' build
```

> Simulator **runtimes are not installed** on this machine, so name a specific
> device (`name=iPhone 15`) fails; use `-destination 'generic/platform=iOS Simulator'`.
> The Xcode build compiles the library; there is no `.xcodeproj` (SwiftPM only).

### SDK pin (macOS 27 SDK vs. the CLT toolchain)

The installed Command Line Tools ship the **macOS 27 SDK**, where SwiftUI's
`@State` is an `@externalMacro` that needs the `SwiftUIMacros` plugin. The CLT
toolchain does **not** ship that plugin, so a plain `swift build` fails with:

```
error: external macro implementation type 'SwiftUIMacros.StateMacro' could not
be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found
```

Only a Swift 6.2-built copy of the plugin exists on this machine
(`/Applications/Swift Playground.app/…/libSwiftUIMacros.dylib`), and the
6.4 compiler rejects it ("produced malformed response"). Build against the
**macOS 26.5 SDK** instead — it declares `@State` as a plain property wrapper
and needs no plugin:

```bash
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
swift build && swift test
```

The permanent fix is installing an Xcode whose toolchain matches the macOS 27
SDK (Swift 6.4+ shipping `libSwiftUIMacros.dylib`). There are no iOS SDKs
installed, so iOS builds are not possible on this machine at all.

## Code generation (read before regenerating)

`Sources/Generated/*.swift` is machine-generated from
`gateway-contract.openrpc.json` and **committed** so the package builds without
Python. Never hand-edit; fix the generator.

- **Do not hand-edit `Models.swift`.** Fix `Scripts/gen_models.py`.
- `Scripts/gen_models.py` `OUT_DIR` is now repo-relative
  (`Sources/Generated`). Regenerating must be drift-free apart from intended
  changes — verify with `diff -ru` against a backup before committing.
- Enum-typed property defaults are emitted as `EnumName(rawValue: "…")`, not
  `.string("…")`. Keep it that way.
- `Scripts/gen_client.py` is **deprecated** (fixes.md R2/R3): it emits a
  non-compiling `HermesGatewayClient.swift` with a duplicate `HermesCoreWebSocket`
  and `fatalError` on connect. Its `OUT_DIR` now writes to
  `Scripts/generated/` (git-ignored, outside the targets). Don't wire it back in;
  `Sources/HermesClient.swift` is the real typed facade.

## Open review findings (Round 2, not yet fixed)

These compile and are documented in `fixes.md`; fix deliberately, they are not
build blockers:

- **F1** — the 4401/4403 auth-close path in `GatewayClient` leaves the socket,
  session, and pending calls alive (they hang to timeout).
- **F2** — `dropSocket` emits the `.closed` callback twice (once explicitly for
  "stable open", once via `setState`).
- **F3** — `TranscriptStore` is never subscribed to the transport, and
  `appendToolCall` looks messages up by `session_id` instead of `message_id`.
- **F4** — auth is a placeholder: `GatewayConnection.connect` feeds
  `ticket.wsUrl` into the `Authorization` header (there is no ticket token yet).
- **F5** — cold-start replay is skipped (`fetchReplay` returns early on an empty
  watermark) — the original A4 fix only covers mid-flight holds.
- **Y9** — `JSONID.key` is deliberately type-tagged (`n:`/`s:`), so `42` ≠ `"42"`.
  The doc comment and test now say so; do not "normalise" without deciding intent.

## Invariants to preserve

- Generated code is frozen; wire enums are **open** (`RawRepresentable` struct
  with typed constants + raw passthrough) so unknown backend values still decode.
- Security: `wss://` only in release builds (`ws://` behind `#if DEBUG`);
  never log conversation content — log frame metadata/byte counts only; tickets
  are single-use secrets and must never be logged or persisted.
- `GatewayClient` is `@MainActor`; `@Sendable` closures it hands out must hop via
  `Task { @MainActor in … }` before touching its state (Swift 6 hazard).
