// RegistryGateway.swift — Data-Source Registry (Wave 2)
// TheBridge · Modules · Registry
//
// The seam between the registry and Notion. A protocol so the reader/writer
// are unit-tested against a deterministic fake (no network), and a live impl
// that resolves the per-entity connection (Decision 8 — workspace-agnostic,
// resolved at the connection layer) and routes EVERY call through the central
// `RegistryRateLimiter` (Decision 4 — global 2 req/s ceiling).
//
// The boundary is fully Sendable: raw `[String: Any]` Notion JSON is decoded
// into `NotionRow`/`DataSourceSchema` here, and writes arrive as `[BoundField]`
// (typed `Value`s + bound ids) which the live impl encodes via the codec.

import Foundation
import MCP

public enum RegistryGatewayError: Error, LocalizedError, Equatable {
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse(let reason): return "registry gateway response invalid: \(reason)"
        }
    }
}

public enum RegistryRowResponseDecoder {
    public static func decode(_ data: Data, context: String) throws -> NotionRow {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RegistryGatewayError.invalidResponse("\(context) is not a JSON object")
        }
        return try decode(object, context: context)
    }

    public static func decode(_ object: [String: Any], context: String) throws -> NotionRow {
        guard let id = object["id"] as? String, !id.isEmpty else {
            throw RegistryGatewayError.invalidResponse("\(context) is missing a nonempty page id")
        }
        guard object["properties"] is [String: Any] else {
            throw RegistryGatewayError.invalidResponse("\(context) is missing a properties object for page \(id)")
        }
        let row = RegistryRowDecoder.row(from: object)
        guard !row.id.isEmpty else {
            throw RegistryGatewayError.invalidResponse("\(context) decoded an empty page id")
        }
        return row
    }
}

public enum RegistryQueryResponseDecoder {
    public static func decode(_ data: Data) throws -> (rows: [NotionRow], nextCursor: String?) {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]],
              let hasMore = object["has_more"] as? Bool else {
            throw RegistryGatewayError.invalidResponse("Notion query response is missing results or has_more")
        }
        let next: String?
        if hasMore {
            guard let cursor = object["next_cursor"] as? String, !cursor.isEmpty else {
                throw RegistryGatewayError.invalidResponse("Notion query response has_more=true without next_cursor")
            }
            next = cursor
        } else {
            next = nil
        }
        let rows = try results.enumerated().map { index, object in
            try RegistryRowResponseDecoder.decode(object, context: "Notion query result[\(index)]")
        }
        return (rows, next)
    }
}

public protocol RegistryNotionGateway: Sendable {
    var supportsAuthoritativeFiltering: Bool { get }
    func schema(dataSourceId: String, workspace: String?) async throws -> DataSourceSchema
    func query(dataSourceId: String, workspace: String?, pageSize: Int, startCursor: String?) async throws -> (rows: [NotionRow], nextCursor: String?)
    func query(dataSourceId: String, workspace: String?, filter: Data, pageSize: Int, startCursor: String?) async throws -> (rows: [NotionRow], nextCursor: String?)
    func page(pageId: String, workspace: String?) async throws -> NotionRow
    func create(dataSourceId: String, workspace: String?, fields: [BoundField]) async throws -> NotionRow
    func update(pageId: String, workspace: String?, fields: [BoundField]) async throws -> NotionRow
    func archive(pageId: String, workspace: String?) async throws
    func markdown(pageId: String, workspace: String?) async throws -> String
    func writeMarkdown(pageId: String, workspace: String?, markdown: String) async throws
}

public extension RegistryNotionGateway {
    var supportsAuthoritativeFiltering: Bool { false }

    func query(dataSourceId: String, workspace: String?) async throws -> [NotionRow] {
        try await query(dataSourceId: dataSourceId, workspace: workspace, pageSize: 100, startCursor: nil).rows
    }

    /// Default compatibility path for test gateways. LiveRegistryGateway overrides
    /// this and sends the filter to Notion. The default never claims server-side
    /// filtering; callers that require a live authoritative lookup should use a
    /// gateway implementation that overrides this method.
    func query(dataSourceId: String, workspace: String?, filter: Data, pageSize: Int, startCursor: String?) async throws -> (rows: [NotionRow], nextCursor: String?) {
        try await query(dataSourceId: dataSourceId, workspace: workspace, pageSize: pageSize, startCursor: startCursor)
    }
}

/// Production gateway: `NotionClientRegistry` for the connection + the shared
/// rate limiter for every call.
public struct LiveRegistryGateway: RegistryNotionGateway {
    public var supportsAuthoritativeFiltering: Bool { true }
    private let limiter: RegistryRateLimiter

    public init(limiter: RegistryRateLimiter = .shared) {
        self.limiter = limiter
    }

    private func client(_ workspace: String?) async throws -> NotionClient {
        try await NotionClientRegistry.shared.getClient(workspace: workspace)
    }

    public func schema(dataSourceId: String, workspace: String?) async throws -> DataSourceSchema {
        let c = try await client(workspace)
        let data = try await limiter.throttled { try await c.getDataSource(dataSourceId: dataSourceId) }
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return RegistryRowDecoder.schema(from: obj)
    }

    public func query(dataSourceId: String, workspace: String?, pageSize: Int, startCursor: String?) async throws -> (rows: [NotionRow], nextCursor: String?) {
        let c = try await client(workspace)
        let data = try await limiter.throttled {
            try await c.queryDataSource(dataSourceId: dataSourceId, pageSize: pageSize, startCursor: startCursor)
        }
        return try RegistryQueryResponseDecoder.decode(data)
    }

    public func query(dataSourceId: String, workspace: String?, filter: Data, pageSize: Int, startCursor: String?) async throws -> (rows: [NotionRow], nextCursor: String?) {
        let c = try await client(workspace)
        let data = try await limiter.throttled {
            try await c.queryDataSource(
                dataSourceId: dataSourceId, filter: filter,
                pageSize: pageSize, startCursor: startCursor
            )
        }
        return try RegistryQueryResponseDecoder.decode(data)
    }

    public func page(pageId: String, workspace: String?) async throws -> NotionRow {
        let c = try await client(workspace)
        let data = try await limiter.throttled { try await c.getPage(pageId: pageId) }
        return try RegistryRowResponseDecoder.decode(data, context: "Notion page response")
    }

    public func create(dataSourceId: String, workspace: String?, fields: [BoundField]) async throws -> NotionRow {
        let c = try await client(workspace)
        let data = try await limiter.throttled {
            try await c.createPage(parentId: dataSourceId, parentType: "data_source_id", properties: try Self.createBody(fields))
        }
        return try RegistryRowResponseDecoder.decode(data, context: "Notion create response")
    }

    public func update(pageId: String, workspace: String?, fields: [BoundField]) async throws -> NotionRow {
        let c = try await client(workspace)
        let body = try Self.updateBody(fields)
        let data = try await limiter.throttled { try await c.updatePage(pageId: pageId, properties: body) }
        return try RegistryRowResponseDecoder.decode(data, context: "Notion update response")
    }

    public func archive(pageId: String, workspace: String?) async throws {
        let c = try await client(workspace)
        // A Notion page is a block; DELETE /blocks/{id} archives it (Decision 8
        // delete = soft archive; a hard delete is never issued).
        _ = try await limiter.throttled { try await c.deleteBlock(blockId: pageId) }
    }

    public func markdown(pageId: String, workspace: String?) async throws -> String {
        let c = try await client(workspace)
        let data = try await limiter.throttled { try await c.getPageMarkdown(pageId: pageId) }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let md = obj["markdown"] as? String { return md }
            if let content = obj["content"] as? String { return content }
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func writeMarkdown(pageId: String, workspace: String?, markdown: String) async throws {
        let c = try await client(workspace)
        _ = try await limiter.throttled {
            try await c.replacePageMarkdown(pageId: pageId, markdown: markdown)
        }
    }

    /// Build the `{"PROPERTY_NAME": <payload>}` envelope from bound fields,
    /// skipping read-only/unsupported types and anything not yet bound.
    ///
    /// Keyed by property NAME, NOT id. Notion returns property ids in
    /// percent-encoded form for ids containing special characters (e.g. a
    /// property whose id is `AH\`N` comes back as `AH%60N`), and that encoded id
    /// does NOT round-trip as a WRITE key — Notion silently ignores it (no
    /// error, no write). Property NAMES are accepted reliably for writes. The
    /// bound id is still required here (proves the field was introspected) and
    /// still drives read-projection + rename detection; only the write KEY uses
    /// the current name. `f.propertyId` empty ⇒ unbound ⇒ skipped (the writer
    /// already fails such writes fast).
    public static func encodeEnvelope(_ fields: [BoundField]) -> [String: Any] {
        var out: [String: Any] = [:]
        for f in fields {
            guard !f.propertyId.isEmpty, !f.notionName.isEmpty,
                  let payload = RegistryPropertyCodec.encode(type: f.type, value: f.value)
            else { continue }
            out[f.notionName] = payload
        }
        return out
    }

    /// The body for `NotionClient.createPage(properties:)`, which WRAPS the
    /// passed dict under `{"parent":…, "properties": <dict>}` itself — so this
    /// passes the RAW property envelope (no `properties` wrapper here).
    public static func createBody(_ fields: [BoundField]) throws -> Data {
        try JSONSerialization.data(withJSONObject: encodeEnvelope(fields))
    }

    /// The body for `NotionClient.updatePage(properties:)`, which sends its arg
    /// AS the PATCH body UNWRAPPED — so the `{"properties": …}` wrapper MUST be
    /// added here. (Asymmetry with createPage; a missing wrapper makes Notion
    /// silently ignore the write — the live-smoke bug this fixes.)
    public static func updateBody(_ fields: [BoundField]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["properties": encodeEnvelope(fields)])
    }
}
