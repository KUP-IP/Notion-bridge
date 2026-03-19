// GoogleDriveModuleTests.swift – V3-QUALITY C3: GoogleDriveModule Tests
// NotionBridge · Tests
//
// Validates tool registration, count, names, and security tiers for GoogleDriveModule.
// Follows the same pattern as NotionModuleTests.

import Foundation
import MCP
import NotionBridgeLib

// MARK: - GoogleDriveModule Tests

func runGoogleDriveModuleTests() async {
    print("\n📁 GoogleDriveModule Tests")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log, batchThreshold: 10)
    await GoogleDriveModule.register(on: router)

    // ============================================================
    // MARK: - Tool Registration (6 tools)
    // ============================================================

    await test("GoogleDriveModule registers 6 tools") {
        let tools = await router.registrations(forModule: "gdrive")
        try expect(tools.count == 6, "Expected 6 gdrive tools, got \(tools.count)")
    }

    let expectedTools: [String] = [
        "gdrive_list",
        "gdrive_search",
        "gdrive_read",
        "gdrive_download",
        "gdrive_upload",
        "gdrive_metadata"
    ]

    for toolName in expectedTools {
        await test("Tool \(toolName) is registered") {
            let tools = await router.registrations(forModule: "gdrive")
            let names = Set(tools.map(\.name))
            try expect(names.contains(toolName), "Missing \(toolName)")
        }
    }

    // ============================================================
    // MARK: - Security Tiers
    // ============================================================

    let openTools = ["gdrive_list", "gdrive_search", "gdrive_read", "gdrive_metadata"]
    let notifyTools = ["gdrive_download", "gdrive_upload"]

    for toolName in openTools {
        await test("\(toolName) has open tier") {
            let tools = await router.registrations(forModule: "gdrive")
            let tool = tools.first(where: { $0.name == toolName })
            try expect(tool != nil, "Tool \(toolName) not found")
            try expect(tool!.tier == .open, "\(toolName) should be .open, got \(tool!.tier)")
        }
    }

    for toolName in notifyTools {
        await test("\(toolName) has notify tier") {
            let tools = await router.registrations(forModule: "gdrive")
            let tool = tools.first(where: { $0.name == toolName })
            try expect(tool != nil, "Tool \(toolName) not found")
            try expect(tool!.tier == .notify, "\(toolName) should be .notify, got \(tool!.tier)")
        }
    }

    // ============================================================
    // MARK: - Tool Descriptions
    // ============================================================

    await test("All gdrive tools have non-empty descriptions") {
        let tools = await router.registrations(forModule: "gdrive")
        for tool in tools {
            try expect(!tool.description.isEmpty, "\(tool.name) has empty description")
        }
    }

    await test("All gdrive tools have input schemas") {
        let tools = await router.registrations(forModule: "gdrive")
        for tool in tools {
            if case .object = tool.inputSchema {
                // valid
            } else {
                throw TestError.assertion("\(tool.name) inputSchema is not an object")
            }
        }
    }

    // ============================================================
    // MARK: - Token Resolution
    // ============================================================

    await test("GoogleDriveTokenResolver.isConfigured returns bool") {
        // Just verify the property exists and is callable — token may or may not be set
        let _ = GoogleDriveTokenResolver.isConfigured
    }

    await test("GoogleDriveTokenResolver.resolve() returns optional tuple") {
        // Verify the method signature — result depends on environment
        let result = GoogleDriveTokenResolver.resolve()
        if let r = result {
            try expect(!r.token.isEmpty, "Token should not be empty if resolved")
            try expect(!r.source.isEmpty, "Source should not be empty if resolved")
        }
        // nil is also valid (no token configured)
    }
}
