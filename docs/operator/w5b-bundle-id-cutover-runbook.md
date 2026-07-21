# W5B — Bundle ID cutover runbook (`notion-bridge` → `the-bridge`)

**Status (2026-07-21):** MANUAL cutover **IN PROGRESS** on `feat/w5b-bundle-id-cutover` after D1 dry_run green ([run 29795964814](https://github.com/KUP-IP/the-bridge/actions/runs/29795964814)). Do **not** tag `v4.0.0` (Sale Gate locked).

## Target

| Surface | Current (pre-cutover) | After cutover |
|---------|----------------------|---------------|
| `CFBundleIdentifier` | `kup.solutions.notion-bridge` | `kup.solutions.the-bridge` |
| Keychain canonical | already `kup.solutions.the-bridge` (W5A) | unchanged |
| Keychain legacy read | includes `kup.solutions.notion-bridge` | keep forever for migration |
| Keychain access group | `TEAM.kup.solutions.notion-bridge` | accept both prior + new groups |

## Prep that was safe before D1 (no Info.plist flip)

- Derive TCC / logger subsystem strings from `Bundle.main.bundleIdentifier` with constant fallback.
- Keep `KeychainManager.legacyServices` containing `kup.solutions.notion-bridge`.
- First-launch re-grant panel (sentinel) — inert until id flips.
- This runbook + Sparkle old→new verification checklist below.

## MANUAL cutover (after D1 dry_run green)

1. Branch off current `main`; bump marketing/build per release rules **only if shipping** (Sale Gate still locked → no `v4.0.0` tag).
2. Flip root `Info.plist` `CFBundleIdentifier` (+ extension ids).
3. Update Makefile `BUNDLE_ID` / `clean-tcc`, TCC SQL clients, Settings reset ids, credential access-group allowlist for prior id.
4. `make test-floor` → `make install-copy` (or notarized `make install` when shipping).
5. Relaunch via `open -a "The Bridge"` so launchd env agent applies.
6. Live TCC: Full Disk Access, Automation, Screen Recording, Accessibility — re-grant for the **new** id.
7. Sparkle: prove old install → new update path (or clean reinstall if Sparkle channel breaks across id change — document which).
8. Evidence: `/health`, `bridge_status`, Keychain credential read still works via legacy fallback.
9. Only then mark W5B packet Done.

## Explicitly out of scope until Sale Gate

- Claiming cutover Done without runtime id `kup.solutions.the-bridge`.
- EdDSA key rotate bundled with id change.
- Tagging `v4.0.0`.
