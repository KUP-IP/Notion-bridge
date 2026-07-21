# Bridge Settings UI-ITER — Wave A

**SHA base:** `7a13c67` · **Branch:** `feat/ui-iter` · **Installed at audit:** 3.9.9 / 81  
**Evidence:** `docs/operator/uiiter/captures/*.png` · A.0 PASS (Security)

## A.0 Capture smoke
- Triad: `bridge_open_settings` → `bridge_settings_navigate(Security)` → `bridge_focus_settings` → `screen_capture` window `kup.solutions.the-bridge`
- Result: Settings Security visible (sidebar + Vault). **PASS**

## Master critique board (Light, first pass)

| ID | Surface | P | Finding | Visual evidence | Status |
|----|---------|---|---------|-----------------|--------|
| SK-1 | Skills | P1 | Group caption wraps; stray letter under count (`ROUTING & ORCHESTRATORS` + `8`) | skills.png — caption line break | fixed (lineLimit+truncation+layoutPriority) — pending F.0 re-verify |
| JOB-1 | Jobs | P2 | Duplicate pause signal: mono `paused` + badge `Paused` | jobs.png — trailing grid | fixed (paused → `—`; badge keeps status) — pending F.0 re-verify |
| SEC-1 | Security | P2 | `USED BY no tools registered` in error-red for every vault row (reads as failure) | security.png — credential cards | fixed (orphan chip `.bad`→`.info`) — pending F.0 re-verify |
| SEC-2 | Security | P3 | GATES cluster digits unlabeled | security.png — hero | defer |
| CMD-1 | Commands | P3 | Stats `12 commands · 10 favorites` repeated (hero + list footer) | commands.png | defer |
| SK-2 | Skills | P3 | Tall palette empty-state banner competes with index | skills.png — top banner | defer |
| CON-1 | Connection | P3 | Live count 47 vs sessions 48 (data, not chrome) | connection.png | defer (data) |
| CON-2 | Connection | P3 | Runtime meta line micro-contrast | connection.png — runtime card footer | defer |
| MEM-1 | Memory | P3 | Empty preview pane sparse (acceptable empty state) | memory.png | defer |
| DS-1 | Data Sources | P3 | Last card clipped at window bottom (scroll expected) | data-sources.png | defer |
| ADV-1 | Advanced | P3 | Network Save vs field height micro-mismatch | advanced.png | defer |
| TOOLS-1 | Tools | — | No P0/P1; family list readable | tools.png | clean |

**P0:** none.

## Visual DoD checklist (Wave A)
- [ ] Section headers consistent
- [ ] Empty states present when empty
- [ ] No clipped primary CTAs
- [ ] Hairline/token grammar OK
- [ ] Light+Dark on Security / Connection / Memory (Dark TBD this wave if time)

## Pass notes
- Pass 1 (structure): SK-1, JOB-1, SEC-1 code landed in worktree (`feat/ui-iter`) — not yet installed / re-captured.
- Pass 2: blocked until Agent mode (install-copy → triad re-capture → Demo Gate → `make test-floor`).
- SEC-1 chose `.info` (not new `.warn` variant) — compiles without `BridgeThemeV2` change; softer than red, still not amber. Acceptable Wave A; optional `.warn` deferred.

## Checkpoint (Execute interrupted)
Parent still in **Plan mode** after mode-switch reject — cannot `make install-copy` / re-capture / test from this session until Agent is approved.
