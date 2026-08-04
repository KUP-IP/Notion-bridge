# Build 89 local pilot — REJECT + rollback (2026-08-03)

## Verdict
**REJECT** build 89 for local pilot. Restored build 87.

## Installed candidate
- Source SHA: `6ef0b32acfb5e83e494782df0ab290dc264b4d8b`
- Binary SHA-256: `bcd479670deedbd5dd53e6885471e14e3bfabf092361333c44b48c9bb378aedf`
- CDHash: `d7f1bb0e8ab064b21687fbc316e210bd5298ef9e`
- Path: `.build/candidates/The Bridge-4.0.2-89-6ef0b32.app`
- Method: `ALLOW_NON_MAIN_INSTALL=1 make install-copy-staged`

## Acceptance failure
Cold `bridge_initialize` (HTTP `/mcp`, 120s budget):
- Attempt 1 (~2.5s): `finalState=DEGRADED`, `capabilityState=FULL`, `routingRosterState=missing` / `EMPTY`, reason `runtime_exposure_freshness_expired`
- `skills_exposure_status`: active generation `7a340178-…` compiled `2026-07-29`, age ~518843s, degraded; latestReceipt `mode=shadow` `outcome=shadowReady` (candidate gen `9e3da411-…` not activated)
- After 55s wait, attempt 2 (~4s): still DEGRADED / EMPTY
- `messages_recent` not attempted (roster gate failed)

## Rollback
- Restored `.build/rollback/The Bridge-4.0.2-87-777ab46a.app`
- Binary SHA-256: `fc337ab11120e5fc09ad578ec9e54db42f6c41f4c80007f1e5bf80fbd0903e56`
- Post-rollback `bridge_initialize`: COMPLETE / FULL / roster HEALTHY

## Unblock
Cold init must wait for an **activated** fresh routing generation (not shadow-only) before claiming a healthy roster, or publish shadow→active on freshness expiry.

## Unblock diagnosis (2026-08-03)

**Layer:** application defect (not harness/transport; live product stayed on 87).

**Expected:** after cold `bridge_initialize` joins shadow refresh with `shadowReady` + empty exposure changes, roster becomes healthy via `verified_unchanged_shadow_renewed_freshness`.

**Actual:** join awaited `runShadow()` (~2–4s), receipt was `shadowReady`/`changes=[]`, but roster stayed `runtime_exposure_freshness_expired` / EMPTY.

**Root cause:** `unchangedShadowRenewal` required `receipt.snapshotID == generation.snapshotID`. Live: generation `af9023e119acd8d1` vs receipt `2d19aa6a333c259b`. Snapshot hash includes `notionLastEditedTime`, so ordinary Notion edits break renewal even when Runtime Exposure policy is unchanged.

**Fix:** renew on empty `changes` + matching `activeGenerationID` (not snapshot equality). Regression test added. Suite: 3593 passed, 0 failed.

**Not done here:** re-install / Ship Gate re-pilot of a new build. Next: Execute → ship a corrected pilot build, then Ship Gate local install again.
