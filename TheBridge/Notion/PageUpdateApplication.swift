// PageUpdateApplication.swift — issue #138
// TheBridge · Notion
//
// Distinguishes a PATCH that Notion rewrote (canonicalized) from one that
// genuinely dropped or rejected fields. Callers must not treat those as the
// same "partially applied" bucket.

import Foundation
import MCP

public struct PageUpdateClassification: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case applied
        case canonicalized
        case rejected
    }

    public var status: Status
    public var applied: [String]
    public var canonicalized: [String]
    public var rejected: [RegistryFieldFailure]

    public init(status: Status, applied: [String], canonicalized: [String], rejected: [RegistryFieldFailure]) {
        self.status = status
        self.applied = applied
        self.canonicalized = canonicalized
        self.rejected = rejected
    }

    /// HTTP 200 plus only canonical rewrites is still success.
    public var success: Bool { rejected.isEmpty }

    public var asValue: [String: Value] {
        [
            "status": .string(status.rawValue),
            "applied": .array(applied.map { .string($0) }),
            "canonicalized": .array(canonicalized.map { .string($0) }),
            "rejected": .array(rejected.map(\.asValue)),
        ]
    }
}

public enum PageUpdateApplication {
    /// Classify each requested property against the PATCH response page.
    /// `requested` is the caller-supplied Notion property map (the object
    /// inside `{"properties": …}`). `returnedPage` is the full page JSON.
    public static func classify(requested: [String: Any], returnedPage: [String: Any]) -> PageUpdateClassification {
        let returnedProps = returnedPage["properties"] as? [String: Any] ?? [:]
        var applied: [String] = []
        var canonicalized: [String] = []
        var rejected: [RegistryFieldFailure] = []

        for key in requested.keys.sorted() {
            guard let reqRaw = requested[key] else { continue }
            guard let retProp = returnedProps[key] as? [String: Any] else {
                rejected.append(RegistryFieldFailure(field: key, reason: "not present on page"))
                continue
            }
            let type = (retProp["type"] as? String) ?? inferType(fromRequested: reqRaw)
            let requestedValue = decodeRequested(type: type, raw: reqRaw)
            let actualValue = RegistryPropertyCodec.decode(type: type, property: retProp)
            switch RegistryPropertyCodec.classifyWrite(type: type, requested: requestedValue, actual: actualValue) {
            case .applied:
                applied.append(key)
            case .canonicalized:
                canonicalized.append(key)
            case .rejected(let reason):
                rejected.append(RegistryFieldFailure(field: key, reason: reason))
            }
        }

        let status: PageUpdateClassification.Status
        if !rejected.isEmpty {
            status = .rejected
        } else if !canonicalized.isEmpty {
            status = .canonicalized
        } else {
            status = .applied
        }
        return PageUpdateClassification(
            status: status, applied: applied, canonicalized: canonicalized, rejected: rejected)
    }

    static func inferType(fromRequested raw: Any) -> String {
        guard let obj = raw as? [String: Any] else { return "" }
        if obj["title"] != nil { return "title" }
        if obj["rich_text"] != nil { return "rich_text" }
        if obj["status"] != nil { return "status" }
        if obj["select"] != nil { return "select" }
        if obj["multi_select"] != nil { return "multi_select" }
        if obj["relation"] != nil { return "relation" }
        if obj["people"] != nil { return "people" }
        if obj["number"] != nil { return "number" }
        if obj["checkbox"] != nil { return "checkbox" }
        if obj["date"] != nil { return "date" }
        if obj["url"] != nil { return "url" }
        if obj["email"] != nil { return "email" }
        if obj["phone_number"] != nil { return "phone_number" }
        return ""
    }

    static func decodeRequested(type: String, raw: Any) -> Value {
        guard var obj = raw as? [String: Any] else { return .null }
        if obj["type"] == nil, !type.isEmpty { obj["type"] = type }
        let decodeType = (obj["type"] as? String) ?? type
        return RegistryPropertyCodec.decode(type: decodeType, property: obj)
    }
}
