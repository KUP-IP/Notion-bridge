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
        public var errorDescription: String? {
            switch self {
            case .notFullyBound(let e, let u):
                return "entity ‘\(e)’ has unbound properties \(u) — run introspection first"
            case .unknownFields(let e, let k):
                return "entity ‘\(e)’ has no properties \(k)"
            case .noWritableFields(let e):
                return "no writable fields supplied for ‘\(e)’"
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

    @discardableResult
    public func create(entity: RegistryEntity, fields input: [String: Value]) async throws -> CachedRow {
        let r = Self.resolve(input, entity: entity)
        if !r.unknown.isEmpty { throw RegistryWriteError.unknownFields(entity: entity.key, keys: r.unknown) }
        if !r.unbound.isEmpty { throw RegistryWriteError.notFullyBound(entity: entity.key, unbound: r.unbound) }
        if r.fields.isEmpty || !Self.hasEncodable(r.fields) { throw RegistryWriteError.noWritableFields(entity: entity.key) }

        let titleFields = r.fields.filter { $0.isTitle }
        let rest = r.fields.filter { !$0.isTitle }

        // Create-then-update: seed the page with the title, then PATCH the rest.
        let created = try await gateway.create(
            dataSourceId: entity.dataSourceId, workspace: entity.workspace,
            fields: titleFields.isEmpty ? r.fields : titleFields)
        // Cache the titled row immediately, so if the follow-up PATCH throws the
        // created page isn't an invisible orphan — a retry/read still sees it.
        // (Notion has no multi-call transaction; this is the best-effort guard.)
        _ = await RegistryReader.store(created, entity: entity, into: cache)
        var row = created
        if !titleFields.isEmpty, !rest.isEmpty {
            row = try await gateway.update(pageId: created.id, workspace: entity.workspace, fields: rest)
        }
        return await RegistryReader.store(row, entity: entity, into: cache)
    }

    // MARK: - Update

    @discardableResult
    public func update(entity: RegistryEntity, pageId: String, fields input: [String: Value]) async throws -> CachedRow {
        let r = Self.resolve(input, entity: entity)
        if !r.unknown.isEmpty { throw RegistryWriteError.unknownFields(entity: entity.key, keys: r.unknown) }
        if !r.unbound.isEmpty { throw RegistryWriteError.notFullyBound(entity: entity.key, unbound: r.unbound) }
        if r.fields.isEmpty || !Self.hasEncodable(r.fields) { throw RegistryWriteError.noWritableFields(entity: entity.key) }
        let row = try await gateway.update(pageId: pageId, workspace: entity.workspace, fields: r.fields)
        return await RegistryReader.store(row, entity: entity, into: cache)
    }

    // MARK: - Delete (soft archive + cache evict)

    public func delete(entity: RegistryEntity, pageId: String) async throws {
        try await gateway.archive(pageId: pageId, workspace: entity.workspace)
        await cache.evict(entity: entity.key, pageId: pageId)
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
