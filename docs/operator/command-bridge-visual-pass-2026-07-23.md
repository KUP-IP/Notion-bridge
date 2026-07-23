# Command Bridge visual pass — 2026-07-23

Contract: Spotlight-rhyme chrome (utilitarian glass, squarer, mono field) +
no group plate + adaptive in-tile favorites + open/close motion.

## Chrome recipe (one system)

| Token | Value |
|-------|--------|
| Bar width | 560 (≤580) |
| Bar height | 52 (≤58) |
| Bar corner | 14 continuous |
| Tile size | 40 (≥36 hit) |
| Tile corner | 12 continuous (not circle) |
| Panel corner | 14 |
| Shadow | r12 / y5 (no e2 fog) |
| Material | regularMaterial body + ultraThinMaterial + top sheen + hairline |
| Host | 584 × 260 content-hug |

## IN shipped

- Footer hints removed (hotkeys unchanged).
- No whole-stack scale (group plate); bar micro-scale only; opacity-led open.
- Close: `didOpen=false` then `orderOut` after `closeDuration` (cancel on re-open).
- Favorite tiles: squircle, digit inside, shared glass with bar.
- Settings → Commands tray preview matches tile chrome (no plate behind row).

## F.0 operator visual gate (required before calling Done)

Run on installed/signed build when ready (`make install-copy` + hotkey):

| Backdrop | Check | PASS/FAIL |
|----------|--------|-----------|
| Full white desktop | No soft rectangular fade enclosing tiles+bar as one card | _ |
| Full black | Tiles + bar readable; discrete glass pieces | _ |
| Busy wallpaper | Look-through quality; no grey plate between tiles and bar | _ |
| 0 / 1 / 10 favorites | Adaptive tray; no clip; digits fire | _ |
| Open then Esc | Close animates then dismisses (no hard cut) | _ |

## Deferred

- Multi-entity search ranking / skill palette filter.
- Results as single growing Spotlight card.
- Exact Spotlight side-by-side pt lock (use F.0 vs system Spotlight).
