# NotionBridge v1.4.0 — Release Handoff

**Prepared by:** MAC Keepr (Chief Executive Agent)
**Date:** 2026-03-24
**Sprint:** UEP v3.2.0 — Version Bump & Release Prep

---

## ✅ Completed (Automated)

| Task | Commit | Status |
|------|--------|--------|
| Commit dirty working tree (Makefile rpath + ChromeModule Space-awareness) | `209c99f` | ✅ |
| Pop & merge stash (Stripe payment test fixes, conflict resolved) | `c9c9b64` | ✅ |
| Version bump v1.2.0 → v1.4.0, build 4 → 5 (Version.swift + Info.plist) | `8d9ed9d` | ✅ |
| Update E2E test tool count assertions (63 → 65) | `24d29a2` | ✅ |
| Update SystemModule (3→4) and SkillsModule (1→2) tool count assertions | `6393a55` | ✅ |
| Update AGENTS.md (65 tools, 13 modules) | `8d9ed9d` | ✅ |
| Full test suite — **308/308 passed** | — | ✅ |
| Tag `v1.4.0` | — | ✅ |
| Push to `origin/main` with tags | — | ✅ |

**9 commits** since v1.3.0. HEAD is `6393a55` on `main`.

---

## ⬜ Remaining Manual Steps

### 1. Store Notarization Credentials

The `notarytool-profile` keychain entry is **missing**. This is required for `make notarize`.

```bash
xcrun notarytool store-credentials "notarytool-profile" \
  --apple-id YOUR_APPLE_ID \
  --team-id VP24Z9CS22 \
  --password YOUR_APP_SPECIFIC_PASSWORD
```

> Generate an app-specific password at [appleid.apple.com](https://appleid.apple.com) → Sign-In and Security → App-Specific Passwords.

### 2. Install `create-dmg`

`create-dmg` is **not installed**. Required for `make dmg`.

```bash
# If brew is not on PATH, find it first:
eval "$(/opt/homebrew/bin/brew shellenv)"

brew install create-dmg
```

### 3. Build, Sign, Notarize, Package

**Option A — Full pipeline (recommended):**
```bash
make release
```
This runs: `clean → test → sign → notarize → dmg → verify`

**Option B — Step by step:**
```bash
make clean
make test       # Should pass (already verified)
make sign       # Code signs with Developer ID
make notarize   # Submits to Apple notary service
make dmg        # Creates distributable DMG
make verify     # Validates signing + notarization
```

### 4. (Optional) Generate Sparkle Appcast

If distributing via Sparkle auto-update:
```bash
.build/artifacts/sparkle/Sparkle/bin/generate_appcast /path/to/releases/
```

---

## Known Environment Notes

- **brew** is not on NotionBridge's shell PATH (use full path `/opt/homebrew/bin/brew` or eval shellenv)
- **NotionBridge cannot build itself** — it must be stopped or built from a separate process
- **Cursor CLI** v2.6.20 is available at `/usr/local/bin/cursor` but `cursor-agent` standalone binary is not installed (Cursor agent mode requires the full Cursor.app)
- **Swift 6.3** is installed and compatible

---

## Changelog (v1.3.0 → v1.4.0)

- **feat(chrome):** Space-aware tab listing + navigate fallback
- **fix(build):** rpath `@loader_path` correction in Makefile
- **fix(tests):** Stripe payment test fixes (readRequestBody helper)
- **chore:** Swift 6.3 compat, SkillsModule fix, patch-deps target
- **chore:** Module tool count reconciliation (63→65 tools, 14→13 modules)
- **chore:** Version bump to v1.4.0 build 5
