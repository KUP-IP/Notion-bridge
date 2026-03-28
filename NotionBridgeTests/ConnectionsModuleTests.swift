import Foundation
import MCP
import NotionBridgeLib

func runConnectionsModuleTests() async {
    print("\n🔌 ConnectionsModule Tests")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await ConnectionsModule.register(on: router)

    await test("ConnectionsModule registers 5 tools") {
        let tools = await router.registrations(forModule: "connections")
        try expect(tools.count == 5, "Expected 5 connections tools, got \(tools.count)")
    }

    let expectedTools = [
        "connections_list",
        "connections_get",
        "connections_health",
        "connections_validate",
        "connections_capabilities"
    ]

    for toolName in expectedTools {
        await test("Tool \(toolName) is registered") {
            let tools = await router.registrations(forModule: "connections")
            try expect(tools.contains(where: { $0.name == toolName }), "Missing \(toolName)")
        }
    }

    for toolName in expectedTools {
        await test("\(toolName) tier is open") {
            let tools = await router.registrations(forModule: "connections")
            guard let tool = tools.first(where: { $0.name == toolName }) else {
                throw TestError.assertion("Tool \(toolName) not found")
            }
            try expect(tool.tier == .open, "Expected open tier for \(toolName)")
        }
    }
}
