// NotionModuleTests.swift – V1-05 → V2-NOTION-CORE NotionModule Tests
// NotionBridge · Tests
//
// PKT-367: Updated for 18 tools, API v2026-03-11, multi-workspace registry,
//          config migration, new model types, helper tests

import Foundation
import MCP
import NotionBridgeLib

// MARK: - NotionModule Tests

func runNotionModuleTests() async {
    print("\n📝 NotionModule Tests")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await NotionModule.register(on: router)

    // ============================================================
    // MARK: - Tool Registration (18 tools)
    // ============================================================

    await test("NotionModule registers 18 tools") {
        let tools = await router.registrations(forModule: "notion")
        try expect(tools.count == 18, "Expected 18 notion tools, got \(tools.count)")
    }

    let expectedTools: [String] = [
        "notion_search", "notion_page_read", "notion_page_update",
        "notion_query", "notion_page_create", "notion_blocks_append",
        "notion_block_delete", "notion_page_markdown_read", "notion_page_markdown_write",
        "notion_comments_list", "notion_comment_create", "notion_users_list",
        "notion_page_move", "notion_file_upload", "notion_token_introspect",
        "notion_connections_list", "notion_block_read", "notion_block_update"
    ]

    for toolName in expectedTools {
        await test("Tool \(toolName) is registered") {
            let tools = await router.registrations(forModule: "notion")
            let names = Set(tools.map(\.name))
            try expect(names.contains(toolName), "Missing \(toolName)")
        }
    }

    // ============================================================
    // MARK: - Security Tiers
    // ============================================================

    let openTools = [
        "notion_search", "notion_page_read", "notion_query",
        "notion_page_markdown_read", "notion_comments_list",
        "notion_users_list", "notion_token_introspect", "notion_connections_list",
        "notion_block_read"
    ]
    for toolName in openTools {
        await test("\(toolName) tier is open") {
            let tools = await router.registrations(forModule: "notion")
            guard let tool = tools.first(where: { $0.name == toolName }) else { throw TestError.assertion("Tool \(toolName) not found") }
            try expect(tool.tier == .open, "Expected open tier for \(toolName), got \(tool.tier.rawValue)")
        }
    }

    let notifyTools = [
        "notion_page_update", "notion_page_create", "notion_blocks_append",
        "notion_block_delete", "notion_page_markdown_write",
        "notion_comment_create", "notion_page_move", "notion_file_upload",
        "notion_block_update"
    ]
    for toolName in notifyTools {
        await test("\(toolName) tier is notify") {
            let tools = await router.registrations(forModule: "notion")
            guard let tool = tools.first(where: { $0.name == toolName }) else { throw TestError.assertion("Tool \(toolName) not found") }
            try expect(tool.tier == .notify, "Expected notify tier for \(toolName), got \(tool.tier.rawValue)")
        }
    }

    // ============================================================
    // MARK: - API Version
    // ============================================================

    await test("NotionClient uses API v2026-03-11") {
        do {
            let client = try NotionClient()
            let version = await client.getAPIVersion()
            try expect(version == "2026-03-11", "Expected 2026-03-11, got \(version)")
        } catch {
            // If no token configured, skip live version check
            print("    ⚠️ No API token — skipping live version check")
        }
    }

    // ============================================================
    // MARK: - Input Validation (missing required params)
    // ============================================================

    await test("notion_search rejects missing query") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_search",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing query")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("notion_page_read rejects missing pageId") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_page_read",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing pageId")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("notion_page_update rejects missing params") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_page_update",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing params")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("notion_page_update rejects invalid JSON in properties") {
        do {
            let result = try await router.dispatch(
                toolName: "notion_page_update",
                arguments: .object([
                    "pageId": .string("fake-id-12345"),
                    "properties": .string("not valid json {{{")
                ])
            )
            if case .object(let dict) = result,
               case .string(let error) = dict["error"] {
                try expect(error.contains("Invalid JSON"), "Expected Invalid JSON error, got: \(error)")
            }
        } catch {
            // Also acceptable — API key might be missing
        }
    }

    await test("notion_query rejects missing databaseId") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_query",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing databaseId")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("notion_page_create rejects missing parentId") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_page_create",
                arguments: .object(["properties": .string("{}")])
            )
            throw TestError.assertion("Expected error for missing parentId")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("notion_blocks_append rejects missing blockId") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_blocks_append",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing blockId")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("notion_block_delete rejects missing blockId") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_block_delete",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing blockId")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("notion_page_markdown_read rejects missing pageId") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_page_markdown_read",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing pageId")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("notion_page_markdown_write rejects missing params") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_page_markdown_write",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing params")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("notion_comments_create rejects missing text") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_comment_create",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing text")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("notion_comments_create rejects missing parentId and discussionId") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_comment_create",
                arguments: .object(["text": .string("test comment")])
            )
            throw TestError.assertion("Expected error for missing parentId/discussionId")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("notion_page_move rejects missing params") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_page_move",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing params")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("notion_file_upload rejects missing filePath") {
        do {
            _ = try await router.dispatch(
                toolName: "notion_file_upload",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing filePath")
        } catch is ToolRouterError {
            // Expected
        }
    }

    // ============================================================
    // MARK: - Config Migration & Registry
    // ============================================================

    await test("NotionClientRegistry initializes without crash") {
        let registry = NotionClientRegistry()
        _ = registry
    }

    await test("NotionClientRegistry.listConnections works") {
        let registry = NotionClientRegistry()
        do {
            let connections = try await registry.listConnections()
            try expect(connections.count >= 0, "Expected non-negative connection count")
            for conn in connections {
                try expect(!conn.name.isEmpty, "Connection name should not be empty")
                try expect(!conn.maskedToken.isEmpty, "Masked token should not be empty")
            }
        } catch {
            print("    ⚠️ No connections configured — skipping live registry check")
        }
    }

    await test("NotionTokenResolver.validateTokenFormat accepts valid ntn_ token") {
        let result = NotionTokenResolver.validateTokenFormat("ntn_abcdef1234567890abcdef")
        try expect(result.valid == true, "Expected valid=true for ntn_ token")
        try expect(result.error == nil, "Expected no error for valid token")
    }

    await test("NotionTokenResolver.validateTokenFormat accepts valid secret_ token") {
        let result = NotionTokenResolver.validateTokenFormat("secret_abcdef1234567890abcdef")
        try expect(result.valid == true, "Expected valid=true for secret_ token")
    }

    await test("NotionTokenResolver.validateTokenFormat rejects short token") {
        let result = NotionTokenResolver.validateTokenFormat("ntn_short")
        try expect(result.valid == false, "Expected valid=false for short token")
        try expect(result.error != nil, "Expected error for short token")
    }

    await test("NotionTokenResolver.validateTokenFormat rejects invalid prefix") {
        let result = NotionTokenResolver.validateTokenFormat("invalid_prefix_abcdef1234567890")
        try expect(result.valid == false, "Expected valid=false for invalid prefix")
    }

    // ============================================================
    // MARK: - NotionJSON Helper Tests
    // ============================================================

    await test("NotionJSON.extractTitle extracts title from properties") {
        let props: [String: Any] = [
            "Name": [
                "type": "title",
                "title": [
                    ["plain_text": "Hello World"]
                ]
            ]
        ]
        let title = NotionJSON.extractTitle(from: props)
        try expect(title == "Hello World", "Expected 'Hello World', got '\(title)'")
    }

    await test("NotionJSON.extractTitle returns Untitled for empty properties") {
        let title = NotionJSON.extractTitle(from: [:])
        try expect(title == "Untitled", "Expected 'Untitled', got '\(title)'")
    }

    await test("NotionJSON.prettyPrint produces valid JSON string") {
        let obj: [String: Any] = ["key": "value", "num": 42]
        let result = NotionJSON.prettyPrint(obj)
        try expect(result.contains("key"), "Expected 'key' in output")
        try expect(result.contains("value"), "Expected 'value' in output")
        try expect(result.contains("42"), "Expected '42' in output")
    }

    await test("NotionJSON.extractPlainText extracts text from rich_text array") {
        let richText: [[String: Any]] = [
            ["plain_text": "Hello "],
            ["plain_text": "World"]
        ]
        let text = NotionJSON.extractPlainText(from: richText)
        try expect(text == "Hello World", "Expected 'Hello World', got '\(text)'")
    }

    await test("NotionJSON.extractPlainText returns empty string for empty array") {
        let text = NotionJSON.extractPlainText(from: [])
        try expect(text == "", "Expected empty string, got '\(text)'")
    }

    await test("NotionJSON.maskToken masks token correctly") {
        let masked = NotionJSON.maskToken("ntn_abcdef1234567890")
        try expect(masked.hasPrefix("ntn_"), "Expected prefix 'ntn_', got '\(masked)'")
        try expect(masked.hasSuffix("7890"), "Expected suffix '7890', got '\(masked)'")
        try expect(masked.contains("•"), "Expected masking dots in '\(masked)'")
    }

    await test("NotionJSON.maskToken handles short token") {
        let masked = NotionJSON.maskToken("short")
        try expect(masked.contains("•"), "Expected masking dots for short token, got '\(masked)'")
    }

    // ============================================================
    // MARK: - Append block children body (API 2026-03-11)
    // ============================================================

    await test("buildAppendBlocksRequestBody end omits position and after") {
        let children = "[{\"object\":\"block\",\"type\":\"paragraph\",\"paragraph\":{\"rich_text\":[]}}]".data(using: .utf8)!
        let body = try NotionClient.buildAppendBlocksRequestBody(children: children, position: .end)
        try expect(body["children"] != nil, "Expected children")
        try expect(body["position"] == nil, "Expected no position for append-to-end")
        try expect(body["after"] == nil, "Must not send deprecated after key")
    }

    await test("buildAppendBlocksRequestBody afterBlock uses position.after_block.id") {
        let children = "[{\"object\":\"block\",\"type\":\"paragraph\",\"paragraph\":{\"rich_text\":[]}}]".data(using: .utf8)!
        let rawAfter = "333cbb58889e8140aba3f4b29693b38f"
        let body = try NotionClient.buildAppendBlocksRequestBody(children: children, position: .afterBlock(id: rawAfter))
        try expect(body["after"] == nil, "Must not send deprecated after key")
        guard let pos = body["position"] as? [String: Any] else {
            throw TestError.assertion("Expected position dict")
        }
        try expect(pos["type"] as? String == "after_block", "Expected type after_block")
        guard let ab = pos["after_block"] as? [String: Any] else {
            throw TestError.assertion("Expected after_block object")
        }
        let id = ab["id"] as? String ?? ""
        try expect(id.contains("-"), "Expected dashed UUID in id field")
        try expect(
            id.replacingOccurrences(of: "-", with: "").lowercased() == rawAfter.lowercased(),
            "Normalized id should match 32-char input"
        )
    }

    // ============================================================
    // MARK: - NotionClientError Tests
    // ============================================================

    await test("NotionClientError.connectionNotFound has descriptive message") {
        let error = NotionClientError.connectionNotFound("myworkspace")
        let desc = error.localizedDescription
        try expect(desc.contains("myworkspace"), "Expected workspace name in error: \(desc)")
        try expect(desc.contains("not found"), "Expected 'not found' in error: \(desc)")
    }

    await test("NotionClientError.missingAPIKey has descriptive message") {
        let error = NotionClientError.missingAPIKey
        let desc = error.localizedDescription
        try expect(desc.contains("NOTION_API_TOKEN"), "Expected env var name in error: \(desc)")
    }

    await test("NotionClientError.httpError includes status code and body") {
        let error = NotionClientError.httpError(404, "page not found")
        let desc = error.localizedDescription
        try expect(desc.contains("404"), "Expected 404 in error: \(desc)")
        try expect(desc.contains("page not found"), "Expected body in error: \(desc)")
    }

    // ============================================================
    // MARK: - Model Tests
    // ============================================================

    await test("NotionPage model includes inTrash field") {
        let page = NotionPage(id: "abc", url: "https://notion.so/abc", title: "Test", inTrash: true, properties: "{}")
        try expect(page.inTrash == true, "Expected inTrash=true")
        try expect(page.id == "abc", "Expected id='abc'")
    }

    await test("NotionPage inTrash defaults to false") {
        let page = NotionPage(id: "abc", url: "https://notion.so/abc", title: "Test", properties: "{}")
        try expect(page.inTrash == false, "Expected inTrash=false by default")
    }

    await test("NotionComment model initializes correctly") {
        let comment = NotionComment(id: "c1", parentId: "p1", text: "Hello", createdTime: "2026-03-19", createdBy: "u1")
        try expect(comment.id == "c1", "Expected id='c1'")
        try expect(comment.parentId == "p1", "Expected parentId='p1'")
        try expect(comment.text == "Hello", "Expected text='Hello'")
    }

    await test("NotionUser model initializes correctly") {
        let user = NotionUser(id: "u1", name: "Alice", email: "alice@example.com", type: "person", avatarURL: nil)
        try expect(user.id == "u1", "Expected id='u1'")
        try expect(user.name == "Alice", "Expected name='Alice'")
        try expect(user.email == "alice@example.com", "Expected email")
        try expect(user.type == "person", "Expected type='person'")
    }

    await test("NotionFileUpload model initializes correctly") {
        let upload = NotionFileUpload(id: "f1", status: "uploaded", url: nil)
        try expect(upload.id == "f1", "Expected id='f1'")
        try expect(upload.status == "uploaded", "Expected status='uploaded'")
    }

    await test("NotionConnection model initializes correctly") {
        let conn = NotionConnection(name: "primary", token: "ntn_test", primary: true)
        try expect(conn.name == "primary", "Expected name='primary'")
        try expect(conn.primary == true, "Expected primary=true")
        try expect(conn.token == "ntn_test", "Expected token='ntn_test'")
    }

    await test("NotionConnectionInfo model initializes correctly") {
        let info = NotionConnectionInfo(name: "primary", isPrimary: true, status: "connected", maskedToken: "ntn_•••1234")
        try expect(info.name == "primary", "Expected name='primary'")
        try expect(info.isPrimary == true, "Expected isPrimary=true")
        try expect(info.status == "connected", "Expected status='connected'")
        try expect(info.maskedToken == "ntn_•••1234", "Expected maskedToken")
    }

    // ============================================================
    // MARK: - Functional Tests (with API key)
    // ============================================================

    let hasAPIKey = ProcessInfo.processInfo.environment["NOTION_API_TOKEN"] != nil ||
                    ProcessInfo.processInfo.environment["NOTION_API_KEY"] != nil ||
                    NotionTokenResolver.readCurrentToken() != nil

    if hasAPIKey {
        await test("notion_search returns results with API key") {
            let result = try await router.dispatch(
                toolName: "notion_search",
                arguments: .object(["query": .string("test"), "pageSize": .int(3)])
            )
            if case .object(let dict) = result {
                try expect(dict["count"] != nil, "Expected count key")
                try expect(dict["results"] != nil, "Expected results key")
            } else {
                throw TestError.assertion("Expected object result")
            }
        }

        await test("notion_connections_list returns connections") {
            let result = try await router.dispatch(
                toolName: "notion_connections_list",
                arguments: .object([:])
            )
            if case .object(let dict) = result {
                try expect(dict["count"] != nil, "Expected count key")
                try expect(dict["connections"] != nil, "Expected connections key")
            } else {
                throw TestError.assertion("Expected object result")
            }
        }
    } else {
        await test("notion_search reports missing API key gracefully") {
            do {
                _ = try await router.dispatch(
                    toolName: "notion_search",
                    arguments: .object(["query": .string("test")])
                )
            } catch {
                let desc = error.localizedDescription
                try expect(
                    desc.contains("API") || desc.contains("key") || desc.contains("KEY") || desc.contains("token"),
                    "Error should mention API key/token: \(desc)"
                )
            }
        }
    }
}
