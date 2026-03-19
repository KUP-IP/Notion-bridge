// SkillsModuleTests.swift – QA: SkillsModule Test Coverage
// NotionBridge · Tests
//
// Validates tool registration, count, names, and security tiers for SkillsModule.
// Follows the same pattern as GoogleDriveModuleTests.

import Foundation
import MCP
import NotionBridgeLib

// MARK: - SkillsModule Tests

func runSkillsModuleTests() async {
    print("\n🧠 SkillsModule Tests")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log, batchThreshold: 10)
    await SkillsModule.register(on: router)

    // ============================================================
    // MARK: - Tool Registration (1 tool)
    // ============================================================

    await test("SkillsModule registers 1 tool") {
        let tools = await router.registrations(forModule: "skills")
        try expect(tools.count == 1, "Expected 1 skills tool, got \(tools.count)")
    }

    await test("Tool fetch_skill is registered") {
        let tools = await router.registrations(forModule: "skills")
        let names = Set(tools.map(\.name))
        try expect(names.contains("fetch_skill"), "Missing fetch_skill")
    }

    // ============================================================
    // MARK: - Security Tier
    // ============================================================

    await test("fetch_skill has open tier") {
        let tools = await router.registrations(forModule: "skills")
        let tool = tools.first(where: { $0.name == "fetch_skill" })
        try expect(tool != nil, "fetch_skill not found")
        try expect(tool!.tier == .open, "fetch_skill should be .open, got \(tool!.tier)")
    }

    // ============================================================
    // MARK: - Tool Description & Schema
    // ============================================================

    await test("fetch_skill has non-empty description") {
        let tools = await router.registrations(forModule: "skills")
        let tool = tools.first(where: { $0.name == "fetch_skill" })
        try expect(tool != nil, "fetch_skill not found")
        try expect(!tool!.description.isEmpty, "fetch_skill has empty description")
    }

    await test("fetch_skill has input schema") {
        let tools = await router.registrations(forModule: "skills")
        let tool = tools.first(where: { $0.name == "fetch_skill" })
        try expect(tool != nil, "fetch_skill not found")
        if case .object = tool!.inputSchema {
            // valid
        } else {
            throw TestError.assertion("fetch_skill inputSchema is not an object")
        }
    }

    // ============================================================
    // MARK: - Required Parameters
    // ============================================================

    await test("fetch_skill requires 'name' parameter") {
        let tools = await router.registrations(forModule: "skills")
        let tool = tools.first(where: { $0.name == "fetch_skill" })
        try expect(tool != nil, "fetch_skill not found")
        if case .object(let schema) = tool!.inputSchema,
           case .array(let required) = schema["required"] {
            let requiredNames = required.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            try expect(requiredNames.contains("name"), "fetch_skill should require 'name'")
        }
    }
}
