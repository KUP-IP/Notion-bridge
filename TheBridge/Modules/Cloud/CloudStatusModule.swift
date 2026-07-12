// CloudStatusModule.swift — WS-D (PKT-921 · Bridge Cloud Access)
// TheBridge · Modules · Cloud
//
// Three small, independently-testable pieces that wire the WS-C
// `BridgeCloudManager` actor into the running MCP server:
//
//   1. CloudHeartbeat — a cancellable repeating timer that re-probes
//      transport health by calling `manager.refreshHealth()` on a ~30s
//      cadence while Bridge Cloud Access is enabled. There is NO
//      `heartbeatLoop()` on the manager (the packet body's API was stale);
//      WS-D BUILDS the loop here over the real `refreshHealth()` seam. The
//      tick interval is injectable so a unit test can drive start/stop
//      deterministically without sleeping 30s.
//
//   2. CloudStatusPayload — the canonical, state-derived `bridge_status`
//      JSON the MCP tool returns. The WS-B static Worker JSON (PKT-920)
//      MUST mirror this exact shape (the packet's coordination note).
//
//   3. CloudStatusModule — registers the cloud-gated `bridge_status` MCP
//      tool whose handler reads `await manager.state` and emits the payload.
//      Registered ONLY when Bridge Cloud Access is enabled (the caller gates
//      on `BridgeDefaults.cloudAccessEnabled`); never part of the static
//      feature-module count.
//
// All three bind to the REAL WS-C API: `state` (.disabled/.connecting/
// .online/.degraded/.offline — there is NO `.connected`) and
// `refreshHealth()`. `.online`/`.degraded` are treated as "up".

import Foundation
import MCP

// MARK: - 1. Heartbeat

/// A cancellable, repeating health-probe loop over `BridgeCloudManager`.
///
/// While running it awaits `interval`, calls `manager.refreshHealth()`, and
/// repeats until `stop()` (or deinit) cancels it. The manager itself no-ops
/// `refreshHealth()` when `.disabled`, so a stray late tick after a disable
/// is harmless — but `stop()` cancels the task promptly regardless.
///
/// An `actor` so `start`/`stop`/`isRunning` are race-free, and `onTick` (a
/// test seam) fires exactly once per completed probe.
public actor CloudHeartbeat {

    /// Default cadence — DoD: "Heartbeat fires every 30s when
    /// cloudAccessEnabled == true and app running".
    public static let defaultInterval: Duration = .seconds(30)

    private let manager: BridgeCloudManager
    private let interval: Duration
    /// Test seam: invoked after each completed `refreshHealth()` probe with
    /// the resulting state. Production passes nil.
    private let onTick: (@Sendable (CloudConnectionState) -> Void)?

    private var task: Task<Void, Never>?

    public init(
        manager: BridgeCloudManager,
        interval: Duration = CloudHeartbeat.defaultInterval,
        onTick: (@Sendable (CloudConnectionState) -> Void)? = nil
    ) {
        self.manager = manager
        self.interval = interval
        self.onTick = onTick
    }

    /// Whether the loop is currently scheduled.
    public var isRunning: Bool { task != nil }

    /// Start the loop. Idempotent: a second `start()` while already running
    /// is a no-op (no duplicate timer).
    public func start() {
        guard task == nil else { return }
        let manager = self.manager
        let interval = self.interval
        let onTick = self.onTick
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    break // cancelled mid-sleep
                }
                if Task.isCancelled { break }
                let state = await manager.refreshHealth()
                onTick?(state)
                _ = self // keep the actor alive while scheduled
            }
        }
    }

    /// Stop the loop. Idempotent: safe to call when not running. Cancels the
    /// in-flight task so no further probes fire.
    public func stop() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}

// MARK: - 2. bridge_status payload (canonical shape — WS-B must mirror)

/// Builds the canonical `bridge_status` payload from a `CloudConnectionState`.
///
/// SCHEMA (v2) — the WS-B static Worker JSON (PKT-920) MUST mirror this:
///   {
///     "tool":  "bridge_status",        // string, constant
///     "ok":    true,                   // bool, constant (the probe itself succeeded)
///     "state": "online",               // string raw value of CloudConnectionState
///                                       //   one of: disabled|connecting|online|degraded|offline
///     "up":    true,                   // bool — true iff state ∈ {online, degraded}
///     "macToolsAvailable": true,       // bool — actual local dispatch surface
///     "gitSHA": "0123abcd...",        // string — build-time commit
///     "gitDirty": false,               // bool — build-time tree state
///     "schemaVersion": 2               // int — payload contract version
///   }
public enum CloudStatusPayload {

    /// Current payload contract version. Bump on any shape change so WS-B can
    /// detect drift.
    public static let schemaVersion = 2

    /// Whether the channel is "up" for serving delegated work. `.online` and
    /// `.degraded` both count as up (degraded = channel impaired but present);
    /// `.disabled`/`.connecting`/`.offline` are down.
    public static func isUp(_ state: CloudConnectionState) -> Bool {
        state == .online || state == .degraded
    }

    /// Whether the live router has any dispatchable Mac tools beyond the
    /// always-visible cloud probe itself. This is intentionally independent of
    /// tunnel state: `up` answers channel health; `macToolsAvailable` answers
    /// local dispatch readiness.
    public static func macToolsAvailable(in registrations: [ToolRegistration]) -> Bool {
        registrations.contains { !ServerManager.cloudAlwaysVisibleTools.contains($0.name) }
    }

    /// The canonical `bridge_status` JSON value.
    public static func make(
        state: CloudConnectionState,
        macToolsAvailable: Bool,
        buildProvenance: BuildProvenance = .current
    ) -> Value {
        .object([
            "tool":               .string("bridge_status"),
            "ok":                 .bool(true),
            "state":              .string(state.rawValue),
            "up":                 .bool(isUp(state)),
            "macToolsAvailable":  .bool(macToolsAvailable),
            "gitSHA":             .string(buildProvenance.gitSHA),
            "gitDirty":           .bool(buildProvenance.gitDirty),
            "schemaVersion":      .int(schemaVersion)
        ])
    }
}

// MARK: - 3. bridge_status MCP tool

/// Registers the cloud-gated `bridge_status` MCP tool. NOT part of the static
/// feature-module surface (`BridgeConstants.staticFeatureModuleToolCount`) —
/// it exists only while Bridge Cloud Access is enabled, so the caller gates
/// registration on `BridgeDefaults.cloudAccessEnabled`.
public enum CloudStatusModule {

    public static let moduleName = "cloud"
    public static let toolName = "bridge_status"

    /// Register `bridge_status` against `router`, reading live state from
    /// `manager`. Handler is `.open` tier (pure read of local cloud state —
    /// no Keychain, no tunnel mutation, no network).
    public static func register(on router: ToolRouter, manager: BridgeCloudManager) async {
        await router.register(makeTool(
            manager: manager,
            macToolsAvailabilityProvider: {
                CloudStatusPayload.macToolsAvailable(in: await router.allRegistrations())
            }
        ))
    }

    /// Factory for the `bridge_status` registration (exposed for tests).
    public static func makeTool(
        manager: BridgeCloudManager,
        macToolsAvailabilityProvider: @escaping @Sendable () async -> Bool,
        buildProvenanceProvider: @escaping @Sendable () -> BuildProvenance = { .current }
    ) -> ToolRegistration {
        ToolRegistration(
            name: toolName,
            module: moduleName,
            tier: .open,
            description: "Report Bridge Cloud Access health for this Mac. Returns the "
                + "connection state (disabled|connecting|online|degraded|offline), whether the "
                + "channel is up (online/degraded), whether local Mac-tool dispatch is available, "
                + "and the packaged build git SHA/dirty stamp. "
                + "Pure read of local state — no side effects. Returns { tool, ok, state, up, "
                + "macToolsAvailable, gitSHA, gitDirty, schemaVersion }.",
            inputSchema: .object([
                "type":       .string("object"),
                "properties": .object([:]),
                "required":   .array([])
            ]),
            metadata: ToolMetadata(
                title: "Bridge Status",
                whenToUse: [
                    "Check whether this Mac is reachable from the cloud and how healthy the tunnel is."
                ],
                whenNotToUse: [
                    "Enabling/disabling cloud access (that is the Remote Access settings toggle, not a tool)."
                ],
                relatedTools: ["session_info", "system_info"]
            ),
            handler: { _ in
                let state = await manager.state
                let macToolsAvailable = await macToolsAvailabilityProvider()
                return CloudStatusPayload.make(
                    state: state,
                    macToolsAvailable: macToolsAvailable,
                    buildProvenance: buildProvenanceProvider()
                )
            }
        )
    }
}
