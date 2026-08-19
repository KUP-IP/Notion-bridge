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
| CB-1 | Command Bridge | **P0** | Create sheet clipped by fixed `hostHeight` 260. AX Save/Cancel at y=1318; host bottom y=1218. Primary CTAs not visible / not hittable. Named variable: **host clip vs content-hug when create sheet is open**. | light/command-bridge-create-sheet.png | **closed** — F.0 on 4.0.5/94: host 584×480; Save/Cancel on-canvas Light+Dark (`v405-chrome`) |
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
- **Last loop id:** Track A loop 1.

---

# v4.0.5 / 94 Wave 4 — F.0 recapture + Demo Gate (2026-08-18)

**Installed:** 4.0.5 / build 94 · SHA `b9e1c8b4af997fc07093ce22d4209980939cfdb5` · dirty false  
**Tag:** annotated `v4.0.5` at that SHA (pushed). Release run [32202976643](https://github.com/KUP-IP/the-bridge/actions/runs/32202976643).  
**Local-sign caveat:** empty local license by design; not a substitute for the Sparkle/notarized customer binary.  
**Captures (uncommitted):** `docs/operator/uiiter/captures/v405-chrome/{light,dark}/`  
**Appearance:** operator Light (`AppleInterfaceStyle` absent). Dark pass via System Events; restored Light in-session (`light/commands-restore-proof.png` + key still absent).  
**Onboarding:** `hasCompletedOnboarding = 1` untouched. Wizard **deferred** — no Advanced Reset.  
**Probe command:** `zzzxno-match-uiiter-405` never Saved (no file under commands/). Escape cancelled the draft.  
**MCP:** Cursor client dead after relaunch; F.0 used Streamable HTTP `http://127.0.0.1:9700/mcp`. `screen_capture` with `windowId` (Settings 6122 1080×880; palette 6136 584×260 idle / 584×480 create).

## Operator restore traps

| Flag | Before | After |
|------|--------|-------|
| Appearance | Light | Light (proven `light/commands-restore-proof.png` + `AppleInterfaceStyle` absent) |
| `hasCompletedOnboarding` | 1 | 1 (untouched) |

## F.0 capture matrix (installed 4.0.5 / 94)

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
| Command Bridge search no-match | command-bridge-search-nomatch.png | command-bridge-search-nomatch.png |
| Command Bridge create sheet | command-bridge-create-sheet.png | command-bridge-create-sheet.png |
| Dashboard | **deferred** (MenuBarExtra; trailing mark is not Dashboard) | **deferred** |
| Onboarding | **deferred** (restore trap not used) | **deferred** |

Footer on Settings captures: `v4.0.5 · build 94`. Advanced About: `4.0.5 (94)`.

## Critique board closeout

| ID | Surface | P | Status after F.0 |
|----|---------|---|------------------|
| CB-1 | Command Bridge | P0 | **closed** — host idle 584×260; create sheet 584×480. Save/Cancel fully visible inside the expanded host in Light and Dark (`v405-chrome/{light,dark}/command-bridge-create-sheet.png`). SwiftUI Save/Cancel are not AX-titled (`ax_inspect title=Save` count 0); visual + CGWindow height are the close. |
| CB-2 | Command Bridge | P2 | still deferred (Name + body still echo the query) |
| remaining P3s | Settings | P3 | still deferred |

Open P0/P1: **none**. Last loop id: Track A loop 1.

## Demo Gate (installed 4.0.5 / 94)

| Surface | Evidence | Verdict | Notes |
|---------|----------|---------|-------|
| Dashboard | — | **deferred** | MenuBarExtra popover; capture-method, not a product P0 |
| Command Bridge (search + create) | v405-chrome light+dark command-bridge-*.png | **PASS** | ⌃⌘B opens; no-match + Create via ⌥↩; host expands 260→480; Save/Cancel on-canvas; Esc drops draft |
| Commands Settings | v405-chrome/{light,dark}/commands.png | **PASS** | hint copy present; 13 commands / 10 favorites; v4.0.5 · 94 |
| Security | v405-chrome/{light,dark}/security.png | **PASS** | Vault + license readable in both appearances |
| Connection | v405-chrome/{light,dark}/connection.png | **PASS** | endpoint / handshake / clients coherent |
| Memory | v405-chrome/{light,dark}/memory.png | **PASS** | memos list + empty preview; no chrome breakage |
| Onboarding welcome | — | **deferred** | `hasCompletedOnboarding=1`; no Reset Onboarding |
| Search C1 | F.0 receipt | **PASS** | ordinary Return with probe query left host at 260; sheet opened only after ⌥↩ |
| #129 | code path unchanged | **PASS** | not reopened; no NSPasteboard on fire path this campaign |
| Tools filter ≠ Search | light/tools.png | **PASS** | family chips + “Search 224 tools…” — not Command Bridge Search |

**Demo Gate:** **PASS** with Onboarding + Dashboard deferred with reason.

## Staged candidates retained

- `.build/candidates/main-f4a7d4e/` (4.0.4 / 93)
- `.build/candidates/rollback-27cfcbe/`
- `.build/candidates/main-b9e1c8b/` (4.0.5 / 94 UI SHA)

## Sparkle 4.0.5 — Released Verified

| Artifact | Value |
|---|---|
| Tag | annotated `v4.0.5` → `b9e1c8b4af997fc07093ce22d4209980939cfdb5` |
| GH release | published, not draft — https://github.com/KUP-IP/the-bridge/releases/tag/v4.0.5 |
| Actions | run [32202976643](https://github.com/KUP-IP/the-bridge/actions/runs/32202976643) **success** (test 9m3s + notarize 17m17s) |
| Feed | `origin/main` `appcast.xml` `sparkle:version` **94**, enclosure `the-bridge-v4.0.5.dmg` length 24076637 |
| Appcast commit | `5517279` `release(v4.0.5): publish Sparkle appcast for v4.0.5 [skip ci]` |
| `make verify-sparkle-feed` | **PASS** — feed HTTP 200, enclosure HTTP 200, Content-Length matches |
| Prior 4.0.4 | tag + GH release **retained**. Feed is single-item (CI `generate_appcast` shape, same as 4.0.4). Clients on 93 are offered 94. |

Installed app, tag SHA, and appcast agree on **4.0.5 / 94**. Build 93 was never reused. Appcast was not hand-edited.

---

# Local 4.0.5 / 94 insert install (2026-08-19)

**Not Sparkle.** `ALLOW_NON_MAIN_INSTALL=1 make install-copy` from feat worktree `feat/v405-local-insert-ui`. Feed still 4.0.5 / 94; About SHA does **not** match tag `v4.0.5`. Do not Check for Updates (notarized 94 would wipe this binary).

| | |
|---|---|
| Installed | 4.0.5 (94) · dirty false · `BridgeGitSHA` `7b10b2cdfd4354e94c2a511100e8b3cda103f86f` |
| Worktree | `/Users/keepup/Developer/worktrees/the-bridge/feat-v405-local-insert-ui` — keep until a later Sparkle GO |
| Canonical main | `/Users/keepup/Developer/the-bridge` @ `633b2ba`, clean |
| Floor | 3761 → **3763** (+2 Electron keyDown policy + C1 name-only empty body) |
| Product commit | `7b10b2c` `fix: land Cursor insert once and stop echoing search into command body` |

## Blocking smoke

| Check | Result | Evidence |
|---|---|---|
| Cursor `review` (Ship Gate, slot 9) | **PASS** — one body | Composer 24px/`Send follow-up` → 733×200 / len **1462**, prefix `Ship Gate`. Clipboard unchanged (`nb-pkt-765-persist-9B552D93-07D2-4538-8DF7-B04EB8F2DCC6`). Draft cleared after read. |
| Notes insert | **PASS** — one body | AXTextArea 39 → **1487** chars; one `Ship Gate`. Clipboard unchanged. |
| C1 ordinary Return | **PASS** | No-match `zzzmokecb2`; host stayed **584×260**; 13 command files unchanged. |
| CB-2 ⌥↩ create | **PASS** | Host **584×480**; name `zzzmokecb2`; placeholder `Body (optional)`; body AXTextArea empty. Esc → 260; no file saved. |
| #129 clipboard | **PASS** | `pbpaste` identical before/after Cursor and Notes fires. No NSPasteboard on the fire path. |

## P3s (best-effort, Light; not recaptured)

SEC-2 Open/Notify/Request labels, CMD-1 footer removed, SK-2 one-line palette caption, CON-2 handshake `fg5`→`fg4`. Still deferred: CON-1, MEM-1, DS-1, ADV-1, Dashboard, Onboarding.

## Staged candidates retained

`.build/candidates/main-f4a7d4e/` · `rollback-27cfcbe/` · `main-b9e1c8b/`



