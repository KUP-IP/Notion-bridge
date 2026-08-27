// LaunchReadinessTests.swift — PKT-1305
// TheBridge · Tests
//
// Hermetic fixtures for the provider-neutral launch-readiness contract.
// No live credentials, no provider-account mutation, no new MCP surface.

import Foundation
import TheBridgeLib

func runLaunchReadinessTests() async {
    print("\n🛫 LaunchReadiness (PKT-1305 · provider-neutral preflight + safeToLaunch)")

    let checkedAt = Date(timeIntervalSince1970: 1_777_200_000)

    func packetProperty(_ field: PacketRegistryContract.Field) -> RegistryProperty {
        RegistryProperty(
            key: field.key,
            notionName: field.notionName,
            notionPropertyId: "id_\(field.key)",
            type: field.type
        )
    }

    func passingPacketConfig() -> RegistryConfig {
        let packet = RegistryEntity(
            key: "packet",
            displayName: "PACKETS",
            dataSourceId: "packets-ds",
            properties: PacketRegistryContract.fields
                .filter(\.registryBindingRequired)
                .map(packetProperty),
            cacheTTLSeconds: 300,
            hasBody: true
        )
        let project = RegistryEntity(key: "project", displayName: "Projects", dataSourceId: "projects-ds", properties: [], cacheTTLSeconds: 300)
        let skill = RegistryEntity(key: "skill", displayName: "Skills", dataSourceId: "skills-ds", properties: [], cacheTTLSeconds: 300)
        let telemetry = RegistryEntity(key: "telemetry", displayName: "Telemetry", dataSourceId: "telemetry-ds", properties: [], cacheTTLSeconds: 300)
        let schedule = RegistryEntity(key: "schedule", displayName: "Schedule", dataSourceId: "schedule-ds", properties: [], cacheTTLSeconds: 300)
        let client = RegistryEntity(key: "client", displayName: "Clients", dataSourceId: "clients-ds", properties: [], cacheTTLSeconds: 300)
        return RegistryConfig(entities: [packet, project, skill, telemetry, schedule, client])
    }

    func passingPacketSchema() -> DataSourceSchema {
        var columns: [String: DataSourceSchema.Column] = [:]
        for field in PacketRegistryContract.fields {
            let target: String?
            switch field.relationTargetEntity {
            case "packet": target = "packets-ds"
            case "project": target = "projects-ds"
            case "skill": target = "skills-ds"
            case "telemetry": target = "telemetry-ds"
            case "schedule": target = "schedule-ds"
            case "client": target = "clients-ds"
            default: target = nil
            }
            columns[field.notionName] = .init(
                id: "id_\(field.key)",
                type: field.type,
                options: field.expectedOptions.sorted(),
                relationDataSourceId: target
            )
        }
        return DataSourceSchema(columnsByName: columns)
    }

    func greenProbes(
        commandAuth: LaunchReadinessSeam = CommandAuthReadinessSeam(.authenticated(tool: "notion_page_read")),
        registry: LaunchReadinessSeam? = nil,
        runtime: LaunchReadinessSeam = RuntimeAvailabilitySeam(.available(runtime: "chrome")),
        storage: LaunchReadinessSeam = StorageWriteabilitySeam(.writable(path: "/tmp/bridge-worktree")),
        coverage: LaunchReadinessSeam = ImplementationCoverageSeam(.proven(locator: "sha:48d6f8fe"))
    ) -> [LaunchReadinessProbe] {
        LaunchReadinessContract.standardProbes(
            commandAuth: commandAuth,
            registryConsumer: registry ?? RegistryConsumerReadinessSeam(.snapshot(
                config: passingPacketConfig(), schema: passingPacketSchema())),
            runtimeBrowser: runtime,
            storageWrite: storage,
            implementationCoverage: coverage
        )
    }

    func check(_ report: LaunchReadinessReport, _ name: String) -> LaunchReadinessCheck? {
        report.checks.first { $0.name == name }
    }

    await test("LaunchReadiness: unauthenticated command/tool fixture returns BLOCKED with evidence") {
        let report = await LaunchReadinessContract.evaluate(
            probes: greenProbes(commandAuth: CommandAuthReadinessSeam(.unauthenticated(tool: "notion_page_update"))),
            now: checkedAt
        )
        let auth = check(report, LaunchReadinessContract.commandAuthCheck)
        try expect(auth?.verdict == .blocked, "expected BLOCKED, got \(auth?.verdict.rawValue ?? "nil")")
        try expect(auth?.evidence.contains("unauthenticated") == true, "evidence must name unauthenticated: \(auth?.evidence ?? "")")
        try expect(!report.safeToLaunch, "any required BLOCKED forbids launch")
        try expect(report.checkedAt == checkedAt)
    }

    await test("LaunchReadiness: missing browser/runtime fixture returns BLOCKED") {
        let report = await LaunchReadinessContract.evaluate(
            probes: greenProbes(runtime: RuntimeAvailabilitySeam(.missing(runtime: "chrome"))),
            now: checkedAt
        )
        let runtime = check(report, LaunchReadinessContract.runtimeBrowserCheck)
        try expect(runtime?.verdict == .blocked)
        try expect(runtime?.evidence.contains("missing") == true)
        try expect(!report.safeToLaunch)
    }

    await test("LaunchReadiness: unavailable storage/write path returns BLOCKED") {
        let report = await LaunchReadinessContract.evaluate(
            probes: greenProbes(storage: StorageWriteabilitySeam(
                .unavailable(path: "/tmp/bridge-worktree", reason: "permission denied"))),
            now: checkedAt
        )
        let storage = check(report, LaunchReadinessContract.storageWriteCheck)
        try expect(storage?.verdict == .blocked)
        try expect(storage?.evidence.contains("not writable") == true)
        try expect(!report.safeToLaunch)
    }

    await test("LaunchReadiness: missing implementation-coverage proof returns BLOCKED") {
        let report = await LaunchReadinessContract.evaluate(
            probes: greenProbes(coverage: ImplementationCoverageSeam(
                .missing(expected: "workflow:pkt-1305-tests"))),
            now: checkedAt
        )
        let coverage = check(report, LaunchReadinessContract.implementationCoverageCheck)
        try expect(coverage?.verdict == .blocked)
        try expect(coverage?.evidence.contains("coverage proof missing") == true)
        try expect(!report.safeToLaunch)
    }

    await test("LaunchReadiness: failed evidence transport returns TRANSPORT_UNKNOWN, never false BLOCKED") {
        let report = await LaunchReadinessContract.evaluate(
            probes: greenProbes(registry: RegistryConsumerReadinessSeam(
                .evidenceUnavailable(reason: "tunnel drop: failed to connect to MCP server"))),
            now: checkedAt
        )
        let registry = check(report, LaunchReadinessContract.registryConsumerCheck)
        try expect(registry?.verdict == .transportUnknown,
                   "transport failure must not collapse to BLOCKED, got \(registry?.verdict.rawValue ?? "nil")")
        try expect(registry?.verdict != .blocked, "false BLOCKED is a contract violation")
        try expect(registry?.evidence.contains("failed to connect") == true)
        try expect(!report.safeToLaunch, "TRANSPORT_UNKNOWN on a required check is not safeToLaunch")
    }

    await test("LaunchReadiness: command auth evidence-path failure is TRANSPORT_UNKNOWN not BLOCKED") {
        let report = await LaunchReadinessContract.evaluate(
            probes: greenProbes(commandAuth: CommandAuthReadinessSeam(
                .evidenceUnavailable(reason: "TCC probe timed out"))),
            now: checkedAt
        )
        try expect(check(report, LaunchReadinessContract.commandAuthCheck)?.verdict == .transportUnknown)
        try expect(!report.safeToLaunch)
    }

    await test("LaunchReadiness: all-green fixture returns PASS for every check and safeToLaunch=true") {
        let report = await LaunchReadinessContract.evaluate(probes: greenProbes(), now: checkedAt)
        try expect(report.checks.count == 5)
        for item in report.checks {
            try expect(item.verdict == .pass, "\(item.name) expected PASS, got \(item.verdict.rawValue)")
            try expect(item.required, "canonical checks are required")
            try expect(!item.evidence.isEmpty, "\(item.name) must carry evidence")
        }
        try expect(report.safeToLaunch, "all required PASS → safeToLaunch")
        try expect(report.checkedAt == checkedAt)
    }

    await test("LaunchReadiness: registry consumer DRIFT is product BLOCKED, not transport") {
        let emptyConfig = RegistryConfig(entities: [])
        let report = await LaunchReadinessContract.evaluate(
            probes: greenProbes(registry: RegistryConsumerReadinessSeam(
                .snapshot(config: emptyConfig, schema: passingPacketSchema()))),
            now: checkedAt
        )
        let registry = check(report, LaunchReadinessContract.registryConsumerCheck)
        try expect(registry?.verdict == .blocked, "known contract drift is BLOCKED")
        try expect(registry?.evidence.contains("DRIFT") == true)
        try expect(!report.safeToLaunch)
    }

    await test("LaunchReadiness: optional TRANSPORT_UNKNOWN does not veto safeToLaunch") {
        let probes: [LaunchReadinessProbe] = greenProbes() + [
            NamedLaunchReadinessProbe(
                name: "optional.telemetry",
                required: false,
                seam: FixedLaunchReadinessSeam(.transportUnknown(evidence: "audit log unreachable"))
            )
        ]
        let report = await LaunchReadinessContract.evaluate(probes: probes, now: checkedAt)
        try expect(report.safeToLaunch, "optional unknown transport must not veto launch")
        try expect(check(report, "optional.telemetry")?.verdict == .transportUnknown)
    }

    await test("LaunchReadiness live attach: runtime residual is TRANSPORT_UNKNOWN, axes distinguished") {
        var config = passingPacketConfig()
        var packet = config.entities[0]
        packet.properties.removeAll { $0.key == "objective" }
        config.entities[0] = packet
        let probes = LaunchReadinessLive.registryEntitiesProbes(
            config: config,
            schema: passingPacketSchema(),
            schemaError: nil,
            storagePath: NSTemporaryDirectory(),
            coverageLocator: "030d03887650dce5b2898cb9d8de231b43fecedd"
        )
        let report = await LaunchReadinessContract.evaluate(probes: probes, now: checkedAt)
        try expect(check(report, LaunchReadinessContract.commandAuthCheck)?.verdict == .pass)
        let registry = check(report, LaunchReadinessContract.registryConsumerCheck)
        try expect(registry?.verdict == .blocked)
        try expect(registry?.evidence.contains("binding=DRIFT") == true)
        try expect(registry?.evidence.contains("consumer=PASS") == true)
        try expect(check(report, LaunchReadinessContract.runtimeBrowserCheck)?.verdict == .transportUnknown)
        try expect(check(report, LaunchReadinessContract.storageWriteCheck)?.verdict == .pass)
        try expect(check(report, LaunchReadinessContract.implementationCoverageCheck)?.verdict == .pass)
        try expect(!report.safeToLaunch)
        try expect(report.value != .null)
    }
}
