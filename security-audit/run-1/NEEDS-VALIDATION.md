# Needs Validation — HermesMobile run-1
1. auth-keychain-access-control: requires Keychain runtime verification on iOS simulator/device.
2. auth-ws-ticket-nil-handle: requires WebSocket gateway fixture + Swift toolchain for bounded execution.
Blocker for both: no Swift toolchain / simulator / device on Linux audit host.
Safe validation plan: source confirmation complete; deployment validation via user's Mac (Xcode / iOS Simulator / local tui_gateway fixture).
