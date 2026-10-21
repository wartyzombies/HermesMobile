# Security Audit Architecture — HermesMobile Auth/WebSocket/Gateway

Profile: standard (scoped to auth/WebSocket/gateway surfaces, no full device matrix). Scope paths: Sources/Views/Auth/AuthView.swift, AuthGateView.swift, Sources/HermesClient.swift, Sources/Gateway/*.swift, Sources/Views/Chat/ComposerView.swift, Sources/Views/Commands/CommandsView.swift, Sources/Views/Sidebar/SidebarView.swift. Expanded source paths include Sources/Auth/*.swift and Sources/Generated/ (wire contracts).

Target: HermesMobile (GitHub stablyai/orca / local scratch repo at /opt/data/profiles/coder/cache/scratch/HermesMobile). Source ref: 3ee63de (commit message "Auth: track activeProvider across OAuth flow (Y27)"), clean worktree.

## Product and principals
HermesMobile is the iOS SwiftUI client for a self-hosted Hermes Gateway (tui_gateway). It connects via WebSocket JSON-RPC to a gateway that serves AI agent sessions (chat, approvals, tool calls, session replay, command catalog). Lower-trust principals: unauthenticated users, any app user interacting with the gateway, malicious or misconfigured gateways, third-party OAuth providers (Nous Portal, self-hosted OIDC), and the device Keychain.
Normal user actions: sign in (basic, OAuth with PKCE, open gateway), resume session, submit prompts, view transcript, approve/reject dangerous commands, select model, execute slash commands, open/close WebSocket connection.

## Stack and build limits
iOS 17 / macOS 14 Swift 5.10 package. Main targets: HermesMobile (SwiftUI app), HermesCoreWebSocket (low-level transport), GeneratedModels (OpenRPC wire), HermesLogger. No Swift toolchain in this audit host (no swift/swiftc in PATH). This blocks sandboxed Swift builds and native simulator checks; bounded local execution is unavailable for Swift targets. Source-only review is permitted; sandboxed validation must be performed on the user's Mac/Xcode environment.

## Trust-sensitive surfaces
1. Auth gate (AuthView.swift, AuthGateView.swift) — basic auth, OAuth (Nous Portal / self-hosted OIDC), PKCE. Keychain-backed AuthStore (Sources/Auth/AuthStore.swift) persists GatewayCredentials per host.
2. Authenticator (HermesAuthenticator.swift, OAuthPKCE.swift, WebSocketTicket.swift) — PKCE generation, token storage, session cookie extraction, WS ticket minting, basic auth sign-in, OAuth complete, currentUser.
3. Gateway transport (GatewayClient.swift, GatewayConnection.swift) — WebSocket JSON-RPC 2.0 (open, reconnect replay, heartbeat, server→client approval handling). No external network access allowed; isolated loopback only. Transport rejects non-`wss://` URLs (DEBUG escape). Single-use WS ticket used as Authorization header/query parameter.
4. Client API (HermesClient.swift) — typed wrappers for session lifecycle, prompts, approvals, model picker, config, profiles, commands, usage.
5. Views (ChatView.swift, ComposerView.swift, CommandsView.swift, SidebarView.swift) — compose submit, command execution, session selection, transcript replay.

## Source-visible controls
- Auth: `discover()` probes `GET /api/status`; `authRequired` from JSON; `authRequired: Bool`, `providers: [AuthProvider]`, `publicURL: URL?`. Basic auth: `POST /auth/password-login` returns `Set-Cookie: hermes_session_at`. OAuth PKCE: `PKCE` (SecRandomCopyBytes, S256 via CryptoKit + CommonCrypto fallback; Linux fallback uses pure-Swift SHA-256). Complete OAuth: hits `auth/callback?code=...` (dashboard server-side token exchange) and extracts cookie value. WS ticket: `POST /api/ws/ticket` with `Authorization: Bearer <token>`; returns `wss://...?ticket=<ticket>`. No refresh token in v1 (contract note: `refreshToken: nil`).
- Transport: `GatewayClient.connect(wsUrl:)` requires `wss://` scheme; `DEBUG` allows `ws`. `ticketProvider` async closure supplies fresh single-use ticket; `connect()` sets `req.setValue(ticket, forHTTPHeaderField: "Authorization")` before dial. WebSocket handshake uses `User-Agent: gateway-client-swift/1.0`. Connection state: idle → connecting → open; heartbeats every 15s; deadline exceeded → `.error`. Replay: `replayEnabled` default true; `lastSeenSeq` watermark; replay fetch via `session.events.since`; replayHold holds frames during replay fetch; supersession protected by `replayGeneration` counter.
- View-level controls: AuthGateView validates URL input; AuthView disables sign-in when fields empty; CommandsView disables buttons during execution; ChatView model picker uses `.confirmationDialog`; ComposerView sends prompt through `HermesClient.submitPrompt()`; Sidebar session selection updates `gateway?.activeSession`; Chat event dispatch handles approvals (`approvalTrigger`).
- Security annotations in source: R6 (refuse non-wss WebSocket URL, with DEBUG escape), R5 (no refresh token contract v1), R7 (no frame payload bytes logged — metadata only), A1-A10 (reconnect replay, heartbeat, event hold, replay generation, open identity check, replay fetch supersession, stale connection guard, timeout), Y3-Y10 (replay watermarks, replayHold flush order, replay supersession, replayed event dispatch, replay hold management).

## Attack surface (scoped audit scope)
Selected: AuthView/AuthGateView, AuthView provider buttons, AuthStore keychain storage, OAuthPKCE, WebSocketTicket, Authenticator discovery/basic/OAuth/WS-ticket/logout/currentUser, GatewayClient (connect/reconnect/replay/heartbeat/event fan-out/approval handling/request correlation), GatewayConnection (connect/disconnect), HermesClient (typed RPC wrappers, approval response, model picker, session lifecycle).
Excluded: Generated wire contracts (only read for interface shapes), non-auth Gateway event types, external deployment/proxy settings, iOS simulator/device build artifacts, Keychain device-level isolation, third-party OAuth provider behavior outside local source contracts, production endpoint testing. These exclusions are recorded as out-of-scope; they can become current work in future full runs.

## Prior evidence
No compatible `coverage-ledger.json` or `findings.json` from a prior run exists in this profile (checked `/opt/data/profiles/coder/home/` and `/opt/data` for prior artifacts). No prior-run input; all units initialized as `new` (no `prior_confirmed_same_source`, `prior_confirmed_changed_source`, or `prior_needs_validation` records).

## Sandbox capability status (critical blocker)
The audit environment (Linux host, no Swift toolchain — `swift` and `swiftc` missing; `swiftly` archive unreadable but no executable Swift compiler available) cannot enforce OS sandbox execution of Swift builds (no isolated SwiftPM build or native build targets, no simulator, no Keychain). Source-only review is permitted; sandboxed Swift execution is blocked. Any candidate that requires a bounded Swift execution check must be recorded as `needs_validation` with the exact blocker (`sandbox_execution_blocked: no Swift toolchain / native simulator / Keychain access available on audit host; safe validation requires user's macOS/Xcode environment`).

## Coverage plan
Standard profile, scoped audit of auth/WebSocket/gateway surfaces. Units seeded (see `coverage-ledger.json`): authview_1, auth_oauth_1, chat_composer_1, sidebar_1, commands_1. Coverage includes: basic auth form, OAuth authorization code/PKCE/state persistence, OAuth callback cookie extraction, session cookie expiration parsing, keychain storage/retrieval/deletion, WS ticket minting (single-use, bearer token authorization, URL construction), gateway connection (connect/auth scheme check, reconnect/replay heartbeat, replay supersession), event dispatch/replay hold, approval manager event routing, composer message send, sidebar session selection/resume, slash command catalog and execution. Expanded scope covers Sources/Auth/*.swift, Sources/Gateway/*.swift, and Sources/Views/Auth/AuthGateView.swift.

## Companion selection
No external companion files selected for this scoped audit (focus is on authentication/access control boundary, session lifecycle, and message/composition flows; no web-protocol, supply-chain, data-isolation, or binary-safety companions required at this scope). Ordinary attack-class blocks selected: `ATTACK-CLASSES.md#Access control` and `ATTACK-CLASSES.md#Authentication bypass` (for OAuth/authentication paths); `ATTACK-CLASSES.md#Input validation and control flow` (for composer message submission); `ATTACK-CLASSES.md#Command injection` (for slash command execution).

## Architecture cap
Under 1000 words. Includes product/principals, stack/build limits, trust-sensitive surfaces with source reference (file:line), source-visible controls, scoped audit surfaces, excluded out-of-scope surfaces, sandbox capability status with exact blocker, coverage plan, and selected/ordinary/companion blocks.
