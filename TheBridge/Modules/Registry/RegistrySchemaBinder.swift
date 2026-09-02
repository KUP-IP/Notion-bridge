// RegistrySchemaBinder.swift — Data-Source Registry (Wave 2)
// TheBridge · Modules · Registry
//
// The introspection core (Decision 5 + Decision 9). Given an entity's declared
// property map and a live data source schema, MATCH properties by display name
// → bind their PROPERTY IDs, and report drift:
//   • unmatched — a declared property whose name is absent from the live schema
//     (a rename the binding can't follow, or a missing column).
//   • typeMismatch — a property bound by name whose live type differs from the
//     declared type (Decision 9: "validate property types against live schema
//     on every sync cycle; alert on mismatch" — a silent type change that would
//     break reads/writes).
//
// Pure value logic — no network — so the binding + drift rules are unit-tested
// deterministically. The live introspection (fetching the schema) is the
// gateway's job; this binds the result.

import Foundation

/// A drift finding from binding an entity against a live schema.
public enum RegistryDrift: Sendable, Equatable {
    /// Declared property `key` (Notion name `notionName`) not found in the live
    /// schema by name. The binding is left unbound; reads/writes of this field
    /// are skipped until resolved.
    case unmatched(key: String, notionName: String)
    /// Property `key` matched by name but the live type changed.
    case typeMismatch(key: String, expected: String, actual: String)

    /// Human-readable one-liner for UI/logging.
    public var message: String {
        switch self {
        case .unmatched(let key, let name):
            return "‘\(key)’ → no column named “\(name)” in the data source"
        case .typeMismatch(let key, let expected, let actual):
            return "‘\(key)’ type drift: declared \(expected), live \(actual)"
        }
    }
}

/// Result of binding an entity to a schema: the entity with property ids
/// resolved where matched, plus any drift.
public struct RegistryBindResult: Sendable, Equatable {
    public let entity: RegistryEntity
    public let drift: [RegistryDrift]
    public init(entity: RegistryEntity, drift: [RegistryDrift]) {
        self.entity = entity
        self.drift = drift
    }

    /// True when every declared property bound cleanly (no unmatched) — the
    /// entity is ready for cache-backed reads/writes. Type mismatches are
    /// surfaced as warnings but do not block (a `select`→`status` change still
    /// has an id; the codec degrades gracefully).
    public var isClean: Bool {
        !drift.contains {
            if case .unmatched = $0 { return true }
            return false
        }
    }

    public var hasDrift: Bool { !drift.isEmpty }
}

public enum RegistrySchemaBinder {
    /// Bind `entity`'s properties against `schema`. Name match first (fresh
    /// id). If the display name moved, follow the stored property **id** and
    /// update `notionName` from the live column (#234). Clear the id only when
    /// neither name nor id is in the schema (column dropped). Type drift
    /// updates the declared type to the live type so writes use the current
    /// codec, and is still reported.
    public static func bind(_ entity: RegistryEntity, to schema: DataSourceSchema) -> RegistryBindResult {
        var drift: [RegistryDrift] = []
        var rebound = entity
        rebound.properties = entity.properties.map { prop in
            var p = prop
            if let col = schema.column(named: prop.notionName) {
                applyLiveColumn(&p, prop: prop, column: col, drift: &drift)
            } else if let id = prop.notionPropertyId, !id.isEmpty,
                      let found = schema.column(withID: id) {
                p.notionName = found.name
                applyLiveColumn(&p, prop: prop, column: found.column, drift: &drift)
            } else {
                p.notionPropertyId = nil
                drift.append(.unmatched(key: prop.key, notionName: prop.notionName))
            }
            return p
        }
        return RegistryBindResult(entity: rebound, drift: drift)
    }

    private static func applyLiveColumn(
        _ p: inout RegistryProperty,
        prop: RegistryProperty,
        column: DataSourceSchema.Column,
        drift: inout [RegistryDrift]
    ) {
        p.notionPropertyId = column.id
        if !prop.type.isEmpty, prop.type != column.type {
            drift.append(.typeMismatch(key: prop.key, expected: prop.type, actual: column.type))
            p.type = column.type
        }
    }

    /// Re-validate an ALREADY-bound entity against a fresh schema (Decision 9
    /// "every sync cycle"): bind ids match the live ids? types still agree? A
    /// property whose bound id is no longer present in the schema is reported
    /// unmatched even if its name still resolves (the column was replaced).
    public static func validate(_ entity: RegistryEntity, against schema: DataSourceSchema) -> [RegistryDrift] {
        bind(entity, to: schema).drift
    }
}
