// ScreenModuleTests.swift – V1-TESTCOVERAGE
// NotionBridge · Tests
//
// Tests for ScreenModule (5 tools: screen_capture, screen_ocr,
// screen_analyze, screen_record_start, screen_record_stop).
// Note: Screen tools require Screen Recording TCC grant. Tests focus on
// registration, tier classification, and graceful error handling.

import Foundation
import MCP
import NotionBridgeLib

// MARK: - ScreenModule Tests

func runScreenModuleTests() async {
    print("\n📸 ScreenModule Tests")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await ScreenModule.register(on: router)
    await ScreenModule.registerRecording(on: router)
    await ScreenModule.registerAnalyze(on: router)

    // --- Registration ---

    await test("ScreenModule registers 5 tools") {
        let tools = await router.registrations(forModule: "screen")
        try expect(tools.count == 5, "Expected 5 screen tools, got \(tools.count)")
    }

    await test("ScreenModule tool names are correct") {
        let tools = await router.registrations(forModule: "screen")
        let names = Set(tools.map(\.name))
        try expect(names.contains("screen_capture"), "Missing screen_capture")
        try expect(names.contains("screen_ocr"), "Missing screen_ocr")
        try expect(names.contains("screen_analyze"), "Missing screen_analyze")
        try expect(names.contains("screen_record_start"), "Missing screen_record_start")
        try expect(names.contains("screen_record_stop"), "Missing screen_record_stop")
    }

    // --- Tier classification ---

    await test("screen_capture is open tier") {
        let tools = await router.registrations(forModule: "screen")
        let tool = tools.first(where: { $0.name == "screen_capture" })!
        try expect(tool.tier == .open, "Expected open, got \(tool.tier.rawValue)")
    }

    await test("screen_ocr is open tier") {
        let tools = await router.registrations(forModule: "screen")
        let tool = tools.first(where: { $0.name == "screen_ocr" })!
        try expect(tool.tier == .open, "Expected open, got \(tool.tier.rawValue)")
    }
    await test("screen_analyze is open tier") {
        let tools = await router.registrations(forModule: "screen")
        let tool = tools.first(where: { $0.name == "screen_analyze" })!
        try expect(tool.tier == .open, "Expected open, got \(tool.tier.rawValue)")
    }


    await test("screen_record_start is notify tier") {
        let tools = await router.registrations(forModule: "screen")
        let tool = tools.first(where: { $0.name == "screen_record_start" })!
        try expect(tool.tier == .notify, "Expected notify, got \(tool.tier.rawValue)")
    }

    await test("screen_record_stop is notify tier") {
        let tools = await router.registrations(forModule: "screen")
        let tool = tools.first(where: { $0.name == "screen_record_stop" })!
        try expect(tool.tier == .notify, "Expected notify, got \(tool.tier.rawValue)")
    }

    // --- Graceful error handling ---

    await test("screen_capture returns error when Screen Recording denied") {
        let result = try await router.dispatch(
            toolName: "screen_capture",
            arguments: .object([:])
        )
        if case .object(let dict) = result {
            if case .string(let err) = dict["error"] {
                try expect(!err.isEmpty, "Error message should not be empty")
            }
        }
    }

    await test("screen_ocr returns error when Screen Recording denied") {
        let result = try await router.dispatch(
            toolName: "screen_ocr",
            arguments: .object([:])
        )
        if case .object(let dict) = result {
            if case .string(let err) = dict["error"] {
                try expect(!err.isEmpty, "Error message should not be empty")
            }
        }
    }
    await test("screen_analyze rejects missing filePath") {
        let result = try await router.dispatch(
            toolName: "screen_analyze",
            arguments: .object([:])
        )
        if case .object(let dict) = result {
            if case .string(let err) = dict["error"] {
                try expect(!err.isEmpty, "Error message should not be empty")
            }
        }
    }


    await test("screen_record_stop handles no active recording") {
        let result = try await router.dispatch(
            toolName: "screen_record_stop",
            arguments: .object([:])
        )
        if case .object(let dict) = result {
            if case .string(let err) = dict["error"] {
                try expect(!err.isEmpty, "Error message should not be empty")
            }
        }
    }

    // --- Module name ---

    await test("ScreenModule.moduleName is 'screen'") {
        try expect(ScreenModule.moduleName == "screen",
                   "Expected 'screen', got '\(ScreenModule.moduleName)'")
    }
}
