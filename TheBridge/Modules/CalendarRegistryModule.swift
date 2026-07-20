// CalendarRegistryModule.swift — env-filtered registry-first pairing MCP tool
// TheBridge · Modules
//
// Thin surface over CalendarRegistrySyncComposition / registryFirstCreate.
// Listed only when BRIDGE_INTERNAL_CALENDAR_REGISTRY_SYNC=1; dispatch also
// fail-closes when composition is disabled. Family: calendar (same as EventKit).

import Foundation
import MCP

public enum CalendarRegistryModule {

    public static let moduleName = "calendar"
    public static let toolName = "calendar_registry_pair"

    /// Hermetic seam: when set, skips live composition/EventKit and returns the
    /// override Value (or throws). Cleared by tests in `defer`.
    public nonisolated(unsafe) static var executeOverride:
        (@Sendable (RegistryFirstTimeInstanceRequest) async throws -> Value)?

    public static func register(
        on router: ToolRouter,
        calendarStore: CalendarStoring = EventKitCalendarStore()
    ) async {
        await router.register(ToolRegistration(
            name: toolName,
            module: moduleName,
            tier: .request,
            neverAutoApprove: true,
            description: """
            Pair one pre-existing Registry-authority Notion EVENT with one allowlisted \
            private local EventKit item (registry-first). Requires an attended approval \
            window. Only discoverable when BRIDGE_INTERNAL_CALENDAR_REGISTRY_SYNC=1 and \
            BRIDGE_INTERNAL_CALENDAR_REGISTRY_ALLOWED_CALENDARS is set. Caller must supply \
            schedule fields from a fresh Notion EVENT read — no inference. When to use: \
            disposable private smoke pairing. Not for: import, reschedule, cancel/detach, \
            recurrence, attendees, or always-on sync. Related: calendar_list, registry_get.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "idempotencyKey": .object([
                        "type": .string("string"),
                        "description": .string("Stable 1–128 char key (letters, digits, . _ : -)"),
                    ]),
                    "registryEventId": .object([
                        "type": .string("string"),
                        "description": .string("Pre-existing Notion EVENT page id"),
                    ]),
                    "title": .object(["type": .string("string")]),
                    "start": .object([
                        "type": .string("string"),
                        "description": .string("ISO-8601 scheduled start from the live EVENT"),
                    ]),
                    "end": .object([
                        "type": .string("string"),
                        "description": .string("ISO-8601 scheduled end from the live EVENT"),
                    ]),
                    "timeZoneIdentifier": .object(["type": .string("string")]),
                    "calendarId": .object([
                        "type": .string("string"),
                        "description": .string("Allowlisted writable local EventKit calendar id"),
                    ]),
                    "location": .object(["type": .string("string")]),
                    "notes": .object(["type": .string("string")]),
                    "eventClass": .object([
                        "type": .string("string"),
                        "description": .string("FOCUS | PLEASE | Meeting | Presentation | Appointment | Travel | Buffer"),
                    ]),
                    "meetingType": .object(["type": .string("string")]),
                    "primaryBlockId": .object([
                        "type": .string("string"),
                        "description": .string("Primary BLOCK page id from the live EVENT"),
                    ]),
                    "blockIds": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                    "projectIds": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                    "contactIds": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
                "required": .array([
                    .string("idempotencyKey"),
                    .string("registryEventId"),
                    .string("title"),
                    .string("start"),
                    .string("end"),
                    .string("timeZoneIdentifier"),
                    .string("calendarId"),
                    .string("eventClass"),
                    .string("primaryBlockId"),
                ]),
            ]),
            handler: { arguments in
                try await handlePair(arguments: arguments, calendarStore: calendarStore)
            }
        ))
    }

    // MARK: - Handler

    private static func handlePair(
        arguments: Value,
        calendarStore: CalendarStoring
    ) async throws -> Value {
        let env = CalendarRegistryFeature.currentEnvironment
        guard CalendarRegistrySyncComposition.featureState(environment: env) == .enabledForPrivateSmoke else {
            throw ToolRouterError.invalidArguments(
                toolName: toolName,
                reason: "Calendar–Registry pairing is disabled. Set BRIDGE_INTERNAL_CALENDAR_REGISTRY_SYNC=1 and an allowlist for a private smoke session only."
            )
        }

        let request = try parseRequest(arguments)

        if let executeOverride {
            return try await executeOverride(request)
        }

        let config = await RegistryModule.loadConfig()
        let entity = try RegistryModule.requireEntity("schedule", in: config, tool: toolName)
        let engine = try CalendarRegistrySyncComposition.build(
            entity: entity,
            registryGateway: RegistryModule.gateway(),
            calendarStore: calendarStore,
            environment: env
        )
        let receipt = try await engine.registryFirstCreate(request)
        return encodeReceipt(receipt)
    }

    // MARK: - Parsing

    private static func parseRequest(_ arguments: Value) throws -> RegistryFirstTimeInstanceRequest {
        let args = objectArgs(arguments)
        func requireString(_ key: String) throws -> String {
            guard let s = stringArg(args, key), !s.isEmpty else {
                throw ToolRouterError.invalidArguments(toolName: toolName, reason: "missing '\(key)'")
            }
            return s
        }
        let eventClassRaw = try requireString("eventClass")
        guard let eventClass = TimeInstanceEventClass(rawValue: eventClassRaw) else {
            throw ToolRouterError.invalidArguments(
                toolName: toolName,
                reason: "invalid eventClass '\(eventClassRaw)' — expected FOCUS|PLEASE|Meeting|Presentation|Appointment|Travel|Buffer"
            )
        }
        let startString = try requireString("start")
        let endString = try requireString("end")
        guard let start = CalendarRegistryISO.date(startString) else {
            throw ToolRouterError.invalidArguments(toolName: toolName, reason: "invalid ISO-8601 start: \(startString)")
        }
        guard let end = CalendarRegistryISO.date(endString) else {
            throw ToolRouterError.invalidArguments(toolName: toolName, reason: "invalid ISO-8601 end: \(endString)")
        }
        return RegistryFirstTimeInstanceRequest(
            idempotencyKey: try requireString("idempotencyKey"),
            registryEventId: try requireString("registryEventId"),
            title: try requireString("title"),
            start: start,
            end: end,
            timeZoneIdentifier: try requireString("timeZoneIdentifier"),
            calendarId: try requireString("calendarId"),
            location: stringArg(args, "location"),
            notes: stringArg(args, "notes"),
            semantics: TimeInstanceSemantics(
                eventClass: eventClass,
                meetingType: stringArg(args, "meetingType"),
                primaryBlockId: try requireString("primaryBlockId"),
                blockIds: stringArrayArg(args, "blockIds"),
                projectIds: stringArrayArg(args, "projectIds"),
                contactIds: stringArrayArg(args, "contactIds")
            )
        )
    }

    // MARK: - Receipt encoding

    public static func encodeReceipt(_ receipt: CalendarRegistrySyncReceipt) -> Value {
        var obj: [String: Value] = [
            "succeeded": .bool(receipt.succeeded),
            "infrastructureFault": .bool(receipt.infrastructureFault),
            "recoveryStatePersisted": .bool(receipt.recoveryStatePersisted),
            "registryFailureStatePersisted": .bool(receipt.registryFailureStatePersisted),
            "operationId": .string(receipt.operationId),
            "idempotencyKey": .string(receipt.idempotencyKey),
            "operationFingerprint": .string(receipt.operationFingerprint),
            "stageBefore": .string(receipt.stageBefore.rawValue),
            "stageAfter": .string(receipt.stageAfter.rawValue),
            "registryFieldsWritten": .array(receipt.registryFieldsWritten.map { .string($0) }),
            "calendarFieldsWritten": .array(receipt.calendarFieldsWritten.map { .string($0) }),
            "verificationEvidence": .array(receipt.verificationEvidence.map { .string($0) }),
            "partialEffects": .array(receipt.partialEffects.map { .string($0) }),
            "calendarSearchScopes": .array(receipt.calendarSearchScopes.map { .string($0) }),
            "ledgerOutcomePersisted": .bool(receipt.ledgerOutcomePersisted),
            "notionOutcomePersisted": .bool(receipt.notionOutcomePersisted),
            "pairIdentityPersisted": .bool(receipt.pairIdentityPersisted),
            "coordinatorReleaseSucceeded": .bool(receipt.coordinatorReleaseSucceeded),
            "singleMachineCoordinator": .bool(true),
        ]
        if let v = receipt.fencingToken { obj["fencingToken"] = .string(v) }
        if let v = receipt.ledgerRevision { obj["ledgerRevision"] = .int(v) }
        if let v = receipt.verifiedSyncHash { obj["verifiedSyncHash"] = .string(v) }
        if let v = receipt.verifiedAt { obj["verifiedAt"] = .string(CalendarRegistryISO.string(v)) }
        if let v = receipt.recoveryAction { obj["recoveryAction"] = .string(v) }
        if let v = receipt.discrepancy { obj["discrepancy"] = .string(v) }
        if let v = receipt.coordinatorNamespace { obj["coordinatorNamespace"] = .string(v) }
        if let v = receipt.registryIdentityCount { obj["registryIdentityCount"] = .int(v) }
        if let v = receipt.calendarIdentityCount { obj["calendarIdentityCount"] = .int(v) }
        if let v = receipt.finalRegistryRevision { obj["finalRegistryRevision"] = .string(v) }
        if let v = receipt.attemptId { obj["attemptId"] = .string(v) }
        if let v = receipt.createInvocationId { obj["createInvocationId"] = .string(v) }
        if let v = receipt.syncWriterToken { obj["syncWriterToken"] = .string(v) }
        if let v = receipt.syncRevision { obj["syncRevision"] = .int(v) }
        if let item = receipt.calendarItem {
            obj["calendarItem"] = .object([
                "provider": .string(item.provider),
                "calendarId": .string(item.calendarId),
                "localEventId": .string(item.localEventId),
                "title": .string(item.title),
                "start": .string(CalendarRegistryISO.string(item.start)),
                "end": .string(CalendarRegistryISO.string(item.end)),
                "timeZoneIdentifier": .string(item.timeZoneIdentifier),
            ])
        }
        return .object(obj)
    }

    // MARK: - Arg helpers

    private static func objectArgs(_ value: Value) -> [String: Value] {
        if case .object(let o) = value { return o }
        return [:]
    }

    private static func stringArg(_ args: [String: Value], _ key: String) -> String? {
        if case .string(let s)? = args[key] {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return nil
    }

    private static func stringArrayArg(_ args: [String: Value], _ key: String) -> [String] {
        guard case .array(let arr)? = args[key] else { return [] }
        return arr.compactMap { v -> String? in
            guard case .string(let s) = v else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
    }
}
