// RoutingIntegrityLayerTests.swift - PKT-1094
// Server-owned tool/skill bindings, manifest-fetch dispatch gate, lifecycle
// scanners, and identity-propagation close contract.

import Foundation
import MCP
import TheBridgeLib

func runRoutingIntegrityLayerTests() async {
    print("\n\u{1F9ED} Routing Integrity Layer (PKT-1094)")

    func fakeMessagesSendRegistration() -> ToolRegistration {
        ToolRegistration(
            name: "messages_send",
            module: MessagesModule.moduleName,
            tier: .open,
            description: "Send an iMessage or SMS after explicit approval.",
            inputSchema: .object(["type": .string("object")]),
            handler: { _ in .object(["ok": .bool(true), "sent": .bool(true)]) }
        )
    }

    await test("RIL registry: messages_send names governing skills") {
        guard let binding = ToolSkillBindingRegistry.binding(for: "messages_send") else {
            throw TestError.assertion("missing messages_send binding")
        }
        let slugs = Set(binding.governingSkills.map(\.slug))
        try expect(slugs.contains("people-keepr"), "people-keepr must govern message intent")
        try expect(slugs.contains("mac-message"), "mac-message must govern delivery mechanics")
        try expect(binding.requiresManifestFetch)
    }

    await test("RIL discovery: messages_send tool description includes governance") {
        let rendered = MCPToolFactory.tool(for: fakeMessagesSendRegistration()).description ?? ""
        try expect(rendered.contains("Governance:"), "description must include governance annotation: \(rendered)")
        try expect(rendered.contains("people-keepr"), "description must name people-keepr: \(rendered)")
        try expect(rendered.contains("mac-message"), "description must name mac-message: \(rendered)")
        try expect(rendered.count <= BridgeToolDescriptionRenderer.charBudget,
                   "description budget breached: \(rendered.count)")
    }

    await test("RIL receipt: bridge_initialize carries registry snapshot") {
        try await withRILTempHome {
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\n> **Amendment record:** v7.0.2\n\nseed")
            let receipt = BridgeInitializeService.buildReceipt(
                context: BridgeInitializeContext(
                    client: "ril-test",
                    connectionState: "local",
                    macToolsAvailable: true,
                    bridgeState: "running",
                    now: rilDate("2026-07-07")
                ),
                supplemental: [],
                telemetryEventRef: "evt-ril"
            )
            try expect(receipt.schemaVersion == 3, "receipt schema must bump for RIL")
            try expect(receipt.routingIntegrity.registryVersion == ToolSkillBindingRegistry.registryVersion)
            try expect(receipt.routingIntegrity.boundToolCount == ToolSkillBindingRegistry.bindings.count)
            try expect(receipt.routingIntegrity.manifestMarkerTools.contains(BridgeInitializeModule.toolName))
            let value = BridgeInitializeModule.receiptValue(receipt)
            guard case .object(let dict) = value,
                  case .object(let ril)? = dict["routingIntegrity"],
                  case .int(let count)? = ril["boundToolCount"] else {
                throw TestError.assertion("receiptValue missing routingIntegrity.boundToolCount")
            }
            try expect(count == ToolSkillBindingRegistry.bindings.count)
        }
    }

    await test("RIL gate: fresh session cannot dispatch messages_send before manifest marker") {
        try await withRILTempHome {
            let log = AuditLog()
            let router = ToolRouter(
                securityGate: SecurityGate(),
                auditLog: log,
                licenseStatusProvider: { .trial(daysRemaining: 5) }
            )
            await MessagesModule.register(on: router)
            try await withNoDisabledTools {
                do {
                    _ = try await router.dispatch(
                        toolName: "messages_send",
                        arguments: .object([
                            "recipient": .string("+15555550123"),
                            "body": .string("dry-run probe"),
                            "confirm": .string("DRY_RUN")
                        ]),
                        context: ToolDispatchContext(transportSessionId: "ril-session-a", origin: .local)
                    )
                    throw TestError.assertion("messages_send reached handler without manifest marker")
                } catch let error as ToolRouterError {
                    if case .routingManifestRequired(let toolName, let governingSkills) = error {
                        try expect(toolName == "messages_send")
                        try expect(governingSkills.contains("people-keepr"))
                    } else {
                        throw TestError.assertion("wrong ToolRouterError case: \(error)")
                    }
                }
            }
            let entries = await log.entries(forSessionID: "ril-session-a")
            try expect(entries.count == 1, "expected exactly one rejected audit entry, got \(entries.count)")
            try expect(entries[0].toolName == "messages_send")
            try expect(entries[0].approvalStatus == .rejected)
            try expect(entries[0].outputSummary.contains("routing manifest required"))
        }
    }

    await test("RIL gate: bridge_initialize marks only the current session; real messages_send no-send guard runs after marker") {
        try await withRILTempHome {
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\n> **Amendment record:** v7.0.2\n\nseed")

            let log = AuditLog()
            let router = ToolRouter(
                securityGate: SecurityGate(),
                auditLog: log,
                licenseStatusProvider: { .trial(daysRemaining: 5) }
            )
            await router.register(BridgeInitializeModule.makeTool(
                contextProvider: { client in
                    BridgeInitializeContext(
                        client: client,
                        connectionState: "local",
                        macToolsAvailable: true,
                        bridgeState: "running",
                        now: rilDate("2026-07-07")
                    )
                },
                preflightProvider: { CapabilityPreflightRegistry(probes: []) }
            ))
            await MessagesModule.register(on: router)

            try await withNoDisabledTools {
                UserDefaults.standard.set(
                    ["messages_send": SecurityTier.open.rawValue],
                    forKey: BridgeDefaults.tierOverrides
                )
                _ = try await router.dispatch(
                    toolName: BridgeInitializeModule.toolName,
                    arguments: .object(["client": .string("ril-session-b")]),
                    context: ToolDispatchContext(transportSessionId: "ril-session-b", origin: .local)
                )
                let marked = await router.hasRoutingManifestMarker(sessionID: "ril-session-b")
                try expect(marked, "bridge_initialize must mark the session")

                let allowed = try await router.dispatch(
                    toolName: "messages_send",
                    arguments: .object([
                        "recipient": .string("+15555550123"),
                        "body": .string("dry-run probe"),
                        "confirm": .string("DRY_RUN")
                    ]),
                    context: ToolDispatchContext(transportSessionId: "ril-session-b", origin: .local)
                )
                guard case .object(let dict) = allowed,
                      case .bool(false)? = dict["sent"],
                      case .string(let error)? = dict["error"],
                      error.contains("confirm") else {
                    throw TestError.assertion("messages_send did not reach real no-send confirmation guard")
                }

                do {
                    _ = try await router.dispatch(
                        toolName: "messages_send",
                        arguments: .object([
                            "recipient": .string("+15555550123"),
                            "body": .string("dry-run probe"),
                            "confirm": .string("DRY_RUN")
                        ]),
                        context: ToolDispatchContext(transportSessionId: "ril-session-c", origin: .local)
                    )
                    throw TestError.assertion("marker leaked across sessions")
                } catch let error as ToolRouterError {
                    if case .routingManifestRequired = error { /* expected */ }
                    else { throw TestError.assertion("wrong error for unmarked second session: \(error)") }
                }
            }

            let bTools = await log.entries(forSessionID: "ril-session-b").map(\.toolName)
            try expect(bTools == [BridgeInitializeModule.toolName, "messages_send"],
                       "session b audit sequence drift: \(bTools)")
            let cEntries = await log.entries(forSessionID: "ril-session-c")
            try expect(cEntries.count == 1 && cEntries[0].approvalStatus == .rejected)
        }
    }

    await test("Amendment lifecycle: ACTIVE marker older than 30 days is due for collapse") {
        let md = """
        # Skill body
        - RIL-17 Amendment Status: ACTIVE since 2026-06-01
        - RIL-18 Amendment Status: ACTIVE since 2026-06-20
        - RIL-19 Amendment Status: SUPERSEDED since 2026-05-01
        """
        let due = AmendmentLifecycle.dueForCollapse(markdown: md, now: rilDate("2026-07-07"))
        try expect(due.map(\.identifier) == ["RIL-17"], "unexpected due markers: \(due.map(\.identifier))")
        try expect(due[0].ageDays >= 30)
    }

    await test("Amendment lifecycle: scheduler template exposes weekly scan") {
        let template = AmendmentLifecycle.jobTemplate()
        guard case .string("weekly-amendment-collapse-scan")? = template["id"],
              case .string("0 9 * * 1")? = template["schedule"],
              case .array(let actions)? = template["actions"],
              case .object(let first)? = actions.first,
              case .string("standing_orders_list")? = first["tool"] else {
            throw TestError.assertion("amendment lifecycle template shape drift: \(template)")
        }
    }

    await test("Identity propagation: unresolved impact hits block rename close") {
        let clean = IdentityPropagationScanResult(renameId: "rename-clean", unresolvedHits: 0, completedScanCycles: 1)
        try expect(IdentityPropagationContract.closeDecision(for: clean) == .canClose)

        let dirty = IdentityPropagationScanResult(renameId: "rename-dirty", unresolvedHits: 4, completedScanCycles: 1)
        try expect(IdentityPropagationContract.closeDecision(for: dirty) == .blockedByImpactHits)

        let repeated = IdentityPropagationScanResult(renameId: "rename-loop", unresolvedHits: 1, completedScanCycles: 3)
        try expect(IdentityPropagationContract.closeDecision(for: repeated) == .escalateAfterRepeatedHits)
    }
}

private func rilDate(_ yyyyMMdd: String) -> Date {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: yyyyMMdd)!
}

private func withRILTempHome(_ body: () async throws -> Void) async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("RoutingIntegrityLayer-test-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? fm.removeItem(at: tmp)
    }
    try await body()
}

private func withNoDisabledTools(_ body: () async throws -> Void) async throws {
    let defaults = UserDefaults.standard
    let priorDisabled = defaults.object(forKey: BridgeDefaults.disabledTools)
    let priorToolOverrides = defaults.object(forKey: BridgeDefaults.tierOverrides)
    let priorModuleOverrides = defaults.object(forKey: BridgeDefaults.moduleTierOverrides)
    defaults.set([], forKey: BridgeDefaults.disabledTools)
    defaults.removeObject(forKey: BridgeDefaults.tierOverrides)
    defaults.removeObject(forKey: BridgeDefaults.moduleTierOverrides)
    defer {
        restore(defaults: defaults, key: BridgeDefaults.disabledTools, value: priorDisabled)
        restore(defaults: defaults, key: BridgeDefaults.tierOverrides, value: priorToolOverrides)
        restore(defaults: defaults, key: BridgeDefaults.moduleTierOverrides, value: priorModuleOverrides)
    }
    try await body()
}

private func restore(defaults: UserDefaults, key: String, value: Any?) {
    if let value {
        defaults.set(value, forKey: key)
    } else {
        defaults.removeObject(forKey: key)
    }
}
