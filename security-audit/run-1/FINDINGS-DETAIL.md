# Findings Detail — HermesMobile auth/WebSocket/gateway
- auth-oauth-pkce-stale-on-cancel (confirmed): AuthView.cancel path does not call completeOAuth(), leaving activePKCE/activeProvider set. Source-only; remediation = add resetOAuthState() call on cancel.
- auth-keychain-access-control (needs_validation): AuthStore uses AfterFirstUnlockThisDeviceOnly; deployment validation recommended.
- auth-ws-ticket-nil-handle (needs_validation): mintWSTicket swallows errors; deployment validation against gateway fixture recommended.
