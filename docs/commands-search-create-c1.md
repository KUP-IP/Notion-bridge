# Command Search create C1

GitHub issue #140, packet C1. Bridge Search can create and manage commands
without accidental saves. Create is explicit. Edit reuses the Settings editor
through a stable command ID, not a display slug.

## Interaction

Ordinary Return still fires the selected result, or does nothing when Search
has no match. It never writes a command.

| Input | Result |
| --- | --- |
| **Create command from this text** | Opens the compact create sheet from the query |
| Option+Return or ⌘N | Same explicit create entry |
| Multiline query / paste | First line becomes the name; full text is the body |
| Sheet **Save** | Writes through `CommandStore.create` after assessment |
| Sheet **Cancel** / Escape | Drops the draft; nothing is written |
| Exact name/slug duplicate | Save stays disabled; **Edit existing** is offered |
| Near-duplicate name | Warning + **Open similar**; Save remains available |
| Sensitive path in body | Warning; Search subtitle never includes the body |
| Context **Edit** / **Reveal** | Settings → Commands, selected by immutable ID |
| Context **Duplicate** | Opens a create sheet with a copy name and the same body |
| Context **Move** / **Remove** | Unchanged C0 favorite transactions |

The create sheet is compact: name, body, sensitivity toggle, optional 1–0
slot, Save, Cancel. It is not a second full editor.

## Quiet + safety

Failed searches stay failed until the operator chooses Create. Duplicate and
sensitive warnings are shown in the sheet before Save. Removing a favorite
still only clears the slot. New commands persist through later `update`.

## Out of scope

No save from ordinary Return. No GitHub publication. No automatic deletion.
Live Search screenshots are a visual-review artifact, not an Installed
Verified claim.
