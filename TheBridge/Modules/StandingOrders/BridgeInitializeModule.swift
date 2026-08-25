// BridgeInitializeModule.swift — PKT-1065A
// TheBridge · Modules · StandingOrders
//
// The single canonical `bridge_initialize` MCP tool. One call runs the
// deterministic init-core (`BridgeInitializeService.run`) — locate + load the
// doctrine, verify the doctrine SHA-256, enforce required-source + integrity
// policy, inspect routing + supplemental orders + capability — and PERSIST a
// structured handshake receipt, emitting one distinct telemetry event.
//
// Tier `.open`: a pure read + local-evidence write (its own receipt file). It
// mutates no operator config and exposes no secrets; it only records what the
// bridge observed at handshake. Mirrors bridge_status / session_info posture.

import Foundation
import MCP

public enum BridgeInitializeModule {

    public static let moduleName = "standing_orders"
    public static let toolName = "bridge_initialize"

    /// Builds the intent-sensitive capability-preflight registry for a
    /// handshake. Injectable so tests drive the Reminders adapter with the mock
    /// seam. Default binds the live EventKit-backed reminders store.
    public typealias PreflightProvider = @Sendable () -> CapabilityPreflightRegistry
    public typealias RoutingSnapshotProvider = @Sendable (_ now: Date) async -> SkillRoutingSnapshot
    public typealias RoutingFreshnessRefresher = @Sendable () async -> Void

    /// Default preflight: the Reminders adapter over the live EventKit store.
    /// The registry runs NO probe unless the opening intent requires it, so
    /// building it here has no cost / side effects on a data-minimal handshake.
    public static let defaultPreflightProvider: PreflightProvider = {
        CapabilityPreflightRegistry(probes: [
            RemindersCapabilityProbe(store: EventKitRemindersStore())
        ])
    }
    public static let defaultRoutingSnapshotProvider: RoutingSnapshotProvider = { now in
        await routingSnapshotForInitialize(
            now: now,
            snapshotProvider: { await SkillsModule.routingSnapshot(now: $0) },
            refresh: { _ = await SkillExposureReconciliationCoordinator.shared.runShadow() }
        )
    }

    /// A stale Runtime Exposure generation is expected to recover through the
    /// startup shadow reconciliation. The MCP server becomes reachable before
    /// that network-backed refresh completes, so the first handshake must join
    /// the in-flight refresh instead of returning a transient empty manifest.
    @_spi(Testing)
    public static func routingSnapshotForInitialize(
        now: Date,
        snapshotProvider: @escaping RoutingSnapshotProvider,
        refresh: @escaping RoutingFreshnessRefresher
    ) async -> SkillRoutingSnapshot {
        let initial = await snapshotProvider(now)
        guard initial.metadata.status == .degraded,
              initial.metadata.reason == "runtime_exposure_freshness_expired"
        else { return initial }
        await refresh()
        return await snapshotProvider(Date())
    }

    /// Resolves the live runtime context (connection + capability + clock) for a
    /// handshake. Injectable so tests can pin a deterministic instant. The
    /// default reads the per-request `ToolDispatchContext.current` (set by
    /// `ToolRouter` around every dispatch, same source `RemoteControlPlanePolicy`
    /// reads) to report the CALLER'S actual origin, rather than assuming local.
    public typealias ContextProvider = @Sendable (_ client: String?) async -> BridgeInitializeContext

    /// Default provider: origin-aware connection state, Mac tools available,
    /// wall-clock now.
    ///
    /// 2026-07-10 fix: previously hardcoded `connectionState: "local"`
    /// unconditionally — a remote/cloud connector caller would be told
    /// `connectionState: "local"` / `capabilityState: "FULL"` here, then have
    /// control-plane tools (shell_exec, credential_*, …) refused with
    /// `origin: "remote"` moments later by `RemoteControlPlanePolicy`. Live-
    /// verified as a real contradiction, not a hypothetical. Now reads the same
    /// `ToolDispatchContext.current.origin` that policy already uses: `.remote`
    /// → `"online"` (the existing vocabulary `bridge_status` uses for a healthy
    /// tunnel; `BridgeInitializeService.capabilityState` already treats it as
    /// `.full` via its default case — no downstream logic change needed).
    /// `.local` (or no ambient context, e.g. stdio/tests) → `"local"`, unchanged.
    public static let defaultContextProvider: ContextProvider = { client in
        let origin = ToolDispatchContext.current?.origin ?? .local
        return BridgeInitializeContext(
            client: client,
            connectionState: origin == .remote ? "online" : "local",
            macToolsAvailable: true,
            bridgeState: "running",
            now: Date()
        )
    }

    public static func register(
        on router: ToolRouter,
        contextProvider: @escaping ContextProvider = defaultContextProvider,
        preflightProvider: @escaping PreflightProvider = defaultPreflightProvider,
        routingSnapshotProvider: @escaping RoutingSnapshotProvider = defaultRoutingSnapshotProvider
    ) async {
        await router.register(makeTool(contextProvider: contextProvider,
                                       preflightProvider: preflightProvider,
                                       routingSnapshotProvider: routingSnapshotProvider))
    }

    /// Factory for the `bridge_initialize` registration (exposed for tests).
    public static func makeTool(
        contextProvider: @escaping ContextProvider = defaultContextProvider,
        preflightProvider: @escaping PreflightProvider = defaultPreflightProvider,
        routingSnapshotProvider: @escaping RoutingSnapshotProvider = defaultRoutingSnapshotProvider
    ) -> ToolRegistration {
        ToolRegistration(
            name: toolName,
            module: moduleName,
            tier: .open,
            description: "Run the canonical Bridge initialization handshake: locate + load the "
                + "standing-orders doctrine (orders.md + manifest.json + metadata.json), verify the "
                + "doctrine SHA-256 (expected vs actual), enforce the required-source + integrity "
                + "policy, inspect the routing roster + supplemental orders + capability state, and "
                + "persist a structured, durable handshake receipt. Initialization state "
                + "(INCOMPLETE|DEGRADED|COMPLETE) is reported SEPARATELY from runtime capability "
                + "state. Returns the full receipt { handshakeId, finalState, integrityResult, "
                + "expectedHash, actualHash, routingRosterState, supplementalOrderCounts, "
                + "capabilityState, capabilityMatrix, routingRosterQuality, preflightIntent, "
                + "operatorSummary, telemetryEventRef, … }. Each call is one distinct evidence event. "
                + "Initialization is DATA-MINIMAL by default: pass an `intent` ONLY when the opening "
                + "task needs a domain capability (e.g. reminders) — a domain probe then runs to report "
                + "access + writable-list availability (and a BOUNDED content read only when the intent "
                + "requires reminder content). With no intent, no domain probe runs.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "client": .object([
                        "type": .string("string"),
                        "description": .string("Optional client name (e.g. the MCP clientInfo.name) to attribute this handshake to.")
                    ]),
                    "intent": .object([
                        "type": .string("string"),
                        "description": .string("Optional opening intent. Free text (e.g. \"add a reminder\", "
                            + "\"what's on my reminders\") or a canonical token (reminders.manage / "
                            + "reminders.read). Governs the intent-sensitive capability preflight: a "
                            + "reminders intent probes access + writable-list availability; a read/list "
                            + "intent additionally performs a BOUNDED content read. Omit for a universal, "
                            + "data-minimal handshake that runs NO domain probe.")
                    ]),
                    "mode": .object([
                        "type": .string("string"),
                        "enum": .array(BrokerSessionMode.allCases.map { .string($0.rawValue) }),
                        "description": .string("Optional broker session mode: recon, execute, background, or general. Defaults to general.")
                    ]),
                    "includeConstitution": .object([
                        "type": .string("boolean"),
                        "description": .string("When true, include the constitution bundle (doctrine + command index + routing roster + supplemental order bodies). Defaults to false — lean receipt. Prefer false unless you need constitution.orders.")
                    ])
                ]),
                "required": .array([])
            ]),
            metadata: ToolMetadata(
                title: "Bridge Initialize",
                whenToUse: [
                    "At session start, to run the canonical handshake and get a durable receipt proving the doctrine loaded and its integrity.",
                    "To re-verify doctrine integrity + routing/capability state on demand."
                ],
                whenNotToUse: [
                    "Editing standing orders (use standing_orders_save).",
                    "Checking only cloud health (use bridge_status)."
                ],
                relatedTools: ["bridge_status", "session_info", "standing_orders_list"]
            ),
            handler: { arguments in
                let client: String? = {
                    if case .object(let a) = arguments, case .string(let s)? = a["client"] {
                        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        return t.isEmpty ? nil : t
                    }
                    return nil
                }()
                let rawIntent: String? = {
                    if case .object(let a) = arguments, case .string(let s)? = a["intent"] {
                        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        return t.isEmpty ? nil : t
                    }
                    return nil
                }()
                let intent = PreflightIntent.classify(rawIntent)
                let mode: BrokerSessionMode = {
                    guard case .object(let a) = arguments,
                          case .string(let raw)? = a["mode"],
                          let mode = BrokerSessionMode(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
                    else { return .general }
                    return mode
                }()
                let includeConstitution: Bool = {
                    guard case .object(let a) = arguments,
                          let raw = a["includeConstitution"]
                    else { return false }
                    if case .bool(let value) = raw { return value }
                    return false
                }()
                let context = await contextProvider(client)
                let routingSnapshot = await routingSnapshotProvider(context.now)
                // Only build a preflight registry when an intent unlocks a probe
                // — the universal, data-minimal path stays probe-free.
                let preflight = intent == .none ? nil : preflightProvider()
                let receipt = await BridgeInitializeService.run(
                    context: context,
                    mode: mode,
                    includeConstitution: includeConstitution,
                    intent: intent,
                    preflight: preflight,
                    routingSnapshot: routingSnapshot
                )
                return receiptValue(receipt)
            }
        )
    }

    // MARK: - Serialization

    /// Serialize a `HandshakeReceipt` to the MCP `Value` result. All fields the
    /// packet enumerates are present; nil hashes serialize as JSON null-safe
    /// omission via `.string`-when-present.
    public static func receiptValue(_ r: HandshakeReceipt) -> Value {
        var d: [String: Value] = [
            "ok": .bool(true),
            "tool": .string(toolName),
            "handshakeId": .string(r.handshakeId),
            "schemaVersion": .int(r.schemaVersion),
            "timestamp": .string(ISO8601DateFormatter().string(from: r.timestamp)),
            "bridgeState": .string(r.bridgeState),
            "macToolsAvailable": .bool(r.macToolsAvailable),
            "doctrineVersion": .string(r.doctrineVersion),
            "integrityResult": .string(r.integrityResult),
            "routingRosterState": .string(r.routingRosterState),
            "routingWarnings": .array(r.routingWarnings.map { .string($0) }),
            "supplementalOrderCounts": .object([
                "found": .int(r.supplementalOrderCounts.found),
                "operative": .int(r.supplementalOrderCounts.operative),
                "ignored": .int(r.supplementalOrderCounts.ignored),
            ]),
            "connectionState": .string(r.connectionState),
            "telemetryEventRef": .string(r.telemetryEventRef),
            "routingRosterQuality": .string(r.routingRosterQuality.rawValue),
            "routingSnapshot": r.routingSnapshot.map { snapshot in
                .object([
                    "status": .string(snapshot.status.rawValue),
                    "source": .string(snapshot.source.rawValue),
                    "snapshot": .string(snapshot.snapshotID),
                    "count": .int(snapshot.count),
                    "reason": .string(snapshot.reason),
                ])
            } ?? .null,
            "routingIntegrity": .object([
                "registryVersion": .int(r.routingIntegrity.registryVersion),
                "boundToolCount": .int(r.routingIntegrity.boundToolCount),
                "manifestMarkerTools": .array(r.routingIntegrity.manifestMarkerTools.map { .string($0) }),
                "descriptionCharBudget": .int(r.routingIntegrity.descriptionCharBudget),
                "warnings": .array(r.routingIntegrity.warnings.map { .string($0) })
            ]),
            "preflightIntent": .string(r.preflightIntent.rawValue),
            "capabilityNotes": .array(r.capabilityNotes.map { .string($0) }),
            "operatorSummary": .string(r.operatorSummary),
            "capabilityState": .string(r.capabilityState.rawValue),
            "capabilityMatrix": .array(r.capabilityMatrix.map { entry in
                var e: [String: Value] = [
                    "capability": .string(entry.capability),
                    "available": .bool(entry.available),
                ]
                if let detail = entry.detail { e["detail"] = .string(detail) }
                return .object(e)
            }),
            "finalState": .string(r.finalState.rawValue),
        ]
        if let client = r.client { d["client"] = .string(client) }
        if let expected = r.expectedHash { d["expectedHash"] = .string(expected) }
        if let actual = r.actualHash { d["actualHash"] = .string(actual) }
        if let session = r.session { d["session"] = sessionValue(session) }
        if let constitution = r.constitution { d["constitution"] = constitutionValue(constitution) }
        return .object(d)
    }

    private static func sessionValue(_ session: BrokerSessionRecord) -> Value {
        var d: [String: Value] = [
            "sessionId": .string(session.sessionId),
            "transportSessionId": .string(session.transportSessionId),
            "mode": .string(session.mode.rawValue),
            "startedAt": .string(ISO8601DateFormatter().string(from: session.startedAt)),
            "governed": .bool(session.governed),
        ]
        if let client = session.client { d["client"] = .string(client) }
        if let closedAt = session.closedAt {
            d["closedAt"] = .string(ISO8601DateFormatter().string(from: closedAt))
        }
        return .object(d)
    }

    private static func constitutionValue(_ bundle: ConstitutionBundle) -> Value {
        .object([
            "tier0": .string(bundle.tier0),
            "doctrineCore": .string(bundle.doctrineCore),
            "doctrineFreshness": .string(bundle.doctrineFreshness.rawValue),
            "doctrineVersion": .string(bundle.doctrineVersion),
            "orders": .array(bundle.orders.map { order in
                .object([
                    "id": .string(order.id),
                    "title": .string(order.title),
                    "scope": .string(order.scope.rawValue),
                    "updatedAt": .string(ISO8601DateFormatter().string(from: order.updatedAt)),
                    "body": .string(order.body),
                ])
            }),
            "commandsIndex": .array(bundle.commandsIndex.map { command in
                var c: [String: Value] = [
                    "slug": .string(command.slug),
                    "name": .string(command.name),
                    "icon": .string(command.icon),
                ]
                if let keySlot = command.keySlot { c["keySlot"] = .int(keySlot) }
                return .object(c)
            }),
            "routingRoster": .string(bundle.routingRoster),
        ])
    }
}
