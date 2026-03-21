// NotionModule.swift – V1-05 → V1-12 → PKT-367 Notion Integration Tools
// NotionBridge · Modules
//
// 16 tools via NotionClientRegistry for multi-workspace support.
// PKT-320: Updated references from NOTION_API_KEY to NOTION_API_TOKEN
// PKT-367: 13 new tools, NotionClientRegistry integration, optional workspace param

import Foundation
import MCP

// MARK: - NotionModule

/// Provides Notion workspace integration tools.
/// Uses NotionClientRegistry for multi-workspace token management.
public enum NotionModule {

    public static let moduleName = "notion"

    /// Register all NotionModule tools on the given router.
    /// Lazily initializes NotionClientRegistry on first tool invocation.
    public static func register(on router: ToolRouter) async {

        // Lazy registry — initialized once on first use
        let registryHolder = NotionRegistryHolder()

        // Helper: extract optional workspace parameter
        @Sendable func extractWorkspace(_ args: [String: Value]) -> String? {
            if case .string(let ws) = args["workspace"] { return ws }
            return nil
        }

        // Helper: workspace parameter schema fragment
        let workspaceParam: Value = .object([
            "type": .string("string"),
            "description": .string("Optional workspace connection name. Uses primary connection if omitted.")
        ])

        // MARK: 1. notion_search – open
        await router.register(ToolRegistration(
            name: "notion_search",
            module: moduleName,
            tier: .open,
            description: "Search the Notion workspace for pages and databases by query. Returns matching results with titles and URLs. Requires NOTION_API_TOKEN.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string"), "description": .string("Search query text")]),
                    "pageSize": .object(["type": .string("integer"), "description": .string("Max results to return (default: 10, max: 100)")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("query")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let query) = args["query"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_search", reason: "missing 'query'")
                }
                let pageSize: Int = { if case .int(let ps) = args["pageSize"] { return min(ps, 100) }; return 10 }()

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
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

        // MARK: 2. notion_page_read – open
        await router.register(ToolRegistration(
            name: "notion_page_read",
            module: moduleName,
            tier: .open,
            description: "Read a Notion page's properties and child blocks by page ID. Returns page metadata and content blocks.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pageId": .object(["type": .string("string"), "description": .string("Notion page ID (with or without dashes)")]),
                    "includeBlocks": .object(["type": .string("boolean"), "description": .string("Whether to also fetch child blocks (default: true)")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("pageId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let pageId) = args["pageId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_page_read", reason: "missing 'pageId'")
                }
                let includeBlocks: Bool = {
                    if case .bool(let b) = args["includeBlocks"] { return b }
                    return true
                }()

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))

                let pageData = try await client.getPage(pageId: pageId)
                guard let pageJSON = try? JSONSerialization.jsonObject(with: pageData) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse page response")])
                }

                let id = pageJSON["id"] as? String ?? pageId
                let url = pageJSON["url"] as? String ?? ""
                let inTrash = pageJSON["in_trash"] as? Bool ?? false

                var title = "Untitled"
                if let properties = pageJSON["properties"] as? [String: Any] {
                    title = NotionJSON.extractTitle(from: properties)
                }

                var result: [String: Value] = [
                    "id": .string(id),
                    "url": .string(url),
                    "title": .string(title),
                    "in_trash": .bool(inTrash),
                    "properties": .string(NotionJSON.prettyPrint(pageJSON["properties"] ?? [:]))
                ]

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

                        var textContent = ""
                        if let typeData = block[blockType] as? [String: Any],
                           let richText = typeData["rich_text"] as? [[String: Any]] {
                            textContent = NotionJSON.extractPlainText(from: richText)
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

        // MARK: 3. notion_page_update – notify
        await router.register(ToolRegistration(
            name: "notion_page_update",
            module: moduleName,
            tier: .notify,
            description: "Update a Notion page's properties. Accepts a JSON string of property updates. SecurityGate enforces orange-tier confirmation.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pageId": .object(["type": .string("string"), "description": .string("Notion page ID (with or without dashes)")]),
                    "properties": .object(["type": .string("string"), "description": .string("JSON string of properties to update (Notion API format)")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("pageId"), .string("properties")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let pageId) = args["pageId"],
                      case .string(let propsJSON) = args["properties"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_page_update", reason: "missing 'pageId' or 'properties'")
                }

                guard let propsData = propsJSON.data(using: .utf8),
                      let propsObj = try? JSONSerialization.jsonObject(with: propsData) as? [String: Any] else {
                    return .object(["error": .string("Invalid JSON in 'properties' parameter")])
                }

                let envelope: [String: Any] = ["properties": propsObj]
                let envelopeData = try JSONSerialization.data(withJSONObject: envelope)

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
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

        // MARK: 4. notion_page_create – notify (A3)
        await router.register(ToolRegistration(
            name: "notion_page_create",
            module: moduleName,
            tier: .notify,
            description: "Create a new Notion page under a parent page or database. Returns the created page ID and URL.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "parentId": .object(["type": .string("string"), "description": .string("Parent page or database ID")]),
                    "parentType": .object(["type": .string("string"), "description": .string("Parent type: 'page_id' or 'database_id' (default: page_id)")]),
                    "properties": .object(["type": .string("string"), "description": .string("JSON string of page properties")]),
                    "children": .object(["type": .string("string"), "description": .string("Optional JSON string of child blocks")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("parentId"), .string("properties")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let parentId) = args["parentId"],
                      case .string(let propsJSON) = args["properties"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_page_create", reason: "missing 'parentId' or 'properties'")
                }

                let parentType: String = {
                    if case .string(let pt) = args["parentType"] { return pt }
                    return "page_id"
                }()

                guard let propsData = propsJSON.data(using: .utf8) else {
                    return .object(["error": .string("Invalid JSON in 'properties'")])
                }

                var childrenData: Data? = nil
                if case .string(let childrenJSON) = args["children"] {
                    childrenData = childrenJSON.data(using: .utf8)
                }

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let resultData = try await client.createPage(
                    parentId: parentId,
                    parentType: parentType,
                    properties: propsData,
                    children: childrenData
                )

                guard let resultJSON = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse create response")])
                }

                return .object([
                    "success": .bool(true),
                    "id": .string(resultJSON["id"] as? String ?? ""),
                    "url": .string(resultJSON["url"] as? String ?? "")
                ])
            }
        ))

        // MARK: 5. notion_query – open (A4)
        await router.register(ToolRegistration(
            name: "notion_query",
            module: moduleName,
            tier: .open,
            description: "Query a Notion data source with optional filter and sort. Returns matching pages.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "dataSourceId": .object(["type": .string("string"), "description": .string("Data source ID to query")]),
                    "filter": .object(["type": .string("string"), "description": .string("Optional JSON string of filter object")]),
                    "sorts": .object(["type": .string("string"), "description": .string("Optional JSON string of sorts array")]),
                    "pageSize": .object(["type": .string("integer"), "description": .string("Max results (default: 100)")]),
                    "startCursor": .object(["type": .string("string"), "description": .string("Pagination cursor from previous query")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("dataSourceId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let dsId) = args["dataSourceId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_query", reason: "missing 'dataSourceId'")
                }

                let pageSize: Int = { if case .int(let ps) = args["pageSize"] { return min(ps, 100) }; return 100 }()
                let startCursor: String? = { if case .string(let c) = args["startCursor"] { return c }; return nil }()

                var filterData: Data? = nil
                if case .string(let f) = args["filter"] { filterData = f.data(using: .utf8) }
                var sortsData: Data? = nil
                if case .string(let s) = args["sorts"] { sortsData = s.data(using: .utf8) }

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.queryDataSource(
                    dataSourceId: dsId,
                    filter: filterData,
                    sorts: sortsData,
                    pageSize: pageSize,
                    startCursor: startCursor
                )

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let results = json["results"] as? [[String: Any]] else {
                    return .object(["error": .string("Failed to parse query response")])
                }

                var items: [Value] = []
                for result in results {
                    let id = result["id"] as? String ?? ""
                    let url = result["url"] as? String ?? ""
                    var title = "Untitled"
                    if let properties = result["properties"] as? [String: Any] {
                        title = NotionJSON.extractTitle(from: properties)
                    }
                    items.append(.object([
                        "id": .string(id),
                        "title": .string(title),
                        "url": .string(url)
                    ]))
                }

                var resultObj: [String: Value] = [
                    "count": .int(items.count),
                    "results": .array(items)
                ]
                if let hasMore = json["has_more"] as? Bool {
                    resultObj["has_more"] = .bool(hasMore)
                }
                if let nextCursor = json["next_cursor"] as? String {
                    resultObj["next_cursor"] = .string(nextCursor)
                }
                return .object(resultObj)
            }
        ))

        // MARK: 6. notion_blocks_append – notify (A5)
        await router.register(ToolRegistration(
            name: "notion_blocks_append",
            module: moduleName,
            tier: .notify,
            description: "Append child blocks to a page or block. Supports position control (after specific block).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "blockId": .object(["type": .string("string"), "description": .string("Parent page or block ID")]),
                    "children": .object(["type": .string("string"), "description": .string("JSON string of children blocks array")]),
                    "afterBlock": .object(["type": .string("string"), "description": .string("Optional block ID to insert after")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("blockId"), .string("children")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let blockId) = args["blockId"],
                      case .string(let childrenJSON) = args["children"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_blocks_append", reason: "missing 'blockId' or 'children'")
                }

                guard let childrenData = childrenJSON.data(using: .utf8) else {
                    return .object(["error": .string("Invalid JSON in 'children'")])
                }

                var position: [String: String]? = nil
                if case .string(let afterId) = args["afterBlock"] {
                    position = ["type": "after_block", "block_id": afterId]
                }

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.appendBlocks(blockId: blockId, children: childrenData, position: position)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let results = json["results"] as? [[String: Any]] else {
                    return .object(["error": .string("Failed to parse append response")])
                }

                return .object([
                    "success": .bool(true),
                    "blocksAppended": .int(results.count)
                ])
            }
        ))

        // MARK: 7. notion_block_delete – notify (A6)
        await router.register(ToolRegistration(
            name: "notion_block_delete",
            module: moduleName,
            tier: .notify,
            description: "Delete (trash) a Notion block by ID.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "blockId": .object(["type": .string("string"), "description": .string("Block ID to delete")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("blockId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let blockId) = args["blockId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_block_delete", reason: "missing 'blockId'")
                }

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.deleteBlock(blockId: blockId)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse delete response")])
                }

                return .object([
                    "success": .bool(true),
                    "id": .string(json["id"] as? String ?? blockId),
                    "in_trash": .bool(json["in_trash"] as? Bool ?? true)
                ])
            }
        ))

        // MARK: 8. notion_page_markdown_read – open (A7)
        await router.register(ToolRegistration(
            name: "notion_page_markdown_read",
            module: moduleName,
            tier: .open,
            description: "Get page content as markdown. Returns the page body in markdown format.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pageId": .object(["type": .string("string"), "description": .string("Notion page ID")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("pageId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let pageId) = args["pageId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_page_markdown_read", reason: "missing 'pageId'")
                }

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.getPageMarkdown(pageId: pageId)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    let text = String(data: data, encoding: .utf8) ?? ""
                    return .object(["markdown": .string(text)])
                }

                let markdown = json["markdown"] as? String ?? String(data: data, encoding: .utf8) ?? ""
                return .object(["markdown": .string(markdown)])
            }
        ))

        // MARK: 9. notion_page_markdown_write – notify (A8)
        await router.register(ToolRegistration(
            name: "notion_page_markdown_write",
            module: moduleName,
            tier: .notify,
            description: "Update page content from markdown. Replaces the page body with the provided markdown.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pageId": .object(["type": .string("string"), "description": .string("Notion page ID")]),
                    "markdown": .object(["type": .string("string"), "description": .string("Markdown content to write")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("pageId"), .string("markdown")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let pageId) = args["pageId"],
                      case .string(let markdown) = args["markdown"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_page_markdown_write", reason: "missing 'pageId' or 'markdown'")
                }

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let _ = try await client.updatePageMarkdown(pageId: pageId, markdown: markdown)

                return .object(["success": .bool(true), "pageId": .string(pageId)])
            }
        ))

        // MARK: 10. notion_comments_list – open (A9a)
        await router.register(ToolRegistration(
            name: "notion_comments_list",
            module: moduleName,
            tier: .open,
            description: "List comments on a Notion page or block.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "blockId": .object(["type": .string("string"), "description": .string("Page or block ID to list comments for")]),
                    "pageSize": .object(["type": .string("integer"), "description": .string("Max results (default: 100)")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("blockId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let blockId) = args["blockId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_comments_list", reason: "missing 'blockId'")
                }
                let pageSize: Int = { if case .int(let ps) = args["pageSize"] { return min(ps, 100) }; return 100 }()

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.listComments(blockId: blockId, pageSize: pageSize)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let results = json["results"] as? [[String: Any]] else {
                    return .object(["error": .string("Failed to parse comments response")])
                }

                var comments: [Value] = []
                for comment in results {
                    let id = comment["id"] as? String ?? ""
                    let createdTime = comment["created_time"] as? String ?? ""
                    var text = ""
                    if let richText = comment["rich_text"] as? [[String: Any]] {
                        text = NotionJSON.extractPlainText(from: richText)
                    }
                    var createdBy = ""
                    if let user = comment["created_by"] as? [String: Any] {
                        createdBy = user["id"] as? String ?? ""
                    }
                    comments.append(.object([
                        "id": .string(id),
                        "text": .string(text),
                        "created_time": .string(createdTime),
                        "created_by": .string(createdBy)
                    ]))
                }

                return .object([
                    "count": .int(comments.count),
                    "comments": .array(comments)
                ])
            }
        ))

        // MARK: 11. notion_comment_create – notify (A9b)
        await router.register(ToolRegistration(
            name: "notion_comment_create",
            module: moduleName,
            tier: .notify,
            description: "Create a comment on a Notion page.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pageId": .object(["type": .string("string"), "description": .string("Page ID to comment on")]),
                    "text": .object(["type": .string("string"), "description": .string("Comment text content")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("pageId"), .string("text")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let pageId) = args["pageId"],
                      case .string(let text) = args["text"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_comment_create", reason: "missing 'pageId' or 'text'")
                }

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.createComment(pageId: pageId, text: text)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse comment response")])
                }

                return .object([
                    "success": .bool(true),
                    "id": .string(json["id"] as? String ?? "")
                ])
            }
        ))

        // MARK: 12. notion_users_list – open (A10)
        await router.register(ToolRegistration(
            name: "notion_users_list",
            module: moduleName,
            tier: .open,
            description: "List all users in the Notion workspace.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pageSize": .object(["type": .string("integer"), "description": .string("Max results (default: 100)")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let args: [String: Value] = {
                    if case .object(let a) = arguments { return a }
                    return [:]
                }()
                let pageSize: Int = { if case .int(let ps) = args["pageSize"] { return min(ps, 100) }; return 100 }()

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.listUsers(pageSize: pageSize)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let results = json["results"] as? [[String: Any]] else {
                    return .object(["error": .string("Failed to parse users response")])
                }

                var users: [Value] = []
                for user in results {
                    let id = user["id"] as? String ?? ""
                    let name = user["name"] as? String ?? ""
                    let type = user["type"] as? String ?? ""
                    var email = ""
                    if let person = user["person"] as? [String: Any] {
                        email = person["email"] as? String ?? ""
                    }
                    users.append(.object([
                        "id": .string(id),
                        "name": .string(name),
                        "type": .string(type),
                        "email": .string(email)
                    ]))
                }

                return .object([
                    "count": .int(users.count),
                    "users": .array(users)
                ])
            }
        ))

        // MARK: 13. notion_page_move – notify (A11)
        await router.register(ToolRegistration(
            name: "notion_page_move",
            module: moduleName,
            tier: .notify,
            description: "Move a Notion page to a new parent page or database.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pageId": .object(["type": .string("string"), "description": .string("Page ID to move")]),
                    "newParentId": .object(["type": .string("string"), "description": .string("New parent page or database ID")]),
                    "parentType": .object(["type": .string("string"), "description": .string("Parent type: 'page_id' or 'database_id' (default: page_id)")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("pageId"), .string("newParentId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let pageId) = args["pageId"],
                      case .string(let newParentId) = args["newParentId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_page_move", reason: "missing 'pageId' or 'newParentId'")
                }

                let parentType: String = {
                    if case .string(let pt) = args["parentType"] { return pt }
                    return "page_id"
                }()

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.movePage(pageId: pageId, newParentId: newParentId, parentType: parentType)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse move response")])
                }

                return .object([
                    "success": .bool(true),
                    "id": .string(json["id"] as? String ?? pageId),
                    "url": .string(json["url"] as? String ?? "")
                ])
            }
        ))

        // MARK: 14. notion_file_upload – notify (A12)
        await router.register(ToolRegistration(
            name: "notion_file_upload",
            module: moduleName,
            tier: .notify,
            description: "Upload a local file to Notion (single-part, max 20MB). Returns the file upload object.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "filePath": .object(["type": .string("string"), "description": .string("Absolute path to the local file")]),
                    "workspace": workspaceParam
                ]),
                "required": .array([.string("filePath")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let filePath) = args["filePath"] else {
                    throw ToolRouterError.invalidArguments(toolName: "notion_file_upload", reason: "missing 'filePath'")
                }

                guard let fileData = FileManager.default.contents(atPath: filePath) else {
                    return .object(["error": .string("File not found or unreadable: \(filePath)")])
                }

                guard fileData.count <= 20 * 1024 * 1024 else {
                    return .object(["error": .string("File exceeds 20MB limit (\(fileData.count) bytes)")])
                }

                let fileName = (filePath as NSString).lastPathComponent
                let ext = (fileName as NSString).pathExtension.lowercased()
                let contentType: String = {
                    switch ext {
                    case "pdf": return "application/pdf"
                    case "png": return "image/png"
                    case "jpg", "jpeg": return "image/jpeg"
                    case "gif": return "image/gif"
                    case "txt": return "text/plain"
                    case "json": return "application/json"
                    case "csv": return "text/csv"
                    default: return "application/octet-stream"
                    }
                }()

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.uploadFile(fileName: fileName, fileData: fileData, contentType: contentType)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse upload response")])
                }

                return .object([
                    "success": .bool(true),
                    "id": .string(json["id"] as? String ?? ""),
                    "status": .string(json["status"] as? String ?? "unknown")
                ])
            }
        ))

        // MARK: 15. notion_token_introspect – open (A13)
        await router.register(ToolRegistration(
            name: "notion_token_introspect",
            module: moduleName,
            tier: .open,
            description: "Introspect the current Notion API token. Returns token info including bot details and workspace.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "workspace": workspaceParam
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let args: [String: Value] = {
                    if case .object(let a) = arguments { return a }
                    return [:]
                }()

                let client = try await registryHolder.getClient(workspace: extractWorkspace(args))
                let data = try await client.introspectToken()

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .object(["error": .string("Failed to parse introspect response")])
                }

                var result: [String: Value] = [:]
                if let botId = json["bot_id"] as? String { result["bot_id"] = .string(botId) }
                if let type = json["type"] as? String { result["type"] = .string(type) }
                if let workspace = json["workspace_name"] as? String { result["workspace_name"] = .string(workspace) }
                if let owner = json["owner"] as? [String: Any] {
                    result["owner"] = .string(NotionJSON.prettyPrint(owner))
                }
                result["raw"] = .string(NotionJSON.prettyPrint(json))

                return .object(result)
            }
        ))

        // MARK: 16. notion_connections_list – open (B4)
        await router.register(ToolRegistration(
            name: "notion_connections_list",
            module: moduleName,
            tier: .open,
            description: "List all configured Notion workspace connections with health status.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            handler: { _ in
                let connList = try await registryHolder.listConnections()

                var items: [Value] = []
                for conn in connList {
                    items.append(.object([
                        "name": .string(conn.name),
                        "primary": .bool(conn.isPrimary),
                        "status": .string(conn.status),
                        "token": .string(conn.maskedToken)
                    ]))
                }

                return .object([
                    "count": .int(items.count),
                    "connections": .array(items)
                ])
            }
        ))
    }
}

// MARK: - Lazy Registry Holder


/// Thread-safe holder for lazy NotionClientRegistry initialization.
/// Methods are async to cross actor-isolation boundary of NotionClientRegistry
/// (Swift 6.2 infers actor isolation on @unchecked Sendable classes).
private final class NotionRegistryHolder: @unchecked Sendable {
    private var registry: NotionClientRegistry?
    private let lock = NSLock()

    private func ensureRegistry() throws -> NotionClientRegistry {
        lock.lock()
        defer { lock.unlock() }

        if let existing = registry {
            return existing
        }

        let newRegistry = try NotionClientRegistry()
        registry = newRegistry
        return newRegistry
    }

    func getClient(workspace: String?) async throws -> NotionClient {
        let reg = try ensureRegistry()
        return try await reg.getClient(workspace: workspace)
    }

    func listConnections() async throws -> [NotionConnectionInfo] {
        let reg = try ensureRegistry()
        return try await reg.listConnections()
    }
}
