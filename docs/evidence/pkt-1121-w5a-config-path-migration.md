# PKT-1121 W5A — Config-Path Migration Evidence

Date: 2026-07-14

## Result

The default Bridge configuration and memory home now resolves to
`~/.config/the-bridge`. `BRIDGE_CONFIG_PATH` remains the highest-precedence
operator override. App startup runs the migration before `ConfigManager` or
`MemoryStore` can initialize and terminates before either subsystem on a
migration error.

This packet did not install or launch an app bundle and did not read,
enumerate, move, or write the operator's real config directories. All
filesystem proof used a temporary `BridgePaths.overrideHomeForTesting` home.

## Non-destructive migration contract

- A legacy `~/.config/notion-bridge` directory is atomically renamed to a
  unique `notion-bridge.legacy-<timestamp>[-N]` archive.
- The full retained archive remains intact. Config, SQLite, WAL, SHM, hidden
  files, and any other top-level entries are copied from it to the canonical
  directory.
- Existing canonical entries are never overwritten. The legacy copy is kept
  as `<name>.pre-migrate-<timestamp>[-N]` while the full archive remains the
  recovery source.
- An external journal makes both the pre-rename and post-rename interruption
  windows resumable. A completion sentinel makes later launches no-ops.
- A fresh install records completion without eagerly creating the canonical
  config directory. An override skips default-path migration without consuming
  the future default migration.
- Migrated `config.json` is owner-only (`0600`). Later config writes create the
  canonical parent and preserve the same permission posture. A legacy read
  fallback remains available when canonical config is absent.

## Automated proof

Ten net-new hermetic tests cover:

1. canonical default resolution;
2. override precedence;
3. fresh-install laziness;
4. byte-identical config, memory DB, WAL, SHM, and hidden-file copy plus full archive retention;
5. real `MemoryStore` recall parity after migration;
6. byte-identical second-run idempotence;
7. canonical collision preservation with both recovery copies;
8. override skip without consuming migration;
9. resume from an already-renamed archive; and
10. resume when interruption occurs after journal creation but before the atomic legacy rename.

Acceptance gates:

- `git diff --check`: PASS
- `make check-counter-collisions`: PASS
- `make test-floor`: PASS — 3,177 passed, 0 failed, floor 3,177
- environment-unset strict `make build`: PASS

The floor moved from 3,167 to 3,177, exactly matching the ten net-new tests.

## Review boundary

Installed-runtime and real-user-home migration proof is deliberately deferred.
It requires a separate operator-authorized install/launch exercise because this
closure run prohibits installs and mutations of real user configuration. The
implementation therefore stops at packet `REVIEW`, not `Done`.
