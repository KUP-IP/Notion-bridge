# Bridge Settings UI-ITER — Wave A

**SHA:** `aff3592` · **Branch:** `feat/ui-iter` · **Installed:** 3.9.9 / 81 (`ALLOW_NON_MAIN_INSTALL=1 make install-copy`)  
**Evidence:** `docs/operator/uiiter/captures/` (baseline) · `captures/pass1/` (post-fix)

## A.0 Capture smoke
- Triad: `bridge_open_settings` → `bridge_settings_navigate(Security)` → `bridge_focus_settings` → `screen_capture` window `kup.solutions.the-bridge`
- Result: Settings Security visible. **PASS**

## Master critique board

| ID | Surface | P | Finding | Visual evidence | Status |
|----|---------|---|---------|-----------------|--------|
| SK-1 | Skills | P1 | Group caption wraps; stray letter under count | skills.png (baseline) | **fixed + F.0 re-verified** pass1/skills.png — single-line `ROUTING & ORCHESTRATORS 8` |
| JOB-1 | Jobs | P2 | Duplicate pause: mono `paused` + badge `Paused` | jobs.png (baseline) | **fixed + F.0 re-verified** pass1/jobs.png — badge only; next-run column clean |
| SEC-1 | Security | P2 | Orphan used-by chip error-red | security.png (baseline) | **fixed + F.0 re-verified** pass1/security.png — `no tools registered` no longer failure-red (`.info`) |
| SEC-2 | Security | P3 | GATES cluster digits unlabeled | security.png | deferred — density, not ship-blocking |
| CMD-1 | Commands | P3 | Stats repeated (hero + footer) | commands.png | deferred |
| SK-2 | Skills | P3 | Tall palette empty-state banner | skills.png / pass1 | deferred |
| CON-1 | Connection | P3 | Live vs sessions count skew | connection.png | deferred (data) |
| CON-2 | Connection | P3 | Runtime meta micro-contrast | connection.png | deferred |
| MEM-1 | Memory | P3 | Empty preview pane sparse | memory.png | deferred (acceptable empty) |
| DS-1 | Data Sources | P3 | Last card clipped at bottom | data-sources.png | deferred (scroll) |
| ADV-1 | Advanced | P3 | Network Save vs field height | advanced.png | deferred |
| TOOLS-1 | Tools | — | No P0/P1 | tools.png | clean |

**P0:** none.

## Visual DoD checklist (Wave A)
- [x] Section headers consistent (Settings chrome)
- [x] Empty states present when empty (Skills detail, Memory preview, Jobs recent runs)
- [x] No clipped primary CTAs on audited surfaces
- [x] Hairline/token grammar OK on fixed surfaces
- [x] Light captured for Security / Connection / Memory (`pass1/`)
- [ ] Dark for Security / Connection / Memory — **deferred**: system appearance is operator-owned; Light Demo Gate evidence is the Wave A bar

## Demo Gate (polish-2)
Agent visual Demo Gate on installed 3.9.9 / `aff3592`.

| Surface | Evidence | Verdict | Notes |
|---------|----------|---------|-------|
| Security | pass1/security.png | **PASS** | Vault readable; orphan chips calm; license banner OK |
| Connection | pass1/connection.png | **PASS** | Endpoint / handshake / clients / loopback coherent |
| Memory | pass1/memory.png | **PASS** | Memos list + empty preview; no chrome breakage |

**Operator verdict (Ship Gate 2026-07-21):** **PASS** (explicit GO on Demo Gate closeout). DoD met.

## Pass notes
- Pass 1: SK-1 / JOB-1 / SEC-1 landed + installed + re-captured.
- Pass 2: Demo Gate PASS ×3 (Light); Dark deferred with reason; P3s deferred.
- SEC-1 used `.info` (BridgeDepLink has no `.warn`) — intentional.

## Version
Wave A landed on 3.9.9; operator Ship Gate GO (2026-07-21) cut **v4.0.0** / build 82.

## Housekeeping
- Smoke-receipt `docs/operator/views-write-smoke-2026-07-21-w5b-install.md` (primary checkout untracked incomplete) — **leave untracked**; out of Wave A Settings scope.
- Captures are large PNGs — keep local under `docs/operator/uiiter/captures/`; log is the committed SSOT.
