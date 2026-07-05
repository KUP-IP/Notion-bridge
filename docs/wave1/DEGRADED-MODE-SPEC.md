# Degraded-Mode Spec (D9a) — Constitution Availability When the Bridge Is Down

Requirement (Bridge-Evolution-Contract v1.1, D9a): clients degrade to **"governed but hands-tied," never "lobotomized."** The constitution must be readable during 100% of Mac-down intervals (north-star metric 5).

## States

| State | Detect | Client behavior |
|---|---|---|
| **LIVE** | `bridge_initialize` succeeds | Full governance + tools. Cache the returned constitution locally with `{doctrineVersion, fetchedAt}`. |
| **DEGRADED (bridge up, source stale)** | receipt `doctrineFreshness: stale/interim` or `finalState: DEGRADED` | Operate normally; announce degraded state in the session receipt; never silently normalize. |
| **DOWN (bridge unreachable)** | initialize/tool calls fail | **No local-machine or write operations.** Fall back to cached constitution if within TTL; else Notion mirror read; else Tier-0 capsule embedded in the bootstrap skill. Work is reasoning/drafting only. On restore: re-run `bridge_initialize` before any tool use. |

## Cache contract

- **What:** the `constitution` object from the last successful handshake (tier0 + doctrine core + orders + roster versions).
- **TTL:** 7 days for governance validity (rules change slowly; Registry Hygiene reviews are 3–6 months). After TTL: only the embedded Tier-0 capsule remains authoritative; everything else is advisory memory.
- **Where:** client-side (claude.ai project/skill cache, Cursor rules file, Code memory). The bootstrap skill's cached Tier-0 capsule is the floor that never expires (its version stamp shows age).
- **Staleness honesty:** any output produced under cached constitution states so: "operating on cached constitution v{X} from {date}; Bridge unreachable."

## Notion mirror as read fallback

The doctrine page and (W2+) order mirrors remain readable via any client's native Notion access when the Bridge is down. Precedence under fallback is unchanged (registry orders > doctrine); the client just can't verify integrity hashes — noted in the staleness statement.

## Explicit non-goals

No secondary broker, no cloud replica of the runtime (rejected in Evolution Contract D9 — "cloud-native core" lost). Availability of *execution* is not promised when the Mac is down; only availability of *law*.
