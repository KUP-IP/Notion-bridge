// ChromeModuleTests.swift – QA: ChromeModule Test Coverage
// NotionBridge · Tests
//
// Validates tool registration, count, names, and security tiers for ChromeModule.
// Follows the same pattern as GoogleDriveModuleTests.

import Foundation
import MCP
import NotionBridgeLib

// MARK: - ChromeModule Tests

func runChromeModuleTests() async {
    print("\n🌐 ChromeModule Tests")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log, batchThreshold: 10)
    await ChromeModule.register(on: router)

    // ============================================================
    // MARK: - Tool Registration (5 tools)
    // ============================================================

    await test("ChromeModule registers 5 tools") {
        let tools = await router.registrations(forModule: "chrome")
        try expect(tools.count == 5, "Expected 5 chrome tools, got \(tools.count)")
    }

    let expectedTools: [String] = [
        "chrome_tabs",
        "chrome_navigate",
        "chrome_read_page",
        "chrome_execute_js",
        "chrome_screenshot_tab"
    ]

    for toolName in expectedTools {
        await test("Tool \(toolName) is registered") {
            let tools = await router.registrations(forModule: "chrome")
            let names = Set(tools.map(\.name))
            try expect(names.contains(toolName), "Missing \(toolName)")
        }
    }

    // ============================================================
    // MARK: - Security Tiers
    // ============================================================

    let openTools = ["chrome_tabs", "chrome_read_page", "chrome_screenshot_tab"]
    let notifyTools = ["chrome_navigate", "chrome_execute_js"]

    for toolName in openTools {
        await test("\(toolName) has open tier") {
            let tools = await router.registrations(forModule: "chrome")
            let tool = tools.first(where: { $0.name == toolName })
            try expect(tool != nil, "Tool \(toolName) not found")
            try expect(tool!.tier == .open, "\(toolName) should be .open, got \(tool!.tier)")
        }
    }

    for toolName in notifyTools {
        await test("\(toolName) has notify tier") {
            let tools = await router.registrations(forModule: "chrome")
            let tool = tools.first(where: { $0.name == toolName })
            try expect(tool != nil, "Tool \(toolName) not found")
            try expect(tool!.tier == .notify, "\(toolName) should be .notify, got \(tool!.tier)")
        }
    }

    // ============================================================
    // MARK: - Tool Descriptions & Schemas
    // ============================================================

    await test("All chrome tools have non-empty descriptions") {
        let tools = await router.registrations(forModule: "chrome")
        for tool in tools {
            try expect(!tool.description.isEmpty, "\(tool.name) has empty description")
        }
    }

    await test("All chrome tools have input schemas") {
        let tools = await router.registrations(forModule: "chrome")
        for tool in tools {
            if case .object = tool.inputSchema {
                // valid
            } else {
                throw TestError.assertion("\(tool.name) inputSchema is not an object")
            }
        }
    }

    // ============================================================
    // MARK: - Required Parameters
    // ============================================================

    await test("chrome_navigate requires 'url' parameter") {
        let tools = await router.registrations(forModule: "chrome")
        let tool = tools.first(where: { $0.name == "chrome_navigate" })
        try expect(tool != nil, "chrome_navigate not found")
        if case .object(let schema) = tool!.inputSchema,
           case .array(let required) = schema["required"] {
            let requiredNames = required.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            try expect(requiredNames.contains("url"), "chrome_navigate should require 'url'")
        }
    }

    await test("chrome_execute_js requires 'javascript' parameter") {
        let tools = await router.registrations(forModule: "chrome")
        let tool = tools.first(where: { $0.name == "chrome_execute_js" })
        try expect(tool != nil, "chrome_execute_js not found")
        if case .object(let schema) = tool!.inputSchema,
           case .array(let required) = schema["required"] {
            let requiredNames = required.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            try expect(requiredNames.contains("javascript"), "chrome_execute_js should require 'javascript'")
        }
    }
}
