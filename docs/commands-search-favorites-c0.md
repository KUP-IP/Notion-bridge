# Command Search favorites C0

GitHub issue #140, packet C0. Bridge Search can assign, move, swap, replace,
and undo favorite slots without mutating command bodies. The A0 favorite map
is the only persistence surface.

## Interaction

Search stays quiet until a command row is hovered, focused, or already
favorited. Then a star appears. An empty star opens the shared 1–0 picker.
A filled star plus slot number means the command already occupies that slot.

| Input | Result |
| --- | --- |
| Star click / context menu **Move to slot…** | Opens the shared 1–0 picker |
| Digit 1–0 while picker is open | Assigns that store slot |
| Option+digit on a selected command | Assigns without opening the picker first |
| Occupied target, mover already slotted | **Replace**, **Swap**, or **Cancel** |
| Occupied target, mover unslotted | **Replace** or **Cancel** (Swap is hidden) |
| Context menu **Remove favorite** | Clears the command's slot |
| Undo / context menu **Undo favorite change** | Restores the previous layout (20 deep) |
| Escape | Cancels picker or prompt; otherwise hides Search |
| Bare digit with picker closed | Still fires the slot, as before |

Replace evicts the occupant. Swap exchanges the two slots. Cancel leaves the
prior layout. Persistence is one `applyFavoriteLayout` publish, so a swap is
never two half-states. `setKeySlot` in the editor still evicts atomically.

## Quiet + accessibility

Inactive rows do not show the star. Skills, jobs, and tools never get favorite
controls. VoiceOver exposes slot value, Move/Remove, and the 1–0 picker.
Keyboard and pointer reach the same layout transactions.

## Out of scope

No command creation, no editor inside Search, no product publication, no body
rewrites. Live Search screenshots are a visual-review artifact, not an
Installed Verified claim.
