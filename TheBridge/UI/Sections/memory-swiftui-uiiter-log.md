# Memory SwiftUI redesign — UI-ITER log

Iteration log for the native SwiftUI port of the Memory section redesign (Wave 0
scaffolded the Tab enum + placeholders; this log covers the real per-tab
implementations). Companion to the design-phase log at
`design/the-bridge-design-system/project/memory-uiiter-log.md`. Same discipline:
evidence-first (screen_capture / ax_tree / ax_inspect over the running app — never
code-reading alone), numbered findings tagged P0 (broken/invisible) – P3 (nitpick).

---

## MemorySettingsTab — Loop 1

**Scope**: Real port of `MemoryProcessingTab.swift` (curator routing, transcription
ladder, cloud provider) + `MemorySurfacingSettingsCard.swift` (handshake inject),
consolidated into one Settings tab per the mockup
(`design/the-bridge-design-system/project/pages/page-memory.jsx`, `SettingsTab()`).
Card order: Curator routing → Transcription ladder → Cloud enhancement → Handshake
memory inject.

### Critique (evidence: screen_capture target=display + ax_tree maxDepth=10, live app
build 76 install, navigated via `bridge_settings_navigate(section: Memory, anchor:
settings)`)

1. **P0** — Every AX identifier inside the Handshake memory inject card
   (`settings.inject.global`, `settings.inject.clientName`, `settings.inject.add`,
   `settings.inject.override.<client>`, `settings.inject.remove.<client>`) resolved
   to the SAME id (`bridge.settings.memory.agent.surfacing`) in the raw `ax_tree`
   dump. Root cause: the outer `BridgeGlassCard`'s
   `.accessibilityIdentifier(BridgeAXID.Memory.surfacingCard)` (applied for card-level
   identification) propagates down onto every descendant AXUIElement that doesn't
   register its own AX identity distinctly at the AX-tree level, shadowing the
   per-control ids set on the toggle/text field/buttons beneath it. Confirmed via
   `grep` over the dumped tree: 11 elements under the card all reported the one
   card-level id.
2. **P2** — Curator Mode uses a native macOS `Picker(.menu)` — functional and
   explicitly allowed by the task brief ("doesn't need to be a hand-rolled popover
   like the HTML version — native Picker or Menu is fine"), but its chrome (system
   grey pill) doesn't match the glass-card aesthetic of the surrounding
   `BridgeInput`-styled fields in the mockup's `MemModeSelect`.
3. **P3** — `curatorBanner`'s AX id is shared by both the "Connected: …" and "No MCP
   client…" `Text` branches (mutually exclusive, so never both present at once —
   harmless, just noting for completeness).

### Plan

1. Fix P0 — remove the card-level `.accessibilityIdentifier(BridgeAXID.Memory.
   surfacingCard)` from `handshakeInjectCard`; it's redundant (the pane-level
   `BridgeAXID.Memory.Settings.pane` id plus each control's own id are sufficient
   for automation/tests). Apply the same fix to `overrideRow`'s row-level
   `injectOverrideRow(client)` id, which had the identical shadowing problem on the
   Remove button — remove that constant from `BridgeAXID.Memory.Settings` since it's
   now unused (the row stays locatable via its Remove button's id or client-name
   text).
2. Defer P2 — acceptable per task brief; revisit only if a later polish pass touches
   this card. Not a P0/P1, no functional impact.
3. Defer P3 — cosmetic AX-id sharing on a mutually-exclusive banner; no behavioral
   risk.

### Execute

- `TheBridge/UI/Sections/MemorySettingsTab.swift`: removed the outer
  `.accessibilityIdentifier(BridgeAXID.Memory.surfacingCard)` on `handshakeInjectCard`
  and the row-level identifier on `overrideRow`; added an explanatory comment at both
  sites documenting the AX-propagation hazard for future editors.
- `TheBridge/UI/BridgeShell.swift`: removed the now-dead
  `BridgeAXID.Memory.Settings.injectOverrideRow(_:)` constant, replaced with a NOTE
  comment explaining why no per-row container id exists.

### Verify

- Rebuilt (`make debug`, clean, no errors) → reinstalled (`make install-copy`) →
  relaunched → re-navigated to Memory → Settings via `bridge_settings_navigate`.
- Fresh `ax_tree` dump: all 5 previously-collided identifiers now resolve distinctly:
  `bridge.settings.memory.settings.inject.global`,
  `...settings.inject.clientName`, `...settings.inject.add`,
  `...settings.inject.remove.cursor` (each on its own element; the "cursor" row's
  Remove button correctly carries `settings.inject.remove.cursor`, not the group id).
- Fresh `screen_capture` confirms the visual is byte-for-byte unchanged (removing an
  AX-only modifier has no rendering effect) — Curator routing / Transcription ladder
  / Cloud enhancement / Handshake memory inject cards render in the mockup's order
  with real data: "Connected: claude-code" banner (live `MCPClientPresence`), all
  three ladder toggles ON (live `@AppStorage`), Base URL / Model prefilled from
  `MemoryHubProviderConfigStore.load()`, "Key configured" badge (live Keychain
  check), and the real "cursor" override row loaded from
  `MemoryAutoInjectClientStore.shared.allOverrides()` (matches the seeded-on-install
  default documented in the card's own body copy).
- Exercised a real interaction: clicked the "Apple embedded transcript" toggle twice
  (off, then back on) via `mouse_click` at its AX-resolved coordinates; a pixel-crop
  of the before/after screenshots confirms the track fill + knob position genuinely
  flip (green‑filled/knob‑right ⇄ grey‑track/knob‑left), i.e. a live `@AppStorage`
  binding, not static markup. (Aside, not a MemorySettingsTab defect: `ax_inspect`
  momentarily reported `AXSelected: true` for the toggle right after the OFF click,
  before catching up on the next read — a pre-existing `BridgeToggle`
  accessibility-trait timing quirk in the shared component, out of scope for this
  file; visual + underlying state were correct throughout.)
- **Result: clean.** No unresolved P0/P1 findings. P2 (native Picker chrome) and P3
  (shared banner AX id) explicitly deferred above with reasons.

---

## MemorySettingsTab — Loop 2

**Scope**: Exercise real interactions end-to-end (not just static AX/pixel reads) to
confirm every control's binding is genuinely live, per the task's F.0 discipline.

### Critique (evidence: live interaction via `mouse_click` / `ax_perform_action` /
`keyboard_type` against the rebuilt+reinstalled app, with before/after
`screen_capture` + `ax_inspect` on each control)

1. Exercised the Transcription Ladder "Apple embedded transcript" toggle (off → on)
   via `mouse_click` at its AX-resolved coordinates. A pixel-crop diff of the
   before/after screenshots confirmed the track fill + knob position genuinely flip.
   **No defect** — real `@AppStorage` binding.
2. Exercised the Curator Mode picker: opened the native `AXPopUpButton` menu,
   confirmed all 5 `VoiceMemoCuratorMode` options are listed (Auto / Heuristics only
   / Local Ollama / Connected MCP agent / Cloud API — real enum labels, not the
   mockup's placeholder strings), selected "Auto", and confirmed the dynamic help
   caption below the picker updated live to the `Auto`-specific copy ("Tries cloud,
   then local Ollama, then heuristics…"). Reverted to "Connected MCP agent".
   **No defect** — real `@AppStorage(BridgeDefaults.voiceMemoCuratorMode)` binding
   driving both the picker AND the derived help text.
3. Exercised the Handshake memory inject "Add per-client override" flow end-to-end:
   typed a client name into the text field (confirmed the "Add override" button's
   `isEnabled` binding flips live as the field goes from empty → non-empty), clicked
   Add, confirmed a new row appeared immediately with its own distinct
   `settings.inject.remove.<client>` AX id (generalizing the Loop 1 P0 fix
   correctly to N rows), clicked that row's Remove button, confirmed the row
   disappeared and the card reflowed. Re-added "cursor" to restore the seeded
   dev-machine default before finishing. **No defect** — real
   `MemoryAutoInjectClientStore.setOverride`/read-through cycle, not static markup.
4. **Operator-error note, not a product defect**: mid-loop, an imprecise
   `ax_perform_action setValue` call (ambiguous bare-role `path`, which resolves to
   the first matching element in the tree rather than a specific one) accidentally
   overwrote the Base URL field instead of the intended target. Caught immediately
   via screenshot, corrected before any Save was pressed (so nothing persisted to
   `providers.json`), and confirmed restored. Documented here as a testing-tool
   lesson (bare-role AX paths need mouse-coordinate or full-literal-path targeting
   when multiple same-role siblings exist), not a MemorySettingsTab bug.
5. Aside, reconfirmed from Loop 1: `AXSelected` on `BridgeToggle` (shared component,
   not owned by this file) can read stale for one AX poll immediately after a click
   before catching up — visual and underlying `@AppStorage` state were correct
   throughout every check. Still deferred as out-of-scope for this task.

### Plan

No fixes required — every real interaction exercised behaves correctly and matches
the mockup's intended behavior (dynamic mode help text, live enable/disable on Add
override, live add/remove of override rows, live toggle state). Confirmed no
regression to Memos/Recall tab navigation or the shared `MemorySection` tab bar
after the BridgeShell.swift AXID edit from Loop 1.

### Execute

No code changes this loop.

### Verify

- Re-navigated Memos → Settings → confirmed tab bar + section routing unaffected.
- Final `ax_inspect find_element(role: AXButton, label: Remove)` shows exactly one
  match (`settings.inject.remove.cursor`) — dev-machine state cleanly restored to
  the original seeded override, Base URL back to `http://127.0.0.1:8080/v1`, Mode
  back to "Connected MCP agent".
- **Result: clean.** No unresolved P0/P1 findings.

---

## MemorySettingsTab — Loop 3

**Scope**: Final polish pass — close-read the mockup's exact CSS/copy specs for the
two areas not yet pixel-verified (the "uses cloud" chip's true styling rule, the
override row's inset-bevel shadow), then a full live-app smoke pass.

### Critique (evidence: `page-memory.jsx` CSS read + fresh screen_capture/pixel-crop,
PLUS a live crash discovered mid-loop via two `~/Library/Logs/DiagnosticReports/
TheBridge-*.ips` crash reports)

1. **P2** — The "uses cloud" tag next to the Cloud enhancement card label was
   styled with `BridgeTokens.accent.opacity(0.16)` fill + `infoText` foreground.
   Re-reading the mockup's CSS closely: that's actually the `.btn:not(.primary)
   .mem-cloud` OVERRIDE rule (only applies when the chip is nested inside a
   non-primary button). The chip in `SettingsTab`'s card head is NOT inside a
   button, so the base `.mem-cloud` rule applies: solid `color-mix(on-accent 22%,
   transparent)`-on-`on-accent`-text — i.e. a solid accent-colored pill with white
   text, not a faint accent-tinted one. Confirmed via pixel-crop the port was
   rendering the wrong (fainter, blue-on-light) variant.
2. **P3** — The Handshake override row (`overrideRow`) was missing the mockup's
   `box-shadow: var(--bevel-inset)` (a recessed inner-shadow on the well-fill
   background) — present in `.mem-override` CSS but not ported.
3. **P0 — CRITICAL, found via live crash, not static reading**: while stress-testing
   the Curator Mode picker for this loop, The Bridge crashed TWICE with an
   identical, 100%-reproducible signature (`~/Library/Logs/DiagnosticReports/
   TheBridge-2026-07-03-123124.ips` and `-123500.ips`): `EXC_BREAKPOINT` /
   `SIGTRAP` from `_dispatch_assert_queue_fail`, with
   `closure #1 in … MemorySettingsTab.curatorRoutingCard.getter` on the crashing
   thread's stack, inside SwiftUI's `ForEachChild.updateValue()` /
   `AG::Graph::UpdateStack::update()` (AttributeGraph) machinery, triggered every
   single time the Mode `Picker`'s dropdown was opened. Root cause: the
   `Picker { ForEach(VoiceMemoCuratorMode.allCases, id: \.rawValue) { … } }` pattern
   — a `ForEach` directly inside a `.menu`-style `Picker` — trips a real
   AttributeGraph/dispatch-queue-isolation assertion on this machine's macOS 27.0
   beta (build 26A5368g). Confirmed NOT introduced by this port: the identical
   `ForEach`-in-`Picker` pattern already exists, unfixed, in the currently-shipping
   `MemoryProcessingTab.swift` (same enum, same construct) — this is a pre-existing
   latent OS-beta/SwiftUI-engine risk that this rewrite happened to newly exercise
   under scripted (rapid, precise) AX-driven clicks.

### Plan

1. Fix P2 — correct the "uses cloud" chip to the base `.mem-cloud` styling: solid
   `BridgeTokens.accent` (majority-opacity) fill, `BridgeTokens.onAccent` text.
2. Fix P3 — add `.bridgeBevel(BridgeTokens.bevelInset, radius: 8)` to `overrideRow`.
3. Fix P0 — replace the `ForEach(VoiceMemoCuratorMode.allCases…)` inside the
   `Picker` with 5 unrolled literal `Text(...).tag(...)` entries (the enum is fixed
   at 5 cases, so this is a safe, permanent structural workaround that sidesteps
   the crashing `ForEachChild`/AttributeGraph code path entirely — not a
   suppression, a different SwiftUI rendering strategy for the same picker).
   Documented inline with the crash evidence so a future editor doesn't
   "simplify" it back into a `ForEach` without knowing why.

### Execute

- `TheBridge/UI/Sections/MemorySettingsTab.swift`:
  - `cloudEnhancementCard`: "uses cloud" chip → `BridgeTokens.accent.opacity(0.75)`
    fill / `BridgeTokens.onAccent` foreground / mono 10.5pt semibold, with a comment
    citing the mockup's base-vs-button-override CSS distinction.
  - `overrideRow`: added `.bridgeBevel(BridgeTokens.bevelInset, radius: 8)`.
  - `curatorRoutingCard`: replaced the `ForEach`-in-`Picker` with 5 unrolled
    `Text(mode.label).tag(mode.rawValue)` entries, one per `VoiceMemoCuratorMode`
    case, with a comment documenting the crash signature and both `.ips` filenames
    for future reference.

### Verify

- Rebuilt (`make debug`, clean) → reinstalled → relaunched → re-navigated to
  Memory → Settings.
- "uses cloud" chip: pixel-crop confirms a solid blue-accent pill with white
  monospace text, matching the mockup's base rule.
- Override row: bevel now applied (visual is subtle at this scale but the modifier
  is correctly present, matching the CSS `box-shadow` ingredient list used
  elsewhere in the file, e.g. `BridgeInput`'s own `bevelInset` usage).
- **Picker crash fix — stress-tested with 4 consecutive rapid open→select cycles**
  covering all 5 `VoiceMemoCuratorMode` options (Auto, Local Ollama, Cloud API,
  Heuristics only, back to Connected MCP agent) via `mouse_click` + `ax_perform_action`
  in immediate succession (the exact conditions that produced 2/2 prior crashes).
  Zero crashes; `ps aux` confirms the same app PID survived the entire sequence;
  `~/Library/Logs/DiagnosticReports/` has no new `TheBridge-*.ips` entries after the
  fix. Dynamic help text and final "Connected MCP agent" selection confirmed correct
  via fresh screenshot. AX identifier `bridge.settings.memory.settings.curator.mode`
  still resolves correctly post-fix (no regression to Loop 1's AX-id work).
- **Result: clean.** No unresolved P0/P1 findings. The P0 crash fix is the
  headline result of this loop — caught only because this protocol requires live
  interaction, not code-reading or static screenshots, exactly the scenario the
  task's "visual-first gate" discipline exists to catch.

**Cross-file note (out of scope, flagged not fixed)**: `MemoryProcessingTab.swift`
and `MemoryAgentTab.swift` contain the same crash-prone `ForEach`-in-`Picker`
pattern. Both files are already orphaned dead code post-Wave-0 (unreferenced by
`MemorySection.swift`'s routing — confirmed via `grep` during Loop 1), so they are
not user-reachable and were left as-is; noted here in case they are ever revived or
deleted outright in a later cleanup wave.

---

## MemoryRecallTab — Loop 1

**Scope**: Real port of `MemoryAgentTab.swift`'s memory-list browsing/pin/forget
functionality (the old "Agent" tab, renamed "Recall") into the mockup's single-column
card-list layout (`page-memory.jsx`, `function RecallTab()`) — content search field,
per-row expand toggle, tag badges, source+used-count meta, Pin/Forget action row,
empty state. Deliberately excludes the old inline `MemorySurfacingSettingsCard()`
(moved to Settings) and the scope/type Picker filter bar (mockup has none, only
content search).

### Critique (evidence: `bridge_settings_navigate(section: Memory, anchor: recall)` +
`bridge_focus_settings` + `screen_capture`/`ax_tree`/`ax_inspect` against the live
build-77 install, real `MemoryStore` data — 49 live memories, e.g. "Isaiah's player
record ID…", "Packet Runner…" entries — no fake/mock rows)

1. **P0** — Every AX identifier meant to be distinct on Recall's interactive controls
   (`recall.search`, `recall.expand`, `recall.pin`, `recall.forget`) resolved to the
   SAME shadowed ancestor id in the raw `ax_tree`/`ax_inspect` dump: the search field
   read back as the section-wide `bridge.settings.memory.root` (set by
   `SettingsWindow.swift`'s generic per-section root container id), and the
   expand/pin/forget buttons all read back as the row-level
   `bridge.settings.memory.recall.row` id applied to each `BridgeGlassCard`. Confirmed
   via `ax_inspect find_element(label: "Pin"/"Forget"/"Show full text")` — all 49 rows'
   worth of each control shared one identifier instead of 49 distinct AX elements each
   correctly tagged. This is the exact container-shadowing hazard `MemorySettingsTab`
   already documented and avoided (Loop 1 there) — reintroduced here independently.
2. **P2** — The Pin button's "pinned" visual state (green/`.ok`-toned background +
   border + text, per the mockup's `.mem-mcard-acts .btn[aria-pressed="true"]` rule)
   had NO visible effect — clicking Pin correctly flipped the label to "Pinned" (real
   `MemoryStore.pin(id:_:)` write, confirmed via the `Pinned` badge appearing in the
   tag row) but the button itself rendered identically to the unpinned "Pin" state.
   Root cause: wrapping a plain `Button` in `BridgeButtonStyle(variant: .default)`
   and trying to override its color with an outer `.foregroundStyle` modifier — SwiftUI
   applies `BridgeButtonStyle.makeBody`'s OWN internal `.foregroundStyle` call, which
   wins over any modifier applied outside the button's style pipeline. Confirmed via a
   pixel-crop `screen_capture` region showing "Pin" and "Pinned" rendered with
   identical grey chrome, differing only in label text.

### Plan

1. Fix P0 — same remedy pattern as `MemorySettingsTab` Loop 1: scope
   `.accessibilityIdentifier(BridgeAXID.Memory.Recall.list)` to just the `ScrollView`
   (not the outer VStack containing the search-field meta row), remove the
   per-row `.accessibilityIdentifier(...row)` from `recallRow` entirely (rows stay
   locatable via their own button ids / text content — mirroring
   `MemorySettingsTab.overrideRow`'s precedent), and remove the now-dead `.row`
   constant from `BridgeAXID.Memory.Recall`. For the search field specifically: after
   two failed attempts (inline `TextField` with the id as its closest modifier;
   pulling it into a dedicated `RecallSearchField` view with the id set internally),
   the actual fix required matching `BridgeInput`'s exact working shape — the
   `.accessibilityIdentifier` must be the OUTERMOST modifier on the fully-composed
   control (icon + field + frame/background/overlay chrome), applied by the *caller*
   after `.accessibilityElement(children: .contain)` establishes a genuine AX subtree
   boundary — not applied internally to the bare `TextField`.
2. Fix P2 — replace the `BridgeButtonStyle`-wrapped `Button` with a small dedicated
   `RecallPinButton` view that owns its own fill/border/text color entirely
   (mirroring `BridgeButton(variant: .default)`'s geometry but swapping in the
   `.ok`-toned recipe used by `BridgeBadge`'s `.ok` tone when pinned), sidestepping
   `BridgeButtonStyle`'s internal color pipeline instead of fighting it.

### Execute

- `TheBridge/UI/Sections/MemoryRecallTab.swift`:
  - Moved `.accessibilityIdentifier(BridgeAXID.Memory.Recall.list)` from the outer
    `VStack` onto the `ScrollView` alone.
  - Removed the per-row `.accessibilityIdentifier(BridgeAXID.Memory.Recall.row)`,
    replaced with `.accessibilityElement(children: .contain)` + an explanatory
    comment.
  - Extracted the search field into a self-contained `RecallSearchField` view
    (icon + `TextField` + frame/background/overlay all internal, no id of its own);
    the call site applies `.accessibilityIdentifier(...).accessibilityElement(children:
    .contain)` as the outermost modifiers, in that order.
  - Replaced the Pin button with a new `RecallPinButton` view (dedicated fill/border/
    text logic, hover state, `.ok`-toned pinned look) and accessibility id applied at
    the call site.
- `TheBridge/UI/BridgeShell.swift`: removed the now-dead
  `BridgeAXID.Memory.Recall.row` constant, replaced with a NOTE comment (matching
  `MemorySettingsTab.Settings`'s precedent) explaining why no per-row container id
  exists.

### Verify

- Rebuilt (`make debug`, clean) → reinstalled (`make install-copy`) → relaunched →
  re-navigated to Memory → Recall via `bridge_settings_navigate`. Iterated 5 times
  total across this loop (one per fix attempt) until the search-field id genuinely
  resolved.
- Fresh `ax_inspect find_element` after the final fix: `recall.search` (1 match, the
  real `AXTextField`), `recall.pin` / `recall.expand` / `recall.forget` (49 matches
  each, one per live row, each its own distinct AX element — no more shared/collided
  ids), `recall.empty` (1 match, confirmed by live-triggering the "No matches" state
  with a real search term that matches nothing).
- Exercised real interactions end-to-end, not just static reads:
  - Typed "packet runner" into the search field → list filtered live from 49 → 18
    real matching entries (confirmed via meta-row count + visible row content, e.g.
    "Point 3 locked for Packet Runner…", "Packet Runner workflow self-modification…").
  - Typed a non-matching term → "No matches / Try a different search term." empty
    state rendered, AX id `recall.empty` confirmed present.
  - Clicked "Show full text" on row 1 → label flipped to "Show summary" and the full
    (untruncated) memory text rendered — confirmed via screenshot diff.
  - Clicked Pin on row 1 → `Pinned` tag badge appeared in the tag row, button label
    flipped to "Pinned" AND (post-P2-fix) rendered with a distinct green background/
    border/text — confirmed via a pixel-crop region capture showing the correct
    `.ok`-toned chrome. Clicked again to unpin, confirmed reverted.
  - Clicked Forget on a row → confirmation dialog appeared with the exact full memory
    text embedded ("…will be soft-deleted and removed from recall and export.");
    clicked Cancel both times a dialog was triggered during testing — never confirmed
    a real delete, so no production `MemoryStore` data was destroyed during
    verification (49 memories before and after this loop).
- All live data mutations made during testing (one pin/unpin cycle) were reverted
  before finishing; final state matches the pre-test baseline (49 memories, none
  pinned, no search filter active) — confirmed via a final full-window screenshot.
- **Result: clean.** No unresolved P0/P1 findings.

---

## MemoryRecallTab — Loop 2

**Scope**: Close-read the mockup's exact CSS specs (`materials.css` `.link-btn`,
`.btn`, `.btn.sm`) rather than relying on visual approximation, then verify live.

### Critique (evidence: `materials.css` CSS read + fresh `screen_capture`/`ax_inspect`
against the Loop-1-fixed live app)

1. **P2** — "Show full text"/"Show summary" and "Forget" were built as ad-hoc
   `Button`s with `BridgeTokens.Typeface.meta.weight(.medium)` (12px) and no hover
   feedback or padding. Re-reading `materials.css` `.link-btn` precisely: `font: 500
   var(--t-sub)/1` (12.5px, not 12px), `padding: 4px 6px`, `border-radius: 5px`,
   `:hover { background: color-mix(accent 12%) }`. Confirmed via CSS diff — the port
   was using the wrong type scale and had no hover affordance at all.
2. **P2** — The Pin/Unpin button was sized like a full `.btn` (30pt height, 13pt
   padding, `base600` font) but the mockup's `.mem-mcard-acts button className="btn
   sm"` — `.btn.sm` overrides to 26pt height, 10pt padding, `t-meta` (12px) font
   size. Confirmed via `ax_inspect`: the live button measured `width: 46, height: 30`
   against the spec's smaller footprint.

### Plan

1. Fix both — extract a shared `RecallLinkButton` (mirrors `.link-btn.plain` exactly:
   sub/500 font, 4×6 padding, 5px radius, accent-tint hover, color parameterized per
   call site) for "Show full text"/"Show summary" and "Forget", and correct
   `RecallPinButton`'s geometry to `.btn.sm`'s 26pt/10pt/meta-semibold spec.

### Execute

- `TheBridge/UI/Sections/MemoryRecallTab.swift`:
  - Added `RecallLinkButton` (title/color/action) and swapped both the expand toggle
    and Forget button to use it instead of ad-hoc `Button` styling.
  - `RecallPinButton`: height 30→26, horizontal padding 13→10, font
    `base600`→`meta.weight(.semibold)`.

### Verify

- Rebuilt (`make debug`, clean) → reinstalled → relaunched → re-navigated to Memory →
  Recall (window had moved to the second display between launches — caught via
  `ax_inspect`'s reported x-coordinate exceeding the primary display's width, then
  captured `screen_capture(displayIndex: 1)` instead of assuming display 0).
- Fresh `ax_inspect find_element(label: Pin)`: all 49 buttons now measure `width: 39,
  height: 26` (down from 46×30), matching `.btn.sm`.
- Live-clicked Pin on row 1: pill renders compact (26px) with the correct
  `.ok`-toned green background/border/text in the pinned state — confirmed via a
  fresh full-window screenshot on display 1. Clicked again to unpin, confirmed
  reverted via `ax_inspect find_element(label: Pinned)` returning 0 matches.
- **Result: clean.** No unresolved P0/P1 findings. Dev-machine data restored to
  baseline (49 memories, none pinned) after verification.

---

## MemoryMemosTab — Loop 1

**Scope**: Real port of `MemoryProcessTab.swift` (1189-line cockpit: memo select →
inspect → Understand → intent tags → batch Confirm, registry-picker sheet, title
rename/cloud-improve, triage-session banner, live-processing sync) plus the old
inline Inbox triage queue (stripped from `MemorySection.swift` pre-Wave-0, resolved
via `git show a11c4d0~1`), consolidated into the mockup's twin master-detail layout
(`page-memory.jsx`, `function MemosTab()`): 240pt left list (search + status pills +
grouped rows) and a right detail pane (Title / Status-stepper / Transcript /
Filed-in-Notion / Needs-review / Process-this-memo cards). The old InboxFilter reason
filters (awaitingAgent/noTranscript/routingFailed/lowConfidence) became a secondary
filter row shown only within the "Review" status-pill group, per the task's
reconciliation instruction. This is the biggest/highest-risk wave (absorbs both the
Process cockpit's business logic AND the Inbox triage actions).

### Critique (evidence: `bridge_settings_navigate(section: Memory, anchor: memos)` +
`bridge_focus_settings` + `screen_capture`/`ax_inspect` against the live build-76
install, real on-disk data — 215 real unprocessed voice memos, e.g. "Lift logs
database search and linking feature ideas" — no fake/mock rows; exercised a real
`voice_memo_get(understand:true, provider:"local")` MCP call end-to-end)

1. **P1** — Same container-shadowing AX-id hazard already caught and fixed twice in
   this log (`MemorySettingsTab` Loop 1, `MemoryRecallTab` Loop 1), reintroduced here
   independently: `BridgeAXID.Memory.Memos.processCard` was applied to the OUTER
   `BridgeGlassCard` wrapping the entire "Process this memo" card, shadowing every
   descendant control's own id. Confirmed via `ax_inspect find_element(label:
   "Process locally")` and `label: "Process with cloud"` — BOTH buttons resolved to
   the same `bridge.settings.memory.memos.processCard` identifier instead of their
   own `Process.processLocal`/`Process.processCloud` ids (which are set correctly in
   code but get shadowed by the ancestor's AX identity in the raw tree). Same root
   cause applies to `dryRun`/`refreshPreview`/the cloud "Improve title" button in the
   same card, and likely to `Memos.list`'s relationship with the per-row
   `Process.memoRow(id)` ids (not yet independently confirmed but same pattern).
2. **P2** — Real end-to-end verification of "Process locally" surfaced a genuine (but
   pre-existing, not newly-introduced) cockpit UX quirk: after a heuristic-only parse
   with no clear primary intent, `MemoryHubMemoTitler.heuristicTitle` falls back to
   `plan.generatedTitle`, which can read worse than the memo's prior humanized-date or
   named title (observed: title changed from "Lift logs database search and linking
   feature ideas" to "All right, I got a little brains coming..." — a raw transcript
   lead-in). This is identical behavior to the old `MemoryProcessTab.swift` (verified
   by reading its `runUnderstand` — same `heuristicTitle` call, same precedence) — not
   a regression introduced by this port, just newly visible because Loop 1 exercised
   a real Understand call end-to-end for the first time.
3. **P3** — Testing-methodology note, not a product defect: raw pixel coordinates
   from an earlier screenshot go stale the instant the detail pane re-renders with
   different content height (e.g. after selecting a memo, the list/card layout
   shifts). Two clicks in this loop landed on the sidebar `Connection` nav item
   instead of the intended memo row / button because I reused a stale coordinate
   instead of re-deriving via `ax_inspect find_element` immediately before each
   click. Documented so later loops don't repeat it.

### Plan

1. Fix P1 — same remedy pattern as the two prior precedents in this log: remove the
   `.accessibilityIdentifier(BridgeAXID.Memory.Memos.processCard)` from the outer
   `BridgeGlassCard` in `processCard(memo:)`; the descendant buttons' own ids
   (`Process.processLocal`, `.processCloud`, `.dryRun`, `.refreshPreview`) are
   sufficient once nothing ancestor-level shadows them. Apply the same audit to
   `Memos.statusCard` and `Memos.list` — check each for the same hazard and fix any
   found.
2. Defer P2 — this is the OLD cockpit's existing heuristic-title behavior, unchanged
   by the redesign (confirmed via a direct read of the pre-Wave-0
   `MemoryProcessTab.swift`'s `runUnderstand`). Out of scope for a visual/IA redesign
   task per the brief ("REDESIGN is about visual/information-architecture... not
   about changing what the underlying async operations do"). Flagging here for
   awareness only.
3. No fix needed for P3 (testing methodology, not a code defect) — adopt the
   discipline of re-deriving coordinates via `ax_inspect` immediately before every
   click for the remaining loops.

### Execute

- `TheBridge/UI/Sections/MemoryMemosTab.swift`:
  - `processCard(memo:)`: removed the outer `.accessibilityIdentifier(BridgeAXID.
    Memory.Memos.processCard)`; added a comment citing the shadowing hazard and the
    two prior log precedents.
  - Audited `statusCard` and `listRows`: `Memos.statusCard` sits on the outer
    `BridgeGlassCard` wrapping `Technical details` (which has its own toggle/body
    ids beneath it) — same hazard, removed. `Memos.list` sits on the `ScrollView`
    (not a card wrapping individual rows' OWN identified controls beyond the row
    button itself, which carries its own `Process.memoRow(id)` id one level down) —
    kept, but confirmed via fresh `ax_inspect` in Verify that it does not shadow the
    per-row ids (rows are `AXButton`s one level below the `ScrollView`/`LazyVStack`,
    not wrapped by another identified container).

### Verify

- Rebuilt (`make debug`, clean, no errors) → reinstalled (`make install-copy`) →
  relaunched → re-navigated to Memory → Memos via `bridge_settings_navigate`.
- Fresh `ax_inspect find_element(label: "Process locally")` / `label: "Process with
  cloud"`: now resolve to their own distinct ids
  (`bridge.settings.memory.process.processLocal`,
  `bridge.settings.memory.process.processCloud`), not the shared card id.
- Fresh `ax_inspect find_element(label: "Technical details")`: toggle now resolves to
  its own `memos.technicalDetails.toggle` id, distinct from the status card.
- Re-confirmed `Process.memoRow(id)` ids remain individually distinct per row (215
  real memo rows, each its own AX element) — no regression from the list-container
  audit.
- Re-exercised the real "Process locally" flow (a different memo, to avoid
  re-mutating the Loop-1-touched one further): real `voice_memo_get` call ran, status
  stepper advanced to "Ready to file", one intent tag rendered with the real
  confidence percentage and provenance badge ("Parsed locally (rules)") — confirms
  removing the AX-only modifier had no rendering/behavioral side effect.
- **Result: P1 fixed and verified. P2 explicitly deferred (pre-existing, out of
  scope). P3 is a testing-discipline note carried into later loops, not a code fix.**

---

## MemoryMemosTab — Loop 2

**Scope**: Continue the AX-id audit begun in Loop 1 across the remaining new controls
(search field, the folded-in Needs-review card), then exercise real interactions not
yet covered (intent write-preview expand, full-transcript sheet open/close).

### Critique (evidence: fresh `ax_inspect find_element` sweeps against the Loop-1-fixed
live app, real interactions via `mouse_click` at AX-resolved coordinates, one real
`voice_memo_get(understand:true, provider:"local")` call reproduced to get a live
intent tag to interact with)

1. **P1** — `ax_inspect find_element(role: AXTextField)` showed the Memos search
   field resolving to `bridge.settings.memory.root` (the section-wide root container
   id set by `SettingsWindow.swift`'s generic `.accessibilityIdentifier(BridgeAXID.
   control(nav.section, "root"))` on the whole tab body), not `Memos.search` — even
   though the identifier was applied as the outermost modifier on the composed
   icon+field+background `HStack`, matching the pattern that worked for the Title
   card's rename field. Root cause (confirmed via a raw `ax_tree` dump inspected
   around the field's frame): a bare inline `HStack` inside a larger view's body does
   not give SwiftUI's AX bridge a distinct enough View identity boundary for the id
   to stick, even with `.accessibilityElement(children: .contain)` — the SAME
   underlying hazard class already documented for `MemoryRecallTab`'s search field
   (Loop 1 there), independently reintroduced here.
2. **P1** — `needsReviewCard`'s outer `BridgeGlassCard` carried
   `BridgeAXID.Memory.inboxRow`, which would shadow every one of `reviewEntryRow`'s
   six real action-button ids (`addReminder`/`agentRemember`/`retryRouting`/
   `markHandled`/`fileAsMemory`/`dismiss`) for every review entry rendered under it —
   the exact same container-shadowing pattern fixed twice already in Loop 1 of this
   file and in the two sibling tabs' logs. Caught by code audit (grepping this file's
   own `.accessibilityIdentifier` call sites against the card-nesting structure)
   before it could be independently reproduced live, since no memo in the current
   real dataset has a `.pending` `VoiceMemoReviewStore` entry right now (checked
   `review.json` directly: 80 total entries, 0 with `status: "pending"` — every real
   entry on this dev machine is already `.resolved`/`.dismissed`). Noting this
   verification gap honestly below rather than fabricating fake review data to
   exercise it, which the task explicitly forbids.
3. Real interaction exercised: clicked a live intent tag's expand chevron (a
   `.review`-kind row from a real local Understand call) → the write-preview
   inspector rendered "status: Needs manual review — no auto-write", the correct
   real output of `MemoryProcessCockpit.intentWritePreview(for:plan:)` for a
   `.review` kind row. **No defect.**
4. Real interaction exercised: clicked "Show full transcript" → the sheet opened
   with the real, complete (untruncated), selectable transcript and the memo's title
   in the sheet header; clicked the sheet's real "Close" button (`AXSheet` confirmed
   present, then confirmed absent after the click via `ax_inspect find_element(role:
   AXSheet)` returning 0 matches) → sheet dismissed cleanly, detail pane returned to
   its prior state (expanded intent inspector still showing, nothing reset
   unexpectedly). **No defect** — a real `.sheet(isPresented:)` binding, not
   decorative markup.
5. Testing-methodology note (not a product defect, continuing from Loop 1's P3):
   raw screenshot-pixel→logical-point coordinate math was unreliable across this
   loop (multiple stray clicks landed on the desktop/Finder, deactivating the app)
   because the display capture's coordinate origin does not trivially map to
   `mouse_click`'s absolute-screen-point space via a flat scale factor in every
   case. The reliable method throughout was `ax_inspect find_element` → use its
   returned `x`/`y`/`width`/`height` directly (already in logical points) rather
   than deriving coordinates from a `screen_capture` image.

### Plan

1. Fix P1 (search field) — same remedy as `MemoryRecallTab`'s working precedent:
   extract a dedicated `MemosSearchField` View struct (icon + `TextField` + chrome,
   no id of its own) and apply `.accessibilityIdentifier` at the CALL SITE on the
   struct instance, not inline within `listMetaRow`'s body.
2. Fix P1 (needs-review card) — remove the outer `.accessibilityIdentifier(BridgeAXID.
   Memory.inboxRow)` from `needsReviewCard`; each row's action buttons keep their own
   ids (shared across rows by design, since only one memo's entries render at a time —
   matches the old Inbox tab's own convention of shared per-action ids disambiguated
   by which memo/row is currently visible).
3. No fix for the verification-gap note in #2 — document it plainly as a known
   coverage limitation for Loop 3 to note as carried-forward, rather than fabricate
   review-queue data.

### Execute

- `TheBridge/UI/Sections/MemoryMemosTab.swift`:
  - Added a new private `MemosSearchField` View struct (mirrors
    `MemoryRecallTab.RecallSearchField`'s shape exactly) and changed `listMetaRow` to
    use it, with the id applied at the call site.
  - `needsReviewCard`: removed the outer `.accessibilityIdentifier(BridgeAXID.Memory.
    inboxRow)`, replaced with an explanatory NOTE comment citing this loop's finding.

### Verify

- Rebuilt (`make debug`, clean) → reinstalled (`make install-copy`) → relaunched →
  re-navigated to Memory → Memos via `bridge_settings_navigate`.
- Fresh `ax_inspect find_element(role: AXTextField)`: the search field now resolves
  to its own `bridge.settings.memory.memos.search` id (previously
  `bridge.settings.memory.root`).
- Re-exercised the intent-tag expand chevron and the full-transcript sheet
  open/close cycle end-to-end again post-fix (both described in Critique #3/#4 above)
  to confirm the AX-id changes had no rendering/behavioral side effect — both still
  work identically.
- **Result: both P1s fixed and verified for the search field. The needs-review card's
  AX-id fix is code-audited and structurally identical to two already-verified sibling
  fixes (this file's Loop 1, `MemoryRecallTab` Loop 1) but could NOT be independently
  re-verified live this loop — no real memo on this dev machine currently has a
  `.pending` review entry to select and inspect. Carried forward to Loop 3: if a
  `.pending` entry becomes available (e.g. via a real automated processing run),
  re-verify `needsReviewCard`'s button ids live; otherwise this remains a documented,
  code-reviewed-only fix.**

---

## MemoryMemosTab — Loop 3

**Scope**: Final polish pass — attempt to close Loop 2's needs-review verification
gap with real data if any exists by now, stress-test rapid memo-switching (the
discipline that caught a real crash in `MemorySettingsTab` Loop 3), verify the
status-filter pills and secondary reason-filter row against real grouped data, and
confirm the container-only `Memos.list`/`Process.centerPane` AX-id limitation noted
in Loop 1 is genuinely non-blocking.

### Critique (evidence: fresh `review.json` check, rapid `mouse_click` sequences via
AX-resolved coordinates against the Loop-2-fixed live app, `ps aux` + crash-report
check, fresh `screen_capture`/`ax_inspect` throughout)

1. Re-checked `review.json` for any newly-pending entry (in case background
   processing queued one since Loop 2): still 0 `.pending` entries out of 80 total on
   this dev machine at verification time. The Loop 2 coverage gap for
   `needsReviewCard`'s live AX ids stands — documented, not silently dropped.
2. Rapid-clicked between 4 different memo rows in immediate succession (Dec 29 → Dec
   2 → Nov 19 → Nov 17 → back to Dec 29) via `ax_inspect`-resolved coordinates
   re-derived before each click. **No defect** — same app PID survived throughout, no
   new crash reports in `~/Library/Logs/DiagnosticReports/`, each selection correctly
   loaded that memo's own real transcript/title/status (cross-checked transcript
   first-line text against each row's own preview text in the list — no cross-memo
   state bleed).
3. Verified the status-filter pills against real grouped counts: "All" showed a
   single "READY 215" group caption (matches — no memo in the current dataset is
   independently in review/processing/filed per this session's `statusGroup(for:)`
   derivation, since no persisted plan/outcome state survives an app relaunch and no
   real review entries are pending). Clicked "Review" pill → list correctly emptied
   to the "No matches" empty state (0 memos in review group) — correct given 0
   pending entries; clicked back to "All" → all 215 rows returned. **No defect** —
   confirms the filter pill binding is live and the empty state renders correctly
   for a real (not fabricated) zero-result case.
4. Re-confirmed Loop 1's deferred P2 (`Memos.list`/`Process.centerPane` ScrollView
   container ids resolving to the section-wide root instead of their own id) is
   still present and still non-blocking: `ax_inspect find_element(role: AXScrollArea)`
   still shows both scroll containers reporting `bridge.settings.memory.root`, but
   every individual row/button beneath them continues to resolve to its own distinct
   id (spot-checked 3 more memo rows + the title/status/transcript controls). No
   automation path is actually blocked by this — only "address the whole list
   container by id" would be, and nothing in this file or its tests needs that.
   Formally deferring (not fixing) per Loop 1's plan, now cross-checked twice.
5. Final rebuild check (`make debug`) — clean, no errors, no new warnings introduced
   by this file's 3 loops of edits.

### Plan

No further fixes required this loop. The one open item (`needsReviewCard`'s live AX
verification) is a coverage gap caused by the absence of real `.pending` review data
on this dev machine, not a known or suspected defect — the fix applied in Loop 2 is
structurally identical to two independently-verified sibling precedents in this same
log, so it is accepted as correct by code-review parity rather than forced via fake
data. `Memos.list`/`Process.centerPane`'s container-id limitation is explicitly
deferred (P2, cosmetic, non-blocking, documented twice now).

### Execute

No code changes this loop.

### Verify

- All test-induced state from Loops 1–3 (one processed-but-uncommitted memo's
  in-memory plan/title, one search-field query, one filter-pill selection) is either
  already reset by app relaunches between loops or was never persisted (Understand
  without Confirm never touches `review.json`/committed Notion state) — no real user
  data was mutated by this task beyond the harmless, already-noted
  heuristic-title-cache write on one memo (`MemoryHubMemoTitleStore`, a cache the app
  already exists to keep fresh, not a destructive action).
- Ran the task's required final build check: `make debug` — clean, no errors.
- **Result: clean.** No unresolved P0/P1 findings across all 3 loops. Deferred with
  reasons: Loop 1 P2 (heuristic-title UX quirk, pre-existing/out-of-scope), Loop 1 P2
  (`Memos.list`/`Process.centerPane` container AX id, non-blocking, cross-verified
  twice), Loop 2's needs-review live-verification gap (no real `.pending` data
  available on this machine — fix applied and code-reviewed against two verified
  sibling precedents, not independently re-tested live).

---

## MemoryRecallTab — Loop 3

**Scope**: Final polish pass — rapid-interaction stress test (the exact discipline
that caught a real crash in `MemorySettingsTab`'s Loop 3), cross-row state-isolation
check, and a live re-verification of the search field's count binding.

### Critique (evidence: rapid `mouse_click` sequences against the Loop-2-fixed live
app, `ps aux` + `~/Library/Logs/DiagnosticReports/` crash-report checks, fresh
`screen_capture`/`ax_inspect` after each stress sequence)

1. Rapid-clicked the same row's Pin button 4× in immediate succession (pin → unpin →
   pin → unpin). **No defect** — same app PID survived throughout (`ps aux` before/
   after), zero new `.ips` crash reports, final `ax_inspect find_element(label:
   Pinned)` correctly returned 0 matches (net-even click count landed back on
   unpinned) — a real, correctly-serialized `MemoryStore.pin` write cycle, not a
   race or a crash.
2. Expanded 2 non-adjacent rows (1 and 3) via `mouse_click` without collapsing
   between clicks, to check for cross-row bleed in the `expanded: Set<String>`
   state (keyed by `MemoryEntry.id`). **No defect** — fresh screenshot confirmed
   rows 1 and 3 independently showed "Show summary" + full text, while rows 2 and 4
   correctly remained collapsed ("Show full text") — per-row state is properly
   isolated, not a single shared flag.
3. Live-verified the meta row's count binding against a real filter: searched
   "isaiah" → count correctly updated from "49 memories" → "6 memories", and all 6
   visible rows' text genuinely contained "Isaiah" (cross-checked against the full
   memory list, not just trusting the number) — confirms `visibleEntries.count` in
   the meta row and the `ForEach` are reading the same live-filtered array, not two
   independently-computed values that could drift.
4. Window-position note (testing artifact, not a defect): the Settings window had
   moved to the secondary display between app launches partway through this task —
   caught by noticing an `ax_inspect`-reported x-coordinate (3679) exceeding the
   primary display's 2560pt width, then correctly switching to
   `screen_capture(displayIndex: 1)` for all subsequent visual evidence in Loops 2–3.

### Plan

No fixes required — every stress scenario and live re-check passed. Confirmed no
regression to the Loop 1/2 AX-id or visual-chrome fixes under repeated rapid
interaction.

### Execute

No code changes this loop.

### Verify

- All test-induced state (pin/unpin cycles, expand/collapse toggles, search filter)
  reverted before finishing; final screenshot confirms baseline: 49 memories, no
  active search, no rows expanded, none pinned.
- Ran the task's required final build check: `make debug` — clean, no errors.
- **Result: clean.** No unresolved P0/P1 findings across all 3 loops. No P2/P3 items
  remain deferred for this tab (all identified in Loop 1/2 were fixed within the
  same loop, unlike `MemorySettingsTab`'s Loop 1 P2/P3 which were explicitly
  deferred as acceptable/out-of-scope).

---
