// CalendarRegistryModuleTests.swift — env-filtered MCP seam for calendar_registry_pair
// TheBridge · Tests
//
// Hermetic only: ListTools gate, dispatch fail-closed, missing allowlist,
// fake success receipt mapping. Does not re-run CR1–CR96.

import Foundation
import MCP
import TheBridgeLib

func runCalendarRegistryModuleTests() async {
    print("\n📅 CalendarRegistryModule — env-filtered MCP seam")
    // Literal name kept for ToolSurfaceCoverageAudit string-reference scan.
    let _ = "calendar_registry_pair"

    func clearSeams() {
        CalendarRegistryFeature.environmentOverride = nil
        CalendarRegistryModule.executeOverride = nil
    }

    func sampleArgs(calendarId: String = "cal-smoke") -> Value {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(3600)
        return .object([
            "idempotencyKey": .string("smoke-test-key-1"),
            "registryEventId": .string("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            "title": .string("Disposable smoke"),
            "start": .string(CalendarRegistryISO.string(start)),
            "end": .string(CalendarRegistryISO.string(end)),
            "timeZoneIdentifier": .string("America/Chicago"),
            "calendarId": .string(calendarId),
            "eventClass": .string("FOCUS"),
            "primaryBlockId": .string("11111111-2222-3333-4444-555555555555"),
        ])
    }

    func boundScheduleEntity() -> RegistryEntity {
        // Mirror CalendarRegistrySyncEngine.requiredScheduleCanonicalFields
        let keys = [
            "syncKey", "operationFingerprint", "calendarProvider", "calendarId",
            "calendarEventId", "providerExternalId", "calendarUrl", "eventClass",
            "meetingType", "primaryBlock", "schedulingAuthority", "syncState",
            "lastSyncedAt", "registryUpdatedAt", "calendarUpdatedAt", "syncHash",
            "lastSyncError", "scheduledDuration", "calendarLocation",
            "createInvocationId", "syncWriterToken", "syncRevision",
        ]
        return RegistryEntity(
            key: "schedule",
            displayName: "EVENTS",
            dataSourceId: "events-ds-test",
            properties: keys.enumerated().map { index, key in
                RegistryProperty(
                    key: key,
                    notionName: key,
                    notionPropertyId: "prop-\(index)",
                    type: "rich_text",
                    role: .generic
                )
            },
            cacheTTLSeconds: 0
        )
    }

    await test("calendar_registry_pair registered on calendar family with .request tier") {
        defer { clearSeams() }
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await CalendarRegistryModule.register(on: router)
        let tools = await router.registrations(forModule: "calendar")
        guard let tool = tools.first(where: { $0.name == CalendarRegistryModule.toolName }) else {
            throw TestError.assertion("calendar_registry_pair not registered")
        }
        try expect(tool.tier == .request, "tier must be .request")
        try expect(tool.neverAutoApprove == true, "neverAutoApprove for attended smoke")
        try expect(tool.module == "calendar", "family calendar")
    }

    await test("env off → ListTools omits calendar_registry_pair") {
        defer { clearSeams() }
        CalendarRegistryFeature.environmentOverride = [:]
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await CalendarRegistryModule.register(on: router)
        let disabled = ToolListingGates.mergedDisabledToolNames()
        try expect(disabled.contains(CalendarRegistryModule.toolName), "gated when env off")
        let listed = await router.registrationsForListTools(disabledNames: disabled)
        try expect(
            !listed.contains(where: { $0.name == CalendarRegistryModule.toolName }),
            "must not appear in ListTools when env off"
        )
    }

    await test("auto-approve hatch requires sync env") {
        defer { clearSeams() }
        CalendarRegistryFeature.environmentOverride = [
            CalendarRegistryFeature.autoApproveEnvironmentKey: "1",
        ]
        try expect(CalendarRegistryFeature.autoApproveEnabled == false, "auto-approve inert when sync off")
        CalendarRegistryFeature.environmentOverride = [
            CalendarRegistrySyncComposition.enableEnvironmentKey: "1",
            CalendarRegistrySyncComposition.allowedCalendarsEnvironmentKey: "cal-smoke",
            CalendarRegistryFeature.autoApproveEnvironmentKey: "1",
        ]
        try expect(CalendarRegistryFeature.autoApproveEnabled == true, "auto-approve only with sync on")
    }

    await test("env off → dispatch fail-closed") {
        defer { clearSeams() }
        CalendarRegistryFeature.environmentOverride = [:]
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await CalendarRegistryModule.register(on: router)
        do {
            _ = try await router.dispatch(toolName: CalendarRegistryModule.toolName, arguments: sampleArgs())
            throw TestError.assertion("dispatch succeeded while env off")
        } catch let err as ToolRouterError {
            switch err {
            case .invalidArguments(let toolName, let reason):
                try expect(toolName == CalendarRegistryModule.toolName)
                try expect(reason.contains("disabled"), "reason mentions disabled: \(reason)")
            default:
                throw TestError.assertion("wrong ToolRouterError: \(err)")
            }
        } catch {
            throw TestError.assertion("unexpected error type: \(error)")
        }
    }

    await test("env on without allowlist → composition missingAllowedCalendars") {
        defer { clearSeams() }
        let env = [CalendarRegistrySyncComposition.enableEnvironmentKey: "1"]
        CalendarRegistryFeature.environmentOverride = env
        do {
            _ = try CalendarRegistrySyncComposition.build(
                entity: boundScheduleEntity(),
                registryGateway: LiveRegistryGateway(),
                calendarStore: MockCalendarStore(),
                environment: env
            )
            throw TestError.assertion("expected missingAllowedCalendars")
        } catch let err as CalendarRegistrySyncCompositionError {
            try expect(err == .missingAllowedCalendars, "got \(err)")
        } catch {
            throw TestError.assertion("unexpected error: \(error)")
        }
    }

    await test("qualify: allowlisted writable caldav is private-smoke eligible; subscription is not") {
        let caldav = MockCalendarStore(calendars: [
            CalendarInfo(
                id: "cal-icloud",
                title: "FOCUS",
                isDefault: false,
                allowsModify: true,
                calendarType: "caldav",
                sourceType: "caldav"
            ),
            CalendarInfo(
                id: "cal-sub",
                title: "Holidays",
                isDefault: false,
                allowsModify: false,
                calendarType: "subscription",
                sourceType: "subscribed"
            ),
        ])
        let provider = CalendarStoringSyncProvider(
            store: caldav,
            allowlistedCalendarIds: ["cal-icloud", "cal-sub"]
        )
        let ok = try await provider.qualify(calendarId: "cal-icloud")
        try expect(ok.qualifiedForPrivateSmoke == true, "allowlisted writable caldav should qualify")
        let blocked = try await provider.qualify(calendarId: "cal-sub")
        try expect(blocked.qualifiedForPrivateSmoke == false, "subscribed calendar must not qualify")
    }

    await test("env on + executeOverride → fake success receipt mapping") {
        defer { clearSeams() }
        CalendarRegistryFeature.environmentOverride = [
            CalendarRegistrySyncComposition.enableEnvironmentKey: "1",
            CalendarRegistrySyncComposition.allowedCalendarsEnvironmentKey: "cal-smoke",
        ]
        CalendarRegistryModule.executeOverride = { request in
            .object([
                "succeeded": .bool(true),
                "infrastructureFault": .bool(false),
                "operationId": .string("op-fake"),
                "idempotencyKey": .string(request.idempotencyKey),
                "operationFingerprint": .string("fp-fake"),
                "stageBefore": .string("claimed"),
                "stageAfter": .string("complete"),
                "singleMachineCoordinator": .bool(true),
                "registryIdentityCount": .int(1),
                "calendarIdentityCount": .int(1),
                "calendarItem": .object([
                    "provider": .string("eventkit"),
                    "calendarId": .string(request.calendarId),
                    "localEventId": .string("ek-local-1"),
                    "title": .string(request.title),
                    "start": .string(CalendarRegistryISO.string(request.start)),
                    "end": .string(CalendarRegistryISO.string(request.end)),
                    "timeZoneIdentifier": .string(request.timeZoneIdentifier),
                ]),
            ])
        }

        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await CalendarRegistryModule.register(on: router)
        let disabled = ToolListingGates.mergedDisabledToolNames()
        try expect(!disabled.contains(CalendarRegistryModule.toolName), "listed when env on")

        let tools = await router.registrations(forModule: "calendar")
        guard let tool = tools.first(where: { $0.name == CalendarRegistryModule.toolName }) else {
            throw TestError.assertion("tool missing")
        }
        let result = try await tool.handler(sampleArgs())
        guard case .object(let obj) = result else {
            throw TestError.assertion("expected object receipt")
        }
        guard case .bool(true)? = obj["succeeded"] else {
            throw TestError.assertion("succeeded != true")
        }
        guard case .string(let key)? = obj["idempotencyKey"] else {
            throw TestError.assertion("missing idempotencyKey")
        }
        try expect(key == "smoke-test-key-1")
        guard case .bool(true)? = obj["singleMachineCoordinator"] else {
            throw TestError.assertion("singleMachineCoordinator missing")
        }
        guard case .object(let item)? = obj["calendarItem"],
              case .string(let localId)? = item["localEventId"] else {
            throw TestError.assertion("calendarItem.localEventId missing")
        }
        try expect(localId == "ek-local-1")
        guard case .int(1)? = obj["registryIdentityCount"],
              case .int(1)? = obj["calendarIdentityCount"] else {
            throw TestError.assertion("identity counts must be 1/1")
        }
    }
}
