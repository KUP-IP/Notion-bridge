// RegistryWriter.swift — Data-Source Registry (Wave 2)
// TheBridge · Modules · Registry
//
// The write path. Resolves canonical-key input (`[key: Value]`) against the
// entity's BOUND property map into `[BoundField]` (id + type + value), then:
//   • create — create-then-update (Decision/spec note: never set the full
//     property set via create-on-data-source; create with the TITLE only, then
//     PATCH the rest), so a Notion automation that fires on create sees a valid
//     titled row first.
//   • update — PATCH changed properties by id.
//   • delete — soft archive (Decision 8) + cache evict.
// Each successful write refreshes the read-through cache from the returned row
// so a subsequent read is a warm hit.
//
// PKT-MEM-135 (2026-07-02): `RegistryAppendMerge` — the shared, entity-agnostic
// append-merge primitive, extracted from `VoiceMemoProcessor.mergeAppendRegistryFields`
// (VoiceMemoProcessor.swift:524-549) so registry_resolve_and_update can reuse the
// EXACT same "existing value + new content, stamped block" behavior without a
// Registry→VoiceMemo module coupling. `VoiceMemoProcessor` is left untouched
// (Scope OUT — rewiring the voice-memo caller is PKT-MEM-136's concern); this is
// a byte-for-byte port of the stamp+block format so both call sites produce
// identical output for the same (existing, newContent, now) triple.

import Foundation
import MCP

public struct RegistryWriter: Sendable {
    public let gateway: RegistryNotionGateway
    public let cache: RegistryRowCache

    public init(gateway: RegistryNotionGateway, cache: RegistryRowCache = .shared) {
        self.gateway = gateway
        self.cache = cache
    }

    public enum RegistryWriteError: Error, LocalizedError, Equatable {
        case notFullyBound(entity: String, unbound: [String])
        case unknownFields(entity: String, keys: [String])
        case noWritableFields(entity: String)
        case preflightFailed(entity: String, failed: [RegistryFieldFailure])
        case partialMaterialization(entity: String, envelope: RegistryCreateEnvelope)
        public var errorDescription: String? {
            switch self {
            case .notFullyBound(let e, let u):
                return "entity ‘\(e)’ has unbound properties \(u) — run introspection first"
            case .unknownFields(let e, let k):
                return "entity ‘\(e)’ has no properties \(k)"
            case .noWritableFields(let e):
                return "no writable fields supplied for ‘\(e)’"
            case .preflightFailed(let e, let failed):
                let detail = failed.map { "\($0.field): \($0.reason)" }.joined(separator: "; ")
                return "entity ‘\(e)’ create blocked before page creation — \(detail)"
            case .partialMaterialization(let e, let env):
                return "entity ‘\(e)’ partially materialized at \(env.entityUrl ?? env.row?.pageId ?? "?") — repair that row; do not re-create"
            }
        }
    }

    /// Resolve canonical-key input into bound fields. Unknown keys (not in the
    /// property map) and unbound keys (no resolved property id) are reported.
    public static func resolve(
        _ input: [String: Value], entity: RegistryEntity
    ) -> (fields: [BoundField], unknown: [String], unbound: [String]) {
        var fields: [BoundField] = []
        var unknown: [String] = []
        var unbound: [String] = []
        for (key, value) in input {
            guard let prop = entity.property(key) else { unknown.append(key); continue }
            guard let pid = prop.notionPropertyId, !pid.isEmpty else { unbound.append(key); continue }
            fields.append(BoundField(
                propertyId: pid, notionName: prop.notionName, type: prop.type,
                value: value, isTitle: prop.role == .title))
        }
        return (fields.sorted { $0.notionName < $1.notionName }, unknown.sorted(), unbound.sorted())
    }

    /// At least one field must actually encode to a Notion payload — guards
    /// against a write whose entire envelope would be empty (e.g. only
    /// read-only types, or all values non-coercible for their type), which
    /// would otherwise no-op an update or create an empty untitled page.
    static func hasEncodable(_ fields: [BoundField]) -> Bool {
        fields.contains { RegistryPropertyCodec.encode(type: $0.type, value: $0.value) != nil }
    }

    // MARK: - Create (create-then-update)

    /// Create-then-update that never hides a materialized page behind a thrown
    /// error. Preflights relation targets; returns `state: none` without creating
    /// when a target is inaccessible; returns `state: partial` with `entityUrl`
    /// when the title lands and a later field PATCH fails.
    public func createReporting(
        entity: RegistryEntity, fields input: [String: Value]
    ) async throws -> RegistryCreateEnvelope {
        let r = Self.resolve(input, entity: entity)
        if !r.unknown.isEmpty { throw RegistryWriteError.unknownFields(entity: entity.key, keys: r.unknown) }
        if !r.unbound.isEmpty { throw RegistryWriteError.notFullyBound(entity: entity.key, unbound: r.unbound) }
        if r.fields.isEmpty || !Self.hasEncodable(r.fields) { throw RegistryWriteError.noWritableFields(entity: entity.key) }

        let preflight = await preflightRelationTargets(r.fields, entity: entity)
        if !preflight.isEmpty {
            return RegistryCreateEnvelope(state: .none, row: nil, applied: [], failed: preflight)
        }

        let titleFields = r.fields.filter { $0.isTitle }
        let rest = r.fields.filter { !$0.isTitle }
        let seedFields = titleFields.isEmpty ? r.fields : titleFields

        let created = try await gateway.create(
            dataSourceId: entity.dataSourceId, workspace: entity.workspace,
            fields: seedFields)
        _ = await RegistryReader.store(created, entity: entity, into: cache)
        var row = created
        var applied = seedFields.map { Self.canonicalKey(for: $0, entity: entity) }
        var failed: [RegistryFieldFailure] = []

        if !titleFields.isEmpty, !rest.isEmpty {
            do {
                row = try await gateway.update(pageId: created.id, workspace: entity.workspace, fields: rest)
                let classified = Self.classifyFields(rest, on: row, entity: entity)
                applied.append(contentsOf: classified.applied)
                failed.append(contentsOf: classified.failed)
            } catch {
                let isolated = await isolateRestFields(
                    rest, pageId: created.id, workspace: entity.workspace, entity: entity)
                row = isolated.row ?? row
                applied.append(contentsOf: isolated.applied)
                failed.append(contentsOf: isolated.failed)
            }
        } else {
            let classified = Self.classifyFields(seedFields, on: row, entity: entity)
            failed.append(contentsOf: classified.failed)
            if !classified.failed.isEmpty {
                applied = classified.applied
            }
        }

        let cached = await RegistryReader.store(row, entity: entity, into: cache)
        let state: RegistryCreateEnvelope.State = failed.isEmpty ? .complete : .partial
        var seen = Set<String>()
        let uniqueApplied = applied.filter { seen.insert($0).inserted }
        return RegistryCreateEnvelope(
            state: state, row: cached, applied: uniqueApplied, failed: failed)
    }

    @discardableResult
    public func create(entity: RegistryEntity, fields input: [String: Value]) async throws -> CachedRow {
        let env = try await createReporting(entity: entity, fields: input)
        switch env.state {
        case .complete:
            guard let row = env.row else {
                throw RegistryWriteError.noWritableFields(entity: entity.key)
            }
            return row
        case .none:
            throw RegistryWriteError.preflightFailed(entity: entity.key, failed: env.failed)
        case .partial:
            throw RegistryWriteError.partialMaterialization(entity: entity.key, envelope: env)
        }
    }

    static func canonicalKey(for field: BoundField, entity: RegistryEntity) -> String {
        entity.properties.first(where: {
            $0.notionPropertyId == field.propertyId || $0.notionName == field.notionName
        })?.key ?? field.notionName
    }

    /// GET each relation target before creating the parent row. Notion returns
    /// 404 for both missing and unshared pages; either is inaccessible to this
    /// integration and must fail closed as `state: none`.
    func preflightRelationTargets(
        _ fields: [BoundField], entity: RegistryEntity
    ) async -> [RegistryFieldFailure] {
        var failed: [RegistryFieldFailure] = []
        for field in fields where field.type == "relation" {
            let key = Self.canonicalKey(for: field, entity: entity)
            for id in RegistryPropertyCodec.pageIds(from: field.value) {
                do {
                    _ = try await gateway.page(pageId: id, workspace: entity.workspace)
                } catch {
                    failed.append(RegistryFieldFailure(
                        field: key,
                        reason: "inaccessible_relation_target (\(id)): \(String(describing: error))"))
                }
            }
        }
        return failed
    }

    static func classifyFields(
        _ fields: [BoundField], on row: NotionRow, entity: RegistryEntity
    ) -> (applied: [String], failed: [RegistryFieldFailure]) {
        var applied: [String] = []
        var failed: [RegistryFieldFailure] = []
        for field in fields {
            let key = canonicalKey(for: field, entity: entity)
            let actual = row.cell(for: matchingProperty(field, entity: entity))?.value
                ?? row.cells[field.notionName]?.value
            switch RegistryPropertyCodec.classifyWrite(type: field.type, requested: field.value, actual: actual) {
            case .applied, .canonicalized:
                applied.append(key)
            case .rejected(let reason):
                failed.append(RegistryFieldFailure(field: key, reason: reason))
            }
        }
        return (applied, failed)
    }

    static func matchingProperty(_ field: BoundField, entity: RegistryEntity) -> RegistryProperty {
        entity.properties.first(where: {
            $0.notionPropertyId == field.propertyId || $0.notionName == field.notionName
        }) ?? RegistryProperty(
            key: field.notionName, notionName: field.notionName,
            notionPropertyId: field.propertyId, type: field.type)
    }

    func isolateRestFields(
        _ rest: [BoundField], pageId: String, workspace: String?, entity: RegistryEntity
    ) async -> (row: NotionRow?, applied: [String], failed: [RegistryFieldFailure]) {
        var row: NotionRow?
        var applied: [String] = []
        var failed: [RegistryFieldFailure] = []
        for field in rest {
            let key = Self.canonicalKey(for: field, entity: entity)
            do {
                row = try await gateway.update(pageId: pageId, workspace: workspace, fields: [field])
                applied.append(key)
            } catch {
                failed.append(RegistryFieldFailure(
                    field: key, reason: String(describing: error)))
            }
        }
        return (row, applied, failed)
    }

    // MARK: - Update

    @discardableResult
    public func update(entity: RegistryEntity, pageId: String, fields input: [String: Value]) async throws -> CachedRow {
        let env = try await updateReporting(entity: entity, pageId: pageId, fields: input)
        guard let row = env.row else {
            throw RegistryWriteError.noWritableFields(entity: entity.key)
        }
        return row
    }

    /// Update with the same applied/failed envelope as create (#233). Non-encodable
    /// fields (files/verification/place) are listed in `failed` instead of dropped.
    public func updateReporting(
        entity: RegistryEntity, pageId: String, fields input: [String: Value]
    ) async throws -> RegistryCreateEnvelope {
        let r = Self.resolve(input, entity: entity)
        if !r.unknown.isEmpty { throw RegistryWriteError.unknownFields(entity: entity.key, keys: r.unknown) }
        if !r.unbound.isEmpty { throw RegistryWriteError.notFullyBound(entity: entity.key, unbound: r.unbound) }
        if r.fields.isEmpty { throw RegistryWriteError.noWritableFields(entity: entity.key) }

        var failed: [RegistryFieldFailure] = []
        var encodable: [BoundField] = []
        for field in r.fields {
            let key = Self.canonicalKey(for: field, entity: entity)
            if RegistryPropertyCodec.encode(type: field.type, value: field.value) == nil {
                failed.append(RegistryFieldFailure(
                    field: key,
                    reason: "non_encodable_type:\(field.type)"))
            } else {
                encodable.append(field)
            }
        }
        if encodable.isEmpty { throw RegistryWriteError.noWritableFields(entity: entity.key) }

        let live = try await gateway.update(pageId: pageId, workspace: entity.workspace, fields: encodable)
        let classified = Self.classifyFields(encodable, on: live, entity: entity)
        failed.append(contentsOf: classified.failed)
        let cached = await RegistryReader.store(live, entity: entity, into: cache)
        let state: RegistryCreateEnvelope.State = failed.isEmpty ? .complete : .partial
        return RegistryCreateEnvelope(
            state: state, row: cached, applied: classified.applied, failed: failed)
    }

    // MARK: - Delete (soft archive + cache evict)

    public func delete(entity: RegistryEntity, pageId: String) async throws {
        try await gateway.archive(pageId: pageId, workspace: entity.workspace)
        await cache.evict(entity: entity.key, pageId: pageId)
    }

    // MARK: - Update by id, with optional append-merge (Notion/Registry Tool Ergonomics Pass)

    /// `update(entity:pageId:fields:)` plus an OPTIONAL `appendKeys` merge pass,
    /// reusing `RegistryAppendMerge.merge` — the SAME primitive
    /// `resolveAndUpdate` uses — so `registry_update` gets append-vs-overwrite
    /// parity with `registry_resolve_and_update` without duplicating the merge
    /// logic. When `appendKeys` is `nil`, this is byte-identical to plain
    /// `update` (no extra read, no behavior change) — additive/backward-compatible.
    /// When non-nil (including `[]`, which disables merging for every key, same
    /// as `resolveAndUpdate`), the row's CURRENT properties are read first (not
    /// force-refreshed — same cache posture as `resolveAndUpdate`'s `reader.find`)
    /// so append targets the live value, not a stale write-time guess.
    @discardableResult
    public func update(
        entity: RegistryEntity,
        pageId: String,
        fields input: [String: Value],
        reader: RegistryReader,
        appendKeys: Set<String>?
    ) async throws -> CachedRow {
        guard let appendKeys else {
            return try await update(entity: entity, pageId: pageId, fields: input)
        }
        let current = try await reader.get(entity: entity, pageId: pageId)
        let merged = RegistryAppendMerge.merge(
            proposed: input, existing: current.properties, appendKeys: appendKeys)
        return try await update(entity: entity, pageId: pageId, fields: merged)
    }

    // MARK: - Resolve + append-merge + update (PKT-MEM-135)

    public enum RegistryResolveError: Error, LocalizedError, Equatable {
        /// `where` matched zero rows — mirrors `registry_find`'s "no match" case,
        /// but as an ERROR here (unlike `registry_find`, a resolve-and-update
        /// with nothing to update is not a valid empty result).
        case noMatch(entity: String, predicateKeys: [String])
        /// `where` matched ≥2 rows — mirrors `registry_find`'s ambiguous case.
        /// The caller must disambiguate (narrow `where`, or use registry_find +
        /// registry_update directly with the chosen id) — no write is attempted.
        case ambiguous(entity: String, predicateKeys: [String], matchCount: Int, matchedIds: [String])
        public var errorDescription: String? {
            switch self {
            case .noMatch(let e, let keys):
                return "no ‘\(e)’ row matched where=\(keys.sorted()) — nothing to update"
            case .ambiguous(let e, let keys, let count, let ids):
                return "ambiguous ‘\(e)’ target: where=\(keys.sorted()) matched \(count) rows \(ids.sorted()) — narrow the predicate before writing"
            }
        }
    }

    /// Resolve a row by `registry_find`-identical predicate matching, merge
    /// append-style fields against the resolved row's CURRENT projected values
    /// (`RegistryAppendMerge` — no separate `registry_get` round trip; the
    /// `find` match already carries the full projection), then write. One call
    /// replaces the find → get → update three-round-trip pattern.
    ///
    /// Ambiguity contract (must match `registry_find` exactly, packet
    /// GOAL_CONDITION): 1 match → resolve + write; 0 matches → `.noMatch`, NO
    /// write; ≥2 matches → `.ambiguous`, NO write.
    @discardableResult
    public func resolveAndUpdate(
        entity: RegistryEntity,
        reader: RegistryReader,
        predicates: [String: Value],
        fields input: [String: Value],
        appendKeys: Set<String> = RegistryAppendMerge.defaultAppendKeys,
        now: Date = Date()
    ) async throws -> (row: CachedRow, matchedId: String) {
        let matches = try await reader.find(entity: entity, predicates: predicates, limit: 500)
        guard !matches.isEmpty else {
            throw RegistryResolveError.noMatch(entity: entity.key, predicateKeys: Array(predicates.keys))
        }
        guard matches.count == 1, let matched = matches.first else {
            throw RegistryResolveError.ambiguous(
                entity: entity.key, predicateKeys: Array(predicates.keys),
                matchCount: matches.count, matchedIds: matches.map { $0.pageId })
        }
        let merged = RegistryAppendMerge.merge(
            proposed: input, existing: matched.properties, appendKeys: appendKeys, now: now)
        let row = try await update(entity: entity, pageId: matched.pageId, fields: merged)
        return (row, matched.pageId)
    }
}

/// The append-merge primitive (PKT-MEM-135): for a configured set of
/// "append-style" canonical field keys, a write's value is APPENDED to the
/// row's current value (stamped block, never silently overwritten); every
/// other key passes through as a plain overwrite — unchanged Bridge write
/// semantics elsewhere in the registry.
///
/// Extracted from `VoiceMemoProcessor.mergeAppendRegistryFields` +
/// `VoiceMemoParser.appendVoiceMemoLog` (VoiceMemoProcessor.swift:524-549) so
/// `registry_resolve_and_update` reuses the EXACT SAME "existing value + new
/// content, dated block" behavior, byte-for-byte, without introducing a
/// Registry→VoiceMemo module coupling (Registry and VoiceMemo remain
/// decoupled — VoiceMemo talks to Registry only through MCP dispatch, never a
/// direct Swift symbol reference; this is a deliberate port, not a shim).
/// `VoiceMemoProcessor` itself is UNCHANGED by this packet (Scope OUT).
public enum RegistryAppendMerge {
    /// The default append-style keys, ported verbatim from
    /// `VoiceMemoProcessor.mergeAppendRegistryFields`'s hardcoded set. Callers
    /// of `registry_resolve_and_update` may override this via `appendKeys`.
    public static let defaultAppendKeys: Set<String> = ["brief", "objective", "summary", "description"]

    /// Merge `proposed` against `existing` (the resolved row's CURRENT
    /// projected properties, a `Value.object`): for each key in `proposed`
    /// that is also in `appendKeys`, replace its value with
    /// `appendBlock(existing:newContent:now:)` applied to the row's current
    /// string value for that key (empty/non-string existing ⇒ treated as
    /// empty, matching `mergeAppendRegistryFields`'s `if case .string(let s)?
    /// = props[key] { existing = s }` — a non-string or absent existing value
    /// never throws, it just starts the log fresh). Keys not in `appendKeys`
    /// (or absent from `existing`) pass through unchanged (overwrite).
    public static func merge(
        proposed: [String: Value],
        existing: Value,
        appendKeys: Set<String> = defaultAppendKeys,
        now: Date = Date()
    ) -> [String: Value] {
        guard !appendKeys.isEmpty, proposed.keys.contains(where: appendKeys.contains) else { return proposed }
        var existingProps: [String: Value] = [:]
        if case .object(let o) = existing { existingProps = o }
        var merged = proposed
        for (key, newValue) in proposed where appendKeys.contains(key) {
            // Append-style fields are text logs — a non-string proposed value
            // has nothing meaningful to append text to; pass it through as a
            // plain overwrite rather than coercing/throwing.
            guard case .string(let newContent) = newValue else { continue }
            var existingText = ""
            if case .string(let s)? = existingProps[key] { existingText = s }
            merged[key] = .string(appendBlock(existing: existingText, newContent: newContent, now: now))
        }
        return merged
    }

    /// Byte-for-byte port of `VoiceMemoParser.appendVoiceMemoLog`: a dated
    /// block (`— Voice memo <YYYY-MM-DD>:\n<trimmed content>`) appended after
    /// a blank line to the existing text; an empty/whitespace-only existing
    /// value returns just the block (no leading separator).
    public static func appendBlock(existing: String?, newContent: String, now: Date = Date()) -> String {
        let stamp = ISO8601DateFormatter().string(from: now).prefix(10)
        let block = "— Voice memo \(stamp):\n\(newContent.trimmingCharacters(in: .whitespacesAndNewlines))"
        guard let existing = existing?.trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty else {
            return block
        }
        return existing + "\n\n" + block
    }
}
