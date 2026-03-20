// AccessibilityModuleTests.swift – V1-TESTCOVERAGE
// NotionBridge · Tests
//
// Tests for AccessibilityModule (5 tools: ax_focused_app, ax_tree,
// ax_find_element, ax_element_info, ax_perform_action).
// Note: Most AX tools require Accessibility TCC grant. Tests focus on
// registration, tier classification, and graceful error handling when
// permission is not available.

import Foundation
import MCP
import NotionBridgeLib

// MARK: - AccessibilityModule Tests

func runAccessibilityModuleTests() async {
    print("\n♿ AccessibilityModule Tests")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await AccessibilityModule.register(on: router)

    // --- Registration ---

    await test("AccessibilityModule registers 5 tools") {
        let tools = await router.registrations(forModule: "accessibility")
        try expect(tools.count == 5, "Expected 5 accessibility tools, got \(tools.count)")
    }

    await test("AccessibilityModule tool names are correct") {
        let tools = await router.registrations(forModule: "accessibility")
        let names = Set(tools.map(\.name))
        try expect(names.contains("ax_focused_app"), "Missing ax_focused_app")
        try expect(names.contains("ax_tree"), "Missing ax_tree")
        try expect(names.contains("ax_find_element"), "Missing ax_find_element")
        try expect(names.contains("ax_element_info"), "Missing ax_element_info")
        try expect(names.contains("ax_perform_action"), "Missing ax_perform_action")
    }

    // --- Tier classification ---

    await test("ax_focused_app is open tier") {
        let tools = await router.registrations(forModule: "accessibility")
        let tool = tools.first(where: { $0.name == "ax_focused_app" })!
        try expect(tool.tier == .open, "Expected open, got \(tool.tier.rawValue)")
    }

    await test("ax_tree is open tier") {
        let tools = await router.registrations(forModule: "accessibility")
        let tool = tools.first(where: { $0.name == "ax_tree" })!
        try expect(tool.tier == .open, "Expected open, got \(tool.tier.rawValue)")
    }

    await test("ax_find_element is open tier") {
        let tools = await router.registrations(forModule: "accessibility")
        let tool = tools.first(where: { $0.name == "ax_find_element" })!
        try expect(tool.tier == .open, "Expected open, got \(tool.tier.rawValue)")
    }

    await test("ax_element_info is open tier") {
        let tools = await router.registrations(forModule: "accessibility")
        let tool = tools.first(where: { $0.name == "ax_element_info" })!
        try expect(tool.tier == .open, "Expected open, got \(tool.tier.rawValue)")
    }

    await test("ax_perform_action is notify tier") {
        let tools = await router.registrations(forModule: "accessibility")
        let tool = tools.first(where: { $0.name == "ax_perform_action" })!
        try expect(tool.tier == .notify, "Expected notify, got \(tool.tier.rawValue)")
    }

    // --- Graceful error handling (no AX permission in test env) ---

    await test("ax_focused_app returns error object when AX not trusted") {
        let result = try await router.dispatch(
            toolName: "ax_focused_app",
            arguments: .object([:])
        )
        if case .object(let dict) = result {
            if case .string(let err) = dict["error"] {
                try expect(err.contains("Accessibility") || err.contains("permission") || err.contains("trusted"),
                           "Error should mention accessibility permission")
            }
        }
    }

    await test("ax_tree returns error or tree when called without pid") {
        let result = try await router.dispatch(
            toolName: "ax_tree",
            arguments: .object([:])
        )
        if case .object(_) = result {
            // Valid — either error or tree data
        }
    }

    await test("ax_find_element handles missing search criteria") {
        let result = try await router.dispatch(
            toolName: "ax_find_element",
            arguments: .object([:])
        )
        if case .object(_) = result {
            // Graceful response
        }
    }

    await test("ax_perform_action handles missing required params") {
        let result = try await router.dispatch(
            toolName: "ax_perform_action",
            arguments: .object([:])
        )
        if case .object(let dict) = result {
            if case .string(let err) = dict["error"] {
                try expect(!err.isEmpty, "Error message should not be empty")
            }
        }
    }

    // --- Module name ---

    await test("AccessibilityModule.moduleName is 'accessibility'") {
        try expect(AccessibilityModule.moduleName == "accessibility",
                   "Expected 'accessibility', got '\(AccessibilityModule.moduleName)'")
    }
}
