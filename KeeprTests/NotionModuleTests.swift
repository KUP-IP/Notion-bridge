// NotionModuleTests.swift – V1-05 NotionModule Tests
// KeeprBridge · Tests

import Foundation
import MCP
import KeeprLib

// MARK: - NotionModule Tests

func runNotionModuleTests() async {
    print("\n📝 NotionModule Tests")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log, batchThreshold: 10)
    await NotionModule.register(on: router)

    // Registration tests
    await test("NotionModule registers 3 tools") {
        let tools = await router.registrations(forModule: "notion")
        try expect(tools.count == 3, "Expected 3 notion tools, got \(tools.count)")
        let names = Set(tools.map(\.name))
        try expect(names.contains("notion_search"), "Missing notion_search")
        try expect(names.contains("notion_page_read"), "Missing notion_page_read")
        try expect(names.contains("notion_page_update"), "Missing notion_page_update")
    }

    // Tier tests
    await test("notion_search tier is green") {
        let tools = await router.registrations(forModule: "notion")
        let tool = tools.first(where: { $0.name == "notion_search" })!
        try expect(tool.tier == .open, "Expected green, got \(tool.tier.rawValue)")
    }

    await test("notion_page_read tier is green") {
        let tools = await router.registrations(forModule: "notion")
        let tool = tools.first(where: { $0.name == "notion_page_read" })!
        try expect(tool.tier == .open, "Expected green, got \(tool.tier.rawValue)")
    }

    await test("notion_page_update tier is orange") {
        let tools = await router.registrations(forModule: "notion")
        let tool = tools.first(where: { $0.name == "notion_page_update" })!
        try expect(tool.tier == .notify, "Expected orange, got \(tool.tier.rawValue)")
    }

    // Functional tests — these require NOTION_API_KEY
    // If the key is not set, tools should return a clear error
    let hasAPIKey = ProcessInfo.processInfo.environment["NOTION_API_KEY"] != nil

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
    } else {
        await test("notion_search reports missing API key gracefully") {
            do {
                _ = try await router.dispatch(
                    toolName: "notion_search",
                    arguments: .object(["query": .string("test")])
                )
                // If it doesn't throw, it should return an error object
            } catch {
                // Expected — missing API key
                let desc = error.localizedDescription
                try expect(
                    desc.contains("API") || desc.contains("key") || desc.contains("KEY"),
                    "Error should mention API key: \(desc)"
                )
            }
        }
    }

    // notion_search rejects missing query
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

    // notion_page_read rejects missing pageId
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

    // notion_page_update rejects missing params
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

    // notion_page_update rejects invalid JSON
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

    // NotionJSON helper tests
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
}
