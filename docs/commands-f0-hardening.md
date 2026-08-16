# Command hardening F0

GitHub issue #140, packet F0. E0 is merged. This packet hardens the integrated
command system and may produce a signed candidate. It does not install, tag,
or close the issue.

## Preservation matrix (source)

| Rehearsal | Expected |
| --- | --- |
| Two forward catalog updates | Local override body stays byte-for-byte |
| Interrupted revision write | Prior revision stays active |
| Corrupt new revision | Reads stay on the last valid body; mutation recovers |
| Product-default hide | Tombstone does not resurrect the default |
| Favorite replace + undo | Layout restores; command bodies unchanged |
| Compatibility-required incoming | Execution gate closes with schema evidence |
| Editorial incoming | Execution gate stays open (false-positive refusal) |
| Search create | Ordinary Return never writes; exact name collision blocks Save |
| Developer publication | Secrets block Ready until acknowledged; standard mode has no Git |
| Calibrate | Bounded; `installAllowed` stays false |

## Out of scope

Promoted install (`make install-copy`), tags, Sparkle, and closing #140.
G0 owns `/Applications`.

## Visual / UX

UI-ITER is fail-closed. Live Search/Settings screenshots are a named gap
unless captured in the same SHA receipt.
