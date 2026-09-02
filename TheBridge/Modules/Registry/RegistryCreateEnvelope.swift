// RegistryCreateEnvelope.swift — issue #138
// TheBridge · Modules · Registry
//
// Uniform create receipt so a title-only page that then fails a relation or
// property PATCH is never reported as "nothing happened." Callers get the
// live URL and can repair instead of re-issuing create.

import Foundation
import MCP

/// One field that did not land on the created (or not-created) row.
public struct RegistryFieldFailure: Sendable, Equatable {
    public let field: String
    public let reason: String
    public init(field: String, reason: String) {
        self.field = field
        self.reason = reason
    }

    public var asValue: Value {
        .object(["field": .string(field), "reason": .string(reason)])
    }
}

/// Outcome of `registry_create` after relation preflight + create-then-update.
public struct RegistryCreateEnvelope: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case complete
        case partial
        case none
    }

    public var state: State
    public var row: CachedRow?
    public var applied: [String]
    public var failed: [RegistryFieldFailure]

    public init(state: State, row: CachedRow?, applied: [String], failed: [RegistryFieldFailure]) {
        self.state = state
        self.row = row
        self.applied = applied
        self.failed = failed
    }

    /// Present whenever a Notion page was created, including `partial`.
    public var entityUrl: String? {
        guard let row, !row.url.isEmpty else { return nil }
        return row.url
    }

    public func asValue(projectedRow: Value?) -> Value {
        var out: [String: Value] = [
            "state": .string(state.rawValue),
            "applied": .array(applied.map { .string($0) }),
            "failed": .array(failed.map(\.asValue)),
            "created": .bool(state == .complete),
            "partialFailure": .bool(state == .partial),
        ]
        if let entityUrl { out["entityUrl"] = .string(entityUrl) }
        if let projectedRow { out["row"] = projectedRow }
        return .object(out)
    }

    /// Same receipt as create, with `updated` instead of `created` (#233).
    public func asUpdateValue(projectedRow: Value?) -> Value {
        var out: [String: Value] = [
            "state": .string(state.rawValue),
            "applied": .array(applied.map { .string($0) }),
            "failed": .array(failed.map(\.asValue)),
            "updated": .bool(state == .complete),
            "partialFailure": .bool(state == .partial),
        ]
        if let entityUrl { out["entityUrl"] = .string(entityUrl) }
        if let projectedRow { out["row"] = projectedRow }
        return .object(out)
    }
}

/// Whether a requested write matches the value Notion actually stored.
public enum FieldWriteOutcome: Sendable, Equatable {
    case applied
    case canonicalized
    case rejected(String)
}
