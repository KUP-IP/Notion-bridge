// NotionModule.swift – V1-05 → V1-12 Notion Integration Tools
// KeeprBridge · Modules
//
// Three tools: notion_search (green), notion_page_read (green),
// notion_page_update (orange).
// Uses NotionClient actor for rate-limited API access.
// PKT-320: Updated references from NOTION_API_KEY to NOTION_API_TOKEN,
//          token resolution now supports env var + config file fallback

import Foundation
import MCP

// MARK: - NotionModule

/// Provides Notion workspace integration tools.
/// Requires NOTION_API_TOKEN environment variable or config file token.
public enum NotionModule {

    public static let moduleName = "notion"

    /// Register all NotionModule tools on the given router.
    /// Lazily initializes NotionClient on first tool invocation.
    public static func register(on router: ToolRouter) async {

        // Lazy client — initialized once on first use
        let clientHolder = NotionClientHolder()

        // MARK: 1. notion_search – 🟢 Green
        await router.register(ToolRegistration(
            name: "notion_search",
            module: moduleName,
            tier: .open,
            description: "Search the Notion workspace for pages and databases by query. Returns matching results with titles and URLs. Requires NOTION_API_TOKEN.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string"), "description": .string("Search query text")]),
                    "pageSize": .object(["type": .string("integer"), "description": .string("Max results to return (default: 10, max: 100)")])
                ]),
                "required": .array([.string("query")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let query) = args["query"] else {
                    throw ToolRouterError.unknownTool("notion_search: missing 'query'")
                }
                let pageSize: Int = { if case .int(let ps) = args["pageSize"] { return min(ps, 100) }; return 10 }()

                let client = try clientHolder.getClient()
                let data = try await client.search(query: query, pageSize: pageSize)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let results = json["results"] as? [[String: Any]] else {
                    return .object(["error": .string("Failed to parse search response")])
                }

                var items: [Value] = []
                for result in results {
                    let id = result["id"] as? String ?? ""
                    let objectType = result["object"] as? String ?? ""
                    let url = result["url"] as? String ?? ""

                    var title = "Untitled"
                    if let properties = result["properties"] as? [String: Any] {
                        title = NotionJSON.extractTitle(from: properties)
                    } else if let titleArr = result["title"] as? [[String: Any]] {
                        // Database titles
                        title = titleArr.compactMap { $0["plain_text"] as? String }.joined()
                    }

                    items.append(.object([
                        "id": .string(id),
                        "type": .string(objectType),
                        "title": .string(title),
                        "url": .string(url)
                    ]))
                }

                return .object([
                    "query": .string(query),
                    "count": .int(items.count),
                    "results": .array(items)
                ])
            }
        ))

        // MARK: 2. notion_page_read – 🟢 Green
        await router.register(ToolRegistration(
            name: "notion_page_read",
            module: moduleName,
            tier: .open,
            description: "Read a Notion page's properties and child blocks by page ID. Returns page metadata and content blocks.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pageId": .object(["type": .string("string"), "description": .string("Notion page ID (with or without dashes)")]),
                    "includeBlocks": .object(["type": .string("boolean"), "description": .string("Whether to also fetch child blocks (default: true)")])
                ]),
                "required": .array([.string("pageId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let pageId) = args["pageId"] else {
                    throw ToolRouterError.unknownTool("notion_page_read: missing 'pageId'")
                }
                let includeBlocks: Bool = {
                    if case .bool(let b) = args["includeBlocks"] { return b }
                    return true
                }()

                let client = try clientHolder.getClient()

                // Fetch page properties
                let pageData = try await client.getPage(pageId: pageId)
                guard let pageJSON = try? JSONSerialization.jsonObject(with: pageData) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse page response")])
                }

                let id = pageJSON["id"] as? String ?? pageId
                let url = pageJSON["url"] as? String ?? ""

                var title = "Untitled"
                if let properties = pageJSON["properties"] as? [String: Any] {
                    title = NotionJSON.extractTitle(from: properties)
                }

                var result: [String: Value] = [
                    "id": .string(id),
                    "url": .string(url),
                    "title": .string(title),
                    "properties": .string(NotionJSON.prettyPrint(pageJSON["properties"] ?? [:]))
                ]

                // Optionally fetch blocks
                if includeBlocks {
                    let blocksData = try await client.getBlocks(blockId: pageId)
                    guard let blocksJSON = try? JSONSerialization.jsonObject(with: blocksData) as? [String: Any],
                          let blockResults = blocksJSON["results"] as? [[String: Any]] else {
                        result["blocks"] = .string("Failed to parse blocks")
                        return .object(result)
                    }

                    var blocks: [Value] = []
                    for block in blockResults {
                        let blockId = block["id"] as? String ?? ""
                        let blockType = block["type"] as? String ?? ""
                        let hasChildren = block["has_children"] as? Bool ?? false

                        // Extract block text content
                        var textContent = ""
                        if let typeData = block[blockType] as? [String: Any],
                           let richText = typeData["rich_text"] as? [[String: Any]] {
                            textContent = richText.compactMap { $0["plain_text"] as? String }.joined()
                        }

                        blocks.append(.object([
                            "id": .string(blockId),
                            "type": .string(blockType),
                            "hasChildren": .bool(hasChildren),
                            "text": .string(textContent)
                        ]))
                    }

                    result["blocks"] = .array(blocks)
                    result["blockCount"] = .int(blocks.count)
                }

                return .object(result)
            }
        ))

        // MARK: 3. notion_page_update – 🟠 Orange (Write-Confirm)
        await router.register(ToolRegistration(
            name: "notion_page_update",
            module: moduleName,
            tier: .notify,
            description: "Update a Notion page's properties. Accepts a JSON string of property updates. SecurityGate enforces orange-tier confirmation.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pageId": .object(["type": .string("string"), "description": .string("Notion page ID (with or without dashes)")]),
                    "properties": .object(["type": .string("string"), "description": .string("JSON string of properties to update (Notion API format)")])
                ]),
                "required": .array([.string("pageId"), .string("properties")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let pageId) = args["pageId"],
                      case .string(let propsJSON) = args["properties"] else {
                    throw ToolRouterError.unknownTool("notion_page_update: missing 'pageId' or 'properties'")
                }

                // Validate JSON
                guard let propsData = propsJSON.data(using: .utf8),
                      let propsObj = try? JSONSerialization.jsonObject(with: propsData) as? [String: Any] else {
                    return .object(["error": .string("Invalid JSON in 'properties' parameter")])
                }

                // Wrap in {"properties": ...} envelope
                let envelope: [String: Any] = ["properties": propsObj]
                let envelopeData = try JSONSerialization.data(withJSONObject: envelope)

                let client = try clientHolder.getClient()
                let resultData = try await client.updatePage(pageId: pageId, properties: envelopeData)

                guard let resultJSON = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse update response")])
                }

                let id = resultJSON["id"] as? String ?? pageId
                let url = resultJSON["url"] as? String ?? ""

                return .object([
                    "success": .bool(true),
                    "id": .string(id),
                    "url": .string(url)
                ])
            }
        ))
    }
}

// MARK: - Lazy Client Holder

/// Thread-safe holder for lazy NotionClient initialization.
/// The client is created on first access and reused thereafter.
private final class NotionClientHolder: @unchecked Sendable {
    private var client: NotionClient?
    private let lock = NSLock()

    func getClient() throws -> NotionClient {
        lock.lock()
        defer { lock.unlock() }

        if let existing = client {
            return existing
        }

        let newClient = try NotionClient()
        client = newClient
        return newClient
    }
}
