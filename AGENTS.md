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

**As of 2026-11-04, re-verified on Xcode 27.2 / Swift 6.4.2: `swift build`,
`swift test` (6 tests, 0 failures), `xcodebuild … -destination
'generic/platform=iOS Simulator'`, and `xcodebuild … -destination
'generic/platform=macOS'` all pass with zero warnings.** Round 2 of `fixes.md`
is the record of getting there; the code on `master` before that round did
**not** compile. Re-run `swift build` before trusting any ✅ table — the ✅ marks
in `README.md`/`todo.md` were aspirational before Round 2 and are now accurate
for build/test only.

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
Scripts/build-ios-device.sh                        # signed/un-signed device .app
Scripts/build-ios-device.sh --profile P --ipa      # Ad Hoc / TestFlight .ipa
```

> The Xcode build compiles the library; there is no `.xcodeproj` (SwiftPM only).
> `xcodebuild` never produces a `.app` — the two `Scripts/*-ios-*.sh` wrappers
> assemble one, because SwiftPM has no application product type (see
> "Packaging an .app" below).

### Toolchain & SDKs (verified 2026-11-04)

**Xcode 27.2 (27B52) is installed at `/Applications/Xcode.app`, and
`xcode-select -p` points at it**, so `swift` resolves to Swift 6.4.2 from
Xcode's toolchain and a plain `swift build` / `swift test` works — no `SDKROOT`
override.

```bash
xcode-select -p          # /Applications/Xcode.app/Contents/Developer
xcrun --find swift       # …/XcodeDefault.xctoolchain/usr/bin/swift
swift --version          # Apple Swift version 6.4.2, target arm64-apple-macosx27.2.0
xcrun --show-sdk-path    # …/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
```

This supersedes the old workaround of pinning
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`. That was
needed when only the Command Line Tools were present: their macOS 27 SDK
declares SwiftUI's `@State` as an `@externalMacro`, and the CLT toolchain does
not ship the `SwiftUIMacros` plugin, so `swift build` failed with:

```
error: external macro implementation type 'SwiftUIMacros.StateMacro' could not
be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found
```

Xcode's toolchain **does** ship `libSwiftUIMacros.dylib`, which is why the pin
is no longer needed. If that error ever comes back, the selected toolchain
regressed — check `xcode-select -p` and `xcrun --find swift` before reintroducing
the pin. Note that a **stale `DEVELOPER_DIR`** (shell env or an editor/MCP
config) makes `xcrun` hard-fail with `missing DEVELOPER_DIR path: …`; it does
not fall back to the default Xcode.

### Simulator & Xcode build-location state

- iOS / tvOS / visionOS / DriverKit SDKs are installed (27.2), so
  `xcodebuild` with `-destination 'generic/platform=iOS Simulator'` compiles.
  iOS builds **are** possible on this machine now (they were not when only the
  CLT were installed).
- Simulator runtime: **iOS 27.0 only** (`xcrun simctl list runtimes`). The
  iPhone 18 Pro / 18 Pro Max / 17 / 17e / Air and iPad (A16) / Air / Pro devices
  exist and are usable; anything tagged `iOS 27.2` shows up as `Unavailable`
  until that runtime is downloaded. `-destination 'name=iPhone 15'` fails
  because **no such device exists here** — check
  `xcrun simctl list devices available` before naming one, or use the generic
  destination. `Scripts/run-ios-sim.sh` (no `--device`) picks a usable iPhone.
- A **physical iPhone 14 is paired** (`xcrun devicectl list devices`), so device
  builds and `--install` are testable on this machine.
- iOS builds are warning-free as of 2026-11-04: `ComposerView` uses
  `UTType.image.identifier` instead of the deprecated `kUTTypeImage`, so
  `xcodebuild` for iOS Simulator **and** `generic/platform=iOS` report no
  warnings either.
- Xcode's build location must stay at the default DerivedData
  (`~/Library/Developer/Xcode/DerivedData`). A leftover **custom** location on
  an unmounted external volume makes every `xcodebuild` fail with
  `Could not compute dependency graph: … “WORKSPACE@v11_hash=…” doesn’t exist`,
  and `-derivedDataPath` does **not** override the intermediates path. Diagnose
  and repair with:

  ```bash
  defaults read com.apple.dt.Xcode IDEBuildLocationStyle      # want: Default
  defaults delete com.apple.dt.Xcode IDECustomBuildIntermediatesPath
  defaults delete com.apple.dt.Xcode IDECustomBuildProductsPath
  defaults write com.apple.dt.Xcode IDEBuildLocationStyle -string Default
  ```

## Packaging an .app (SwiftPM has no application product)

`Package.swift` exposes only `.library` products, so there is no `.app` for
`xcodebuild` to build. Both scripts do the same three-step dance — build the
package with signing off, link the per-module `.o` files into an executable with
`swiftc`, write a generated `Info.plist` — and differ only in SDK/arch/signing:

| target | script | output | runnable on |
| --- | --- | --- | --- |
| Simulator | `Scripts/run-ios-sim.sh` | `.build/ios-sim/HermesMobile.app` | simulator only |
| Device (arm64) | `Scripts/build-ios-device.sh` | `.build/ios-device/HermesMobile.app` | a device, **if signed** |

`build-ios-device.sh` signs ad-hoc when no profile is given (inspectable, not
installable) and takes `--profile`, `--identity`, `--team`, `--entitlements`,
`--bundle-id`, `--version`, `--build`, `--ipa`, `--install`, `--device`.
Prerelease checklist:

1. Register the App ID (`--bundle-id`, default `com.hermesmobile.app`) in the
   developer portal, and the device's UDID.
2. Download a **Development** or **Ad Hoc** profile; its `TeamIdentifier` and
   `Entitlements` are read from the profile (`security cms -D` + `plutil`), so
   passing `--profile` is usually the only signing argument needed.
3. `Scripts/build-ios-device.sh --profile ~/Downloads/x.mobileprovision --ipa`
   → `Payload/HermesMobile.app` zipped as `.build/ios-device/HermesMobile-<v>-<b>.ipa`.
4. `--install` (development profile) or hand the `.ipa` to Xcode → Devices and
   Simulators / Apple Configurator / `xcrun devicectl device install app`.
   TestFlight needs an **Apple Distribution** profile and an App Store Connect
   app record; upload with `xcrun altool --upload-app` or Transporter — a
   development-signed `.ipa` cannot be uploaded.

Hard rule: do **not** hand-edit the generated `Info.plist` inside the scripts'
output — it is regenerated on every run; change the heredoc in the script.

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
