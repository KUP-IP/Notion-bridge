# W5B — Bundle ID cutover runbook (`notion-bridge` → `the-bridge`)

**Status (Closeout-A 2026-07-20):** MANUAL cutover **blocked on D1** (`LICENSE_PUBLIC_KEY_BASE64URL` + release dry_run). Prep here is documentation only — **do not** flip `CFBundleIdentifier` in this sprint.

## Target

| Surface | Current | After cutover |
|---------|---------|---------------|
| `CFBundleIdentifier` | `kup.solutions.notion-bridge` | `kup.solutions.the-bridge` |
| Keychain canonical | already `kup.solutions.the-bridge` (W5A) | unchanged |
| Keychain legacy read | includes `kup.solutions.notion-bridge` | keep forever for migration |

## Prep that is safe before D1 (no Info.plist flip)

- Derive TCC / logger subsystem strings from `Bundle.main.bundleIdentifier` with constant fallback.
- Keep `KeychainManager.legacyServices` containing `kup.solutions.notion-bridge`.
- First-launch re-grant panel (sentinel) — inert until id flips.
- This runbook + Sparkle old→new verification checklist below.

## MANUAL cutover (after D1 dry_run green)

1. Branch off current `main`; bump marketing/build per release rules if shipping.
2. Flip root `Info.plist` `CFBundleIdentifier` (+ any extension ids if present).
3. `make test-floor` → `make install` (notarized) or operator-approved install path.
4. Relaunch via `open -a "The Bridge"` so launchd env agent applies.
5. Live TCC: Full Disk Access, Automation, Screen Recording, Accessibility — re-grant for the **new** id.
6. Sparkle: prove old install → new update path (or clean reinstall if Sparkle channel breaks across id change — document which).
7. Evidence: `/health`, `bridge_status`, Keychain credential read still works via legacy fallback.
8. Only then mark W5B packet Done.

## Explicitly out of Closeout-A

- Claiming cutover Done without runtime id `kup.solutions.the-bridge`.
- EdDSA key rotate bundled with id change.
- Tagging `v4.0.0` (Sale Gate / Fork1 unlock only).
