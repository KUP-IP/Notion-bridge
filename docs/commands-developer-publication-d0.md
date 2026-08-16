# Command developer publication D0

GitHub issue #140, packet D0. An operator can propose a local command override
as a product change. Ordinary command use and updates stay Git-free.

## Capability gate

Developer publication is off by default (`commandsDeveloperPublication`).
Standard mode shows no GitHub, branch, commit, or push controls. Offline
command updates still work with or without a repo.

## Publication transaction

| Step | Required |
| --- | --- |
| Review exact outbound body | Always |
| Associate or create a GitHub issue | Before Ready |
| Choose an issue-linked branch | Before Ready |
| Privacy scan | Blocks until acknowledged |
| Commit | Explicit approval |
| Push | Explicit approval |
| Reconcile local override | Only after the shipped default matches |

Favorite layout and usage history are never part of the patch. No commit or
push is silent. Ambiguous repository identity refuses the Git action.

Proposal states: Draft → Ready → Published → Merged → Shipped → Reconciled.

## Out of scope

Automatic commit/push, standard-mode GitHub UI, publishing favorites, deleting
the local override on merge, tags, and promoted install.
