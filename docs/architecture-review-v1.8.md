# Architecture Review — v1.8.0 Code Review Sprint

**Date:** 2026-04-04  
**Reviewer:** MAC Keepr (agent-assisted)  
**Branch:** `chore/code-review-v1.8`  
**Scope:** Full codebase architecture analysis — 44 source files, 15,858 lines

---

## Executive Summary

The keepr-bridge codebase demonstrates **strong architectural discipline** for a v1.8.0 macOS MCP server app. The layering is clean, module boundaries are consistent, and concurrency patterns are appropriate for Swift 6.2. Five architecture observations are noted — none are blocking, but three merit future attention.

**Verdict:** PASS with observations. No architectural changes required for v1.8.0.

---

## 1. Layering Analysis

### 6-Layer Architecture (top → bottom)

| Layer | Directory | Responsibility | Files |
|-------|-----------|---------------|-------|
| **App** | `App/` | Lifecycle, menu bar, window management | 4 files (832 lines) |
| **UI** | `UI/` | SwiftUI views, settings, onboarding | 13 files |
| **Config** | `Config/` | Persistence, connections, versioning | 5 files (1,002 lines) |
| **Security** | `Security/` | Gates, permissions, credentials, Stripe | 9 files (3,623 lines) |
| **Server** | `Server/` | MCP transport, routing, validation | 4 files (1,597 lines) |
| **Modules** | `Modules/` | Tool implementations (stateless) | 19 files (8,804 lines) |

### Dependency Direction

```
App → UI → Config → Security → Server → Modules
 ↓         ↓                     ↓
 Config    Security              Config (read-only)
```

**Assessment:** Clean top-down dependency flow. No circular dependencies detected. Config is correctly accessed read-only from lower layers. Security layer sits between Config and Server, gating all tool dispatch.

---

## 2. Module Boundaries

### Pattern: Stateless Enum Modules

All 15 tool modules follow the identical pattern:

```swift
public enum XModule {
    public static let moduleName = "x"
    public static func register(on router: ToolRouter) async { ... }
}
```

**15 modules confirmed:** accessibility, applescript, chrome, connections, credential, file, messages, notion, payment, screen (+ recording + analyze), session, shell, skills, stripe, system

### Registration

ServerManager.swift registers all 16 modules (15 + echo builtin) in a fixed order. The order is:
1. ShellModule → FileModule → SessionModule → MessagesModule → SystemModule
2. NotionModule → ScreenModule (register + registerRecording + registerAnalyze)
3. AccessibilityModule → AppleScriptModule → ChromeModule
4. SkillsModule → CredentialModule → PaymentModule → StripeMcpModule → ConnectionsModule
5. Echo builtin

**Assessment:** Registration order is not functionally significant — modules are independent. The grouping roughly follows capability domains (core → Notion → UI automation → skills → payment → meta).

---

## 3. Concurrency & Actor Isolation

### Actor-Isolated Types (5)
| Type | Isolation | Purpose |
|------|-----------|---------|
| `SecurityGate` | `actor` | Tool tier enforcement, approval flow |
| `AuditLog` | `actor` | Append-only tool call audit trail |
| `ConnectionHealthChecker` | `actor` | Cached health validation (60s TTL) |
| `ConnectionRegistry` | `actor` | Bridge connection CRUD |
| `StripeMcpProxy` | `actor` | Stripe MCP session + tool proxy |

### @unchecked Sendable Types (2)
| Type | Pattern | Justification |
|------|---------|---------------|
| `ConfigManager` | DispatchQueue + barrier writes | Pre-actor design, functional. Thread-safe via concurrent queue. |
| `StripeClient` | URLSession-based, no mutable state per call | Stateless request builder. |

### @MainActor Types (4)
| Type | Purpose |
|------|---------|
| `AppDelegate` | App lifecycle |
| `StatusBarController` | Observable UI state |
| `WindowTracker` | Activation policy management |
| All SwiftUI views | Standard UI isolation |

### Module Handlers
All tool handlers are closures captured at registration time — they are `@Sendable` by ToolRouter contract. Modules are stateless enums, so no isolation is needed.

**Assessment:** Concurrency model is well-structured. The actor/MainActor split correctly separates concerns. See ARCH-02 for ConfigManager modernization opportunity.

---

## 4. Protocol Seams

**Finding:** Zero Swift `protocol` declarations exist in the codebase.

The codebase uses **concrete types exclusively** — enums for modules, actors for stateful services, structs for data, final classes for singletons. This works well at the current scale but limits testability:

- `NotionClient` is a concrete class — tests must hit the real Notion API or mock at the network layer
- `CredentialManager.shared` is a singleton — no injection seam for tests
- `ToolRouter` is a concrete actor — no protocol for test doubles

**Assessment:** Acceptable for current scale. If test coverage expansion (Phase 5) reveals mocking friction, introduce protocols for `NotionClient`, `CredentialManager`, and `ToolRouter` as needed. Not a v1.8.0 blocker.

---

## 5. Naming Conventions

### Modules
- Pattern: `{Domain}Module` — **100% consistent** across all 15 modules
- Module names: lowercase domain strings (`"notion"`, `"shell"`, `"chrome"`, etc.)

### Tools
- Pattern: `{module}_{action}` — **100% consistent**
- Examples: `shell_exec`, `chrome_tabs`, `notion_search`, `credential_save`, `ax_focused_app`

### Security Types
- Pattern: `{Concept}Manager` or `{Concept}Gate` — consistent
- `SecurityGate`, `PermissionManager`, `CredentialManager`, `KeychainManager`

### Config Types
- Pattern: `{Domain}Manager` or `{Domain}Registry` — consistent
- `ConfigManager`, `ConnectionRegistry`, `ConnectionHealthChecker`

**Assessment:** Naming is disciplined and predictable. No inconsistencies found.

---

## 6. Architecture Observations

### ARCH-01: Dual SkillConfig Types (Low Priority)
**Location:** `SkillsModule.swift` + `SkillsManager.swift`  
**Issue:** Both files define parallel `Skill`/`SkillConfig` structs with overlapping fields. SkillsModule has its own parsing, SkillsManager has its own.  
**Impact:** Maintenance burden — changes to skill schema require updates in two places.  
**Recommendation:** Consolidate into a single `SkillConfig` in `SkillsManager.swift` and have `SkillsModule` reference it.

### ARCH-02: ConfigManager @unchecked Sendable (Low Priority)
**Location:** `Config/ConfigManager.swift`  
**Issue:** Uses `DispatchQueue` with barrier writes for thread safety, annotated `@unchecked Sendable`. Functional but pre-actor pattern.  
**Impact:** The `@unchecked` annotation suppresses compiler checking. If new mutable state is added without barrier protection, it silently becomes a data race.  
**Recommendation:** Migrate to `actor ConfigManager` in a future sprint. Not urgent — current barrier pattern is correct.

### ARCH-03: NotionModule Lazy Registry with NSLock (Low Priority)
**Location:** `NotionModule.swift:1127-1130`  
**Issue:** Uses `private var registry` + `NSLock` for lazy initialization of `NotionClientRegistry`. Pre-actor pattern.  
**Impact:** Minor — NSLock is correct but verbose. Actor isolation would be more idiomatic.  
**Recommendation:** Low priority. The pattern works and the scope is small (3 lines).

### ARCH-04: Tier Override System — No Audit Trail (Medium Priority)
**Location:** `UI/ToolRegistryView.swift` + `Server/ToolRouter.swift:93`  
**Issue:** UserDefaults key `com.notionbridge.tierOverrides` allows UI-driven tier changes (e.g., `.request` → `.open`) that take effect at tool dispatch time. Changes are persisted but not logged to AuditLog.  
**Impact:** A user (or agent with `shell_exec` access) could silently downgrade security tiers. No record of when/what changed.  
**Recommendation:** Log tier override changes to AuditLog. Consider adding a timestamp and source (UI vs programmatic) to the override record.

### ARCH-05: No Protocol Seams for Testing (Low Priority)
**Location:** Codebase-wide  
**Issue:** Zero protocol declarations. All dependencies are concrete types with `.shared` singletons.  
**Impact:** Test doubles require network-level mocking rather than dependency injection.  
**Recommendation:** Introduce protocols incrementally as test coverage expands. Start with `NotionClientProtocol` and `CredentialStoring`.

---

## 7. Positive Highlights

1. **Consistent module pattern** — All 15 modules follow the exact same registration API
2. **Clean actor boundaries** — 5 actors with clear responsibilities, no actor re-entrancy concerns
3. **Proper @MainActor isolation** — UI layer correctly isolated, no cross-actor UI updates
4. **Stateless modules** — All tool modules are enums with no stored state, eliminating concurrency bugs
5. **Centralized routing** — ToolRouter is the single dispatch point for all 75+ tools
6. **Defensive error handling** — Tool handlers consistently return error objects rather than throwing
7. **Transport abstraction** — stdio + SSE run concurrently via TaskGroup, sharing the same ToolRouter

---

*Generated during code-review-v1.8 sprint, Phase 3.*
