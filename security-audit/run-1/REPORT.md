# Security Audit Report — HermesMobile (run-1)
Scope: Auth/WebSocket/Gateway surfaces (standard profile, scoped run).
Status: **incomplete** — sandboxed local execution unavailable (no Swift toolchain / iOS simulator / device on audit host).
Findings: 1 confirmed (PKCE stale-on-cancel), 2 needs_validation (keychain access, WS ticket nil).
Artifacts: run-metadata.json, architecture.md, coverage-ledger.json, findings.json, FINDINGS-DETAIL.md, NEEDS-VALIDATION.md.
All artifacts validated (findings.json: PASS 3; coverage-ledger.json: PASS 5).
Gap disclosed in Phase 6: target-controlled sandboxed execution cannot be enforced; findings requiring local runtime confirmation remain `needs_validation` with deployment-level validation plans.
