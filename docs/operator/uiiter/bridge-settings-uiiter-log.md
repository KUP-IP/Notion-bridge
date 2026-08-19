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

## Terminal close — DEFERRED loops (2026-07-21)

| Loop | Reason deferred |
|------|-----------------|
| First-sale proof (Stripe live buy → mint → activate) | Outside tag cut; operator custody |
| Anthropic directory + legal/ToS sign-off | Outside tag cut |
| OAuth bake proof without `bridge-env` LaunchAgent | Not re-proven this session after v4 inject |
| Settings Dark captures (Security/Connection/Memory) | Operator appearance ownership |
| Settings P3 polish (CMD/SK/CON/MEM/DS/ADV) | Non-blocking density |
| Lost PACKET Priority scores (~60) | Pre-session Notion data loss; not this arc |
| Incomplete views-write smoke receipt file | Untracked; incomplete; leave or finish later |
| Shell UI-ITER (Dashboard / Command Bridge / Onboarding) | Explicit Wave A OUT |

---

# v4.0.4 / 93 chrome UI-ITER — Wave 1 board (2026-08-18)

**Baseline:** installed 4.0.4 / build 93 · SHA `f4a7d4ee159a841863df9beffe9b15dc86e1cd03` · dirty false  
**Feed:** 4.0.4 / 93 Released Verified (do not recut). Next legal identity if this campaign ships: **4.0.5 / 94**.  
**Worktree:** `feat/v4.0.5-chrome-uiiter` @ `55a5d3c` (origin/main + appcast).  
**Captures (uncommitted):** `docs/operator/uiiter/captures/v404-chrome/{light,dark}/`  
**Appearance:** operator Light (`AppleInterfaceStyle` absent). Dark pass via System Events; restored Light in-session (Commands recapture `light/commands-restore.png`).  
**Onboarding:** `hasCompletedOnboarding = 1`. Wizard **deferred** — restore trap would require relaunch (MCP death) or Advanced Reset; Demo Gate Onboarding deferred with reason.  
**Skill caveat:** app-dev Testing/Building. No Magic Patterns. Track B not used (finding is clip/height, not an IA fork).

## Operator restore traps

| Flag | Before | After |
|------|--------|-------|
| Appearance | Light | Light (proven `commands-restore.png` + `AppleInterfaceStyle` absent) |
| `hasCompletedOnboarding` | 1 | 1 (untouched) |

## Capture matrix

| Surface | Light | Dark |
|---------|-------|------|
| Settings Commands | commands.png | commands.png |
| Settings Skills | skills.png | skills.png |
| Settings Jobs | jobs.png | jobs.png |
| Settings Tools | tools.png | tools.png |
| Settings Security | security.png | security.png |
| Settings Connection | connection.png | connection.png |
| Settings Memory | memory.png | memory.png |
| Settings Data Sources | data-sources.png | data-sources.png |
| Settings Advanced | advanced.png | advanced.png |
| Command Bridge idle | command-bridge-idle.png | command-bridge-idle.png |
| Command Bridge search no-match | command-bridge-search-nomatch.png | (idle Dark covers chrome; create clip is Light P0) |
| Command Bridge create sheet | command-bridge-create-sheet.png | — |
| Dashboard | **deferred** | **deferred** |
| Onboarding | **deferred** | **deferred** |

Duplicate Settings windows (win 5670 + 5628) during the audit — P3 chrome duplication, not ship-blocking.

## UX interaction audit (fail-closed)

| Check | Result |
|-------|--------|
| ⌃⌘B opens palette | **PASS** |
| Esc dismisses palette | **PASS** (toggle close / hide) |
| 1–0 fire favorites | **PASS** (slot 1 Initiate fired on probe) |
| Ordinary Return never creates | **PASS** — Return with no-match query did not open sheet or write |
| ⌥↩ / Create row opens sheet | **PASS** (Create row click) |
| Cancel drops draft | **PASS with caveat** — Save/Cancel were off-host (P0); no Save |
| Settings Tools filter is not Search | **PASS** — family chips + tool filter, not Command Bridge Search |
| Dashboard deep-links | **deferred** — MenuBarExtra popover not captured via AX; Settings MCP navigate lands on named sections |
| PKT-1005 harness | **PASS** — `make test-floor` 3761 passed, 0 failed on Wave 3 SHA; SettingsAXIdentifierTests green |
| #129 clipboard on fire path | not reopened; insert path unchanged |

## Critique board (this campaign)

| ID | Surface | P | Finding | Evidence | Status |
|----|---------|---|---------|----------|--------|
| CB-1 | Command Bridge | **P0** | Create sheet clipped by fixed `hostHeight` 260. AX Save/Cancel at y=1318; host bottom y=1218. Primary CTAs not visible / not hittable. Named variable: **host clip vs content-hug when create sheet is open**. | light/command-bridge-create-sheet.png | **fixed in code → F.0 recapture** |
| CB-2 | Command Bridge | P2 | Create sheet Name + body both echo the query string | light/command-bridge-create-sheet.png | deferred (cheap P2 in same file if loop 1 is open) |
| SET-DUP | Settings | P3 | Two Settings windows (5670 + 5628) | light/commands-win*.png | deferred |
| CMD-1 | Commands | P3 | Stats repeated hero + footer | Wave A, still | deferred |
| SK-2 | Skills | P3 | Tall palette empty-state banner | Wave A, still | deferred |
| CON-1 | Connection | P3 | Live vs sessions skew | Wave A, still | deferred |
| CON-2 | Connection | P3 | Runtime meta micro-contrast | Wave A, still | deferred |
| MEM-1 | Memory | P3 | Empty preview sparse | Wave A, still | deferred |
| DS-1 | Data Sources | P3 | Last card clip / scroll | Wave A, still | deferred |
| ADV-1 | Advanced | P3 | Network Save vs field height | Wave A, still | deferred |
| SEC-2 | Security | P3 | GATES digits unlabeled | Wave A, still | deferred |
| DARK-TOK | Settings + palette | — | Dark carbon tokens readable on 9 Settings + idle palette | dark/*.png | clean; no new P0 |

**P0:** CB-1. **P1:** none (Dashboard/Onboarding are capture-method deferrals, not proven product hierarchy failures). Empty-release gate: **ship 4.0.5 / 94** for CB-1.

## Track A — loop 1

- **Variable:** host panel height must expand when create sheet is open so Save/Cancel stay inside the host.
- **Track B:** skipped (not an IA fork).
- **Loop cap remaining after this loop:** 7.
- **Code:** idle `hostHeight` stays 260 (`< 360`). `hostHeightCreateSheet` = 480. `CommandBridgeRootView` frames to `hostHeight(createSheetOpen:)` and `setFrame`s the NSPanel with `frameKeepingTop` (grow/shrink downward). Hosting view `autoresizingMask` width+height.
- **CB-2:** left deferred (`CommandSearchCreate.draft` is a different file).
- **Last loop id:** Track A loop 1. Recapture + Demo Gate in Wave 4.
