# PKT-1131 — A.I. Doctrine Cache

Status: implementation candidate for review
Authority: Notion is the write source of truth; Bridge is a disposable, derived read cache.

## Decision

V1 caches **SKILLS only**. BOTS, AI LOGS, and BUGS have different state, retention, and write semantics and are intentionally excluded. Adding them to the same payload would blur doctrine with operational records and would couple this packet to schema owned by other Keeprs.

Bridge extends its existing skill-body cache and `fetch_skill` protocol rather than introducing another registry or sync service:

- Agent calls prefer the Notion page UUID through `fetch_skill.id`.
- Slug/name remains available for people, routing, and compatibility.
- A cached record contains schema version, canonical page UUID, slug, doctrine version, full Markdown body, status, maturity, mirrored Notion properties, source URL/title, Notion `last_edited_time`, cache write time, TTL, and call count.
- UUID resolution is limited to configured Bridge skills and specialists discovered through their curated routing relations. An arbitrary Notion page ID cannot turn `fetch_skill` into an unrestricted page reader.
- The response envelope exposes `uuid`, `slug`, `version`, `status`, and `maturity` beside the full `content` body.

Disk files remain an implementation cache under Bridge's existing cache directory. They have no write-back path and can be deleted and rebuilt from Notion without loss of authoritative state.

## Existing topology reused

The implementation keeps the current separation:

1. `SkillsManager` owns the configured-skill roster and parent/specialist topology.
2. `SkillsCacheWriter` maintains the thin routing roster.
3. `SkillBodyCacheStore` maintains full bodies, keyed by normalized Notion page ID, using atomic writes.
4. `SkillsModule.fetch_skill` resolves a configured skill and serves memory, disk, or Notion while preserving the existing plain-fetch fast path.
5. Notion mutation tools already evict affected skill-body entries.

No new database, manifest, schema, or bidirectional synchronizer is added.

## Fetch and identity protocol

`fetch_skill` accepts one of:

- `id`: canonical or compact Notion UUID. This is the preferred, exact agent identity and is authoritative if both fields are supplied.
- `name`: existing human/routing label path, retained for compatibility.

Success returns the stable identity tuple plus the full body. A malformed UUID is an input error; a well-formed but unconfigured UUID is a not-found error. Existing name ambiguity rules remain in force. Cache files written before schema version 1 decode compatibly and derive the identity tuple from mirrored properties when possible.

## Invalidation and refresh

V1 keeps the existing configurable TTL, defaulting to 24 hours, and strengthens it:

- Startup performs a background sweep of configured Notion parents plus their curated routing specialists and refreshes entries that are missing or expired.
- An expired entry triggers revalidation immediately when accessed; fresh entries keep the existing periodic validator cadence.
- Notion `last_edited_time` remains the cheap content validator.
- Known Notion writes evict the affected cache entry.
- Refresh is atomic per UUID. A failed or incomplete refresh never replaces a complete last-known-good entry.
- A refresh sweep returns explicit counts and failed UUIDs so partial failure is observable without invalidating successful records.

A body hash adds little in V1 because detecting a changed hash still requires fetching Notion. Webhooks would reduce the stale window, but introduce host reachability, delivery authentication, retry storage, and multi-host fan-out. TTL plus source timestamps is the appropriate first protocol; a webhook can later act only as an eviction hint while TTL remains the repair path.

## Failure semantics

- Network or Notion failure: retain the prior complete cache record and report the failed UUID.
- Missing required doctrine fields: serve the live result when possible, but do not persist it over a complete record.
- Partial startup sweep: preserve successful refreshes and expose the failed IDs in the refresh report.
- Deleted/unconfigured skill: UUID lookup fails closed; existing explicit cache eviction paths remain responsible for removing obsolete files.
- Cache corruption: existing reader behavior treats the file as a miss and rebuilds from Notion.

Required cache completeness is UUID, slug, version, non-empty full body, status, and maturity. This validation is Bridge-side only and does not mutate the Notion A.I. schema.

## Risks and controls

| Risk | Control / residual |
| --- | --- |
| Up to one TTL of staleness on an idle host | Startup sweep, access revalidation, and write eviction reduce the window; no push invalidation in V1. |
| Multi-host refresh load | Sweep only missing/expired entries and run in the existing background startup task; large fleets may later need jitter or bounded concurrency. |
| Slug rename or collision | UUID is the agent identity; slug is a label and compatibility route. |
| Incomplete Notion records | Completeness gate refuses to overwrite last-known-good cache; source schema quality remains owned by NOTION Keepr. |
| Local cache disclosure | Full doctrine already exists in the current Bridge cache; this change adds explicit metadata, not a new persistence surface. Existing local permissions remain the boundary. |
| Old cache files lack explicit fields | Backward-compatible decoding derives fields from mirrored properties; incomplete legacy entries are refreshed. |
| No webhook | TTL is deterministic repair. A future authenticated webhook should only evict by UUID, never write doctrine. |

## Implementation and verification plan

1. Extend `CachedSkillBody` with a versioned identity tuple and completeness validation.
2. Add UUID-first `fetch_skill` resolution against configured skills and annotate all success envelopes.
3. Add a startup missing/expired body sweep with explicit partial-failure reporting and last-known-good retention.
4. Correct specialist freshness tracking to use the child's `last_edited_time`, not the parent's.
5. Cover cache round-trip/backward shape, UUID schema/input behavior, and response identity in the standalone test suite.
6. Run the repository test floor. Review and merge normally; no Notion schema migration or cache-to-Notion write is part of rollout.

## Rollback

Revert the implementation commit. Existing cache files remain readable by the new code and disposable by design; deleting them only causes a Notion rebuild. No authoritative doctrine or Notion schema must be rolled back.
