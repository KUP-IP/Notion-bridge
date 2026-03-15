// MessagesModuleTests.swift – V1-05 MessagesModule Tests
// NotionGate · Tests

import Foundation
import MCP
import NotionGateLib

// MARK: - MessagesModule Tests

func runMessagesModuleTests() async {
    print("\n💬 MessagesModule Tests")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log, batchThreshold: 10)
    await MessagesModule.register(on: router)

    // Registration tests
    await test("MessagesModule registers 6 tools") {
        let tools = await router.registrations(forModule: "messages")
        try expect(tools.count == 6, "Expected 6 messages tools, got \(tools.count)")
        let names = Set(tools.map(\.name))
        try expect(names.contains("messages_search"), "Missing messages_search")
        try expect(names.contains("messages_recent"), "Missing messages_recent")
        try expect(names.contains("messages_chat"), "Missing messages_chat")
        try expect(names.contains("messages_content"), "Missing messages_content")
        try expect(names.contains("messages_participants"), "Missing messages_participants")
        try expect(names.contains("messages_send"), "Missing messages_send")
    }

    // Tier tests
    await test("messages_search tier is green") {
        let tools = await router.registrations(forModule: "messages")
        let tool = tools.first(where: { $0.name == "messages_search" })!
        try expect(tool.tier == .open, "Expected green, got \(tool.tier.rawValue)")
    }

    await test("messages_recent tier is green") {
        let tools = await router.registrations(forModule: "messages")
        let tool = tools.first(where: { $0.name == "messages_recent" })!
        try expect(tool.tier == .open, "Expected green, got \(tool.tier.rawValue)")
    }

    await test("messages_chat tier is green") {
        let tools = await router.registrations(forModule: "messages")
        let tool = tools.first(where: { $0.name == "messages_chat" })!
        try expect(tool.tier == .open, "Expected green, got \(tool.tier.rawValue)")
    }

    await test("messages_content tier is green") {
        let tools = await router.registrations(forModule: "messages")
        let tool = tools.first(where: { $0.name == "messages_content" })!
        try expect(tool.tier == .open, "Expected green, got \(tool.tier.rawValue)")
    }

    await test("messages_participants tier is green") {
        let tools = await router.registrations(forModule: "messages")
        let tool = tools.first(where: { $0.name == "messages_participants" })!
        try expect(tool.tier == .open, "Expected green, got \(tool.tier.rawValue)")
    }

    await test("messages_send tier is red") {
        let tools = await router.registrations(forModule: "messages")
        let tool = tools.first(where: { $0.name == "messages_send" })!
        try expect(tool.tier == .notify, "Expected red, got \(tool.tier.rawValue)")
    }

    // Functional tests — messages_search (requires chat.db access)
    await test("messages_search returns result structure") {
        let result = try await router.dispatch(
            toolName: "messages_search",
            arguments: .object(["query": .string("test_nonexistent_xyz_notiongate"), "limit": .int(5)])
        )
        if case .object(let dict) = result {
            // Should have rows and count keys (even if empty)
            try expect(dict["rows"] != nil || dict["error"] != nil,
                       "Expected 'rows' or 'error' key in result")
        } else {
            throw TestError.assertion("Expected object result")
        }
    }

    // messages_recent returns result structure
    await test("messages_recent returns result structure") {
        let result = try await router.dispatch(
            toolName: "messages_recent",
            arguments: .object(["limit": .int(3)])
        )
        if case .object(let dict) = result {
            try expect(dict["rows"] != nil || dict["error"] != nil,
                       "Expected 'rows' or 'error' key in result")
        } else {
            throw TestError.assertion("Expected object result")
        }
    }

    // messages_send rejects without confirm
    await test("messages_send rejects without confirm='SEND'") {
        let result = try await router.dispatch(
            toolName: "messages_send",
            arguments: .object([
                "recipient": .string("+15551234567"),
                "body": .string("test"),
                "confirm": .string("NO")
            ])
        )
        if case .object(let dict) = result,
           case .bool(let sent) = dict["sent"] {
            try expect(sent == false, "Expected sent=false without SEND confirm")
        } else {
            throw TestError.assertion("Expected object with sent=false")
        }
    }

    // messages_search rejects missing query
    await test("messages_search rejects missing query") {
        do {
            _ = try await router.dispatch(
                toolName: "messages_search",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing query")
        } catch is ToolRouterError {
            // Expected
        }
    }

    // messages_chat rejects missing contact
    await test("messages_chat rejects missing contact") {
        do {
            _ = try await router.dispatch(
                toolName: "messages_chat",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing contact")
        } catch is ToolRouterError {
            // Expected
        }
    }

    // messages_content rejects missing messageId
    await test("messages_content rejects missing messageId") {
        do {
            _ = try await router.dispatch(
                toolName: "messages_content",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing messageId")
        } catch is ToolRouterError {
            // Expected
        }
    }

    // messages_participants rejects missing chatIdentifier
    await test("messages_participants rejects missing chatIdentifier") {
        do {
            _ = try await router.dispatch(
                toolName: "messages_participants",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing chatIdentifier")
        } catch is ToolRouterError {
            // Expected
        }
    }

    // messages_send rejects missing params
    await test("messages_send rejects missing params") {
        do {
            _ = try await router.dispatch(
                toolName: "messages_send",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing params")
        } catch is ToolRouterError {
            // Expected
        }
    }
}
