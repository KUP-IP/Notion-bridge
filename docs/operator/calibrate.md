# Calibrate

Read-only whole-product report for The Bridge. Not a backlog. Not an AI LOG
mirror. Actionable leftovers go to GitHub Issues after search-before-create.

## When to run

After a focus session, before promoted install, or when source / installed /
GitHub identity has drifted.

## Required sections (bounded)

1. **Identity** — source branch, exact SHA, dirty, installed SHA/path if proven, whether they match.
2. **GitHub** — open issues, open PRs, latest CI conclusion. Search before creating.
3. **Workspace** — current branches and worktrees. Primary checkout stays on `main`.
4. **Install / release** — whether a promoted install is allowed. Default: no, until G0.
5. **Coherence** — docs vs live catalog vs tests. Name contradictions; do not guess.
6. **Sprint outcomes** — at most five next moves.

Do not append `AGENT_FEEDBACK.md`. Do not dump AI LOG rows into Issues.

## Dry-run shape

Use `CommandCalibrateReport.render()`. A live dry run is Source Tested when
the report is produced from named Git evidence without replacing
`/Applications/The Bridge.app`. Installed identity stays `unproven` unless
read back from the installed bundle.
