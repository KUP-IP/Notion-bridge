// MemoryHubLiveProcessingTests.swift — PKT-MEM-134 UI↔agent live processing sync
// TheBridge · Tests
//
// voice_memo_get (understand:true, considering) / voice_memo_commit (committed)
// must durably log a MemoryHubActivityEvent with the new eventType AND post
// .memoryHubLiveProcessingDidChange on a channel SEPARATE from
// .voiceMemoReviewDidChange, so an already-open Process tab can live-render both
// without a manual reload. Hermetic: VoiceMemoParseRouter.providerOverride forces
// the pure, always-available HeuristicParseProvider — no network/Ollama/cloud —
// and every downstream MCP tool the commit lane touches is a stub registered on
// the router (the VoiceMemoPlayerAttachTests pattern).

import Foundation
import MCP
import TheBridgeLib

/// Mirrors PKT879OnboardingTests' NotificationListener — captures whether (and how
/// many times) `.memoryHubLiveProcessingDidChange` was delivered.
@MainActor
private final class LiveProcessingListener {
    var fireCount: Int = 0
    nonisolated init() {}
    nonisolated func fire() {
        Task { @MainActor in self.fireCount += 1 }
    }
}

/// Writes one fixture voice memo (audio stub + transcript sidecar) under a fresh
/// fake HOME and returns its discovered recording. `understand: false` never
/// classifies this transcript — `.get(understand:true)`/`.commit` route it through
/// the heuristic reminder lane ("remind me…"), never memory_keep, so the fixture
/// never touches VoiceMemoSummarizer / any LLM path.
private func makeFixtureRecording(name: String) throws -> VoiceMemoRecording {
    let fakeHome = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bridge-live-\(UUID().uuidString)", isDirectory: true)
    let recordings = fakeHome
        .appendingPathComponent("Library/Application Support/com.apple.voicememos/Recordings", isDirectory: true)
    try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(fakeHome)

    let audio = recordings.appendingPathComponent("\(name).m4a")
    try Data([0x00]).write(to: audio)
    let sidecar = recordings.appendingPathComponent("\(name).txt")
    try "Remind me to check the live processing sync tomorrow.".data(using: .utf8)?.write(to: sidecar)

    let list = VoiceMemoDiscovery.listRecordings(roots: [recordings])
    guard let recording = list.first else {
        throw TestError.assertion("fixture recording not discovered")
    }
    return recording
}

/// Registers a stub `memory_remember` (the agent_memory commit lane's sole
/// dispatch) so `.commit(intentKind: "agent_memory")` succeeds with zero live I/O.
private func installAgentMemoryStub(on router: ToolRouter) async {
    let stub = ToolRegistration(
        name: "memory_remember", module: "stub", tier: .open,
        description: "stub",
        inputSchema: .object(["type": .string("object")]),
        handler: { _ in .object(["ok": .bool(true)]) }
    )
    await router.register(stub)
}

func runMemoryHubLiveProcessingTests() async {
    print("\n🔴 Memory Hub live agent processing sync (PKT-MEM-134)")

    // MARK: — Event taxonomy

    await test("liveSync_eventType_newCasesPresent") {
        let raw = Set(MemoryHubActivityEventType.allCases.map(\.rawValue))
        try expect(raw.contains("memoConsidering"), "memoConsidering present")
        try expect(raw.contains("memoCommitted"), "memoCommitted present")
    }

    await test("liveSync_eventType_distinctFromEachOtherAndUnknown") {
        try expect(MemoryHubActivityEventType.memoConsidering != .memoCommitted, "considering != committed")
        try expect(MemoryHubActivityEventType.memoConsidering != .unknown, "considering != unknown")
        try expect(MemoryHubActivityEventType.memoCommitted != .unknown, "committed != unknown")
    }

    await test("liveSync_notificationName_isDedicated_separateFromReviewChannel") {
        // .voiceMemoReviewDidChange (the pre-existing review-queue mutation channel,
        // MemorySection.swift) is internal — not visible across the TheBridgeLib →
        // TheBridgeTests module boundary — so compare against its known literal wire
        // name rather than referencing the internal symbol directly.
        try expect(
            Notification.Name.memoryHubLiveProcessingDidChange.rawValue != "com.notionbridge.voiceMemoReviewDidChange",
            "live-processing channel must be a distinct Notification.Name from the review-queue channel"
        )
        try expect(
            Notification.Name.memoryHubLiveProcessingDidChange.rawValue == "com.notionbridge.memoryHubLiveProcessingDidChange",
            "live-processing channel wire name"
        )
    }

    // MARK: — voice_memo_get (considering)

    await test("liveSync_voiceMemoGet_understandTrue_postsConsideringAndLogsEvent") {
        defer { VoiceMemoParseRouter.providerOverride = nil }
        VoiceMemoParseRouter.providerOverride = { _ in [HeuristicParseProvider()] }
        defer { BridgePaths.overrideHomeForTesting(nil) }
        let recording = try makeFixtureRecording(name: "considering")

        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let listener = LiveProcessingListener()
        let token = NotificationCenter.default.addObserver(
            forName: .memoryHubLiveProcessingDidChange, object: nil, queue: .main
        ) { _ in listener.fire() }
        defer { NotificationCenter.default.removeObserver(token) }

        let beforeCount = MemoryHubActivityLog.load().filter {
            $0.memoId == recording.id && $0.eventType == .memoConsidering
        }.count

        _ = try await VoiceMemoProcessor.get(args: .object([
            "memoId": .string(recording.id),
            "understand": .bool(true),
        ]), router: router)

        // Drain the main run loop briefly — the post is dispatched via `Task { @MainActor in }`,
        // a fire-and-forget hop off the calling context (mirrors PKT879OnboardingTests).
        await MainActor.run {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }

        let fired = await MainActor.run { listener.fireCount }
        try expect(fired >= 1, "expected .memoryHubLiveProcessingDidChange to have been delivered at least once, got \(fired)")

        let events = MemoryHubActivityLog.load().filter {
            $0.memoId == recording.id && $0.eventType == .memoConsidering
        }
        try expect(events.count == beforeCount + 1, "expected exactly one new memoConsidering receipt, got \(events.count - beforeCount)")
        try expect(events.last?.action == "voice_memo_get", "considering receipt action")
        try expect(events.last?.actor == "agent", "considering receipt actor")
    }

    await test("liveSync_voiceMemoGet_understandFalse_doesNotPostOrLogConsidering") {
        defer { BridgePaths.overrideHomeForTesting(nil) }
        let recording = try makeFixtureRecording(name: "inspect-only")

        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let listener = LiveProcessingListener()
        let token = NotificationCenter.default.addObserver(
            forName: .memoryHubLiveProcessingDidChange, object: nil, queue: .main
        ) { _ in listener.fire() }
        defer { NotificationCenter.default.removeObserver(token) }

        _ = try await VoiceMemoProcessor.get(args: .object([
            "memoId": .string(recording.id),
            "understand": .bool(false),
        ]), router: router)

        await MainActor.run {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        let fired = await MainActor.run { listener.fireCount }
        try expect(fired == 0, "an inspect-only (understand:false) get must NOT post the live-processing channel, got \(fired) posts")

        let events = MemoryHubActivityLog.load().filter { $0.memoId == recording.id && $0.eventType == .memoConsidering }
        try expect(events.isEmpty, "an inspect-only get must not log a memoConsidering receipt")
    }

    // MARK: — voice_memo_commit (committed)

    await test("liveSync_voiceMemoCommit_success_postsCommittedAndLogsEvent") {
        defer { VoiceMemoParseRouter.providerOverride = nil }
        VoiceMemoParseRouter.providerOverride = { _ in [HeuristicParseProvider()] }
        defer { BridgePaths.overrideHomeForTesting(nil) }
        let recording = try makeFixtureRecording(name: "committed")

        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await installAgentMemoryStub(on: router)
        let listener = LiveProcessingListener()
        let token = NotificationCenter.default.addObserver(
            forName: .memoryHubLiveProcessingDidChange, object: nil, queue: .main
        ) { _ in listener.fire() }
        defer { NotificationCenter.default.removeObserver(token) }

        let beforeCount = MemoryHubActivityLog.load().filter {
            $0.memoId == recording.id && $0.eventType == .memoCommitted
        }.count

        let result = try await VoiceMemoProcessor.commit(args: .object([
            "memoId": .string(recording.id),
            "intentKind": .string(VoiceMemoIntentKind.agentMemory.rawValue),
        ]), router: router)

        guard case .object(let env) = result, case .bool(let ok)? = env["ok"] else {
            try expect(false, "expected an object envelope with ok")
            return
        }
        try expect(ok == true, "commit should have succeeded against the stubbed memory_remember")

        await MainActor.run {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }

        let fired = await MainActor.run { listener.fireCount }
        try expect(fired >= 1, "expected .memoryHubLiveProcessingDidChange to have been delivered at least once, got \(fired)")

        let events = MemoryHubActivityLog.load().filter {
            $0.memoId == recording.id && $0.eventType == .memoCommitted
        }
        try expect(events.count == beforeCount + 1, "expected exactly one new memoCommitted receipt, got \(events.count - beforeCount)")
        try expect(events.last?.action == "voice_memo_commit:agent_memory", "committed receipt action")
        try expect(events.last?.actor == "agent", "committed receipt actor")
        try expect(events.last?.status == "executed", "committed receipt status")
    }

    await test("liveSync_voiceMemoCommit_ambiguousRegistryTarget_doesNotPostOrLogCommitted") {
        defer { VoiceMemoParseRouter.providerOverride = nil }
        VoiceMemoParseRouter.providerOverride = { _ in [HeuristicParseProvider()] }
        defer { BridgePaths.overrideHomeForTesting(nil) }
        let recording = try makeFixtureRecording(name: "ambiguous")

        // registry_list returns two rows whose titles both contain the hint, forcing
        // the documented registryAmbiguous → needsManual short-circuit (no write, no
        // processed-gate) — the "committed" event must NOT fire on this path.
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let ambiguousRows: Value = .object(["rows": .array([
            .object(["id": .string("row-1"), "title": .string("Ambiguous Match One")]),
            .object(["id": .string("row-2"), "title": .string("Ambiguous Match Two")]),
        ])])
        let list = ToolRegistration(
            name: "registry_list", module: "stub", tier: .open, description: "stub",
            inputSchema: .object(["type": .string("object")]),
            handler: { _ in ambiguousRows }
        )
        await router.register(list)
        // PKT-MEM-131 (merged after this branch was cut) swapped resolveRegistryRowId's
        // registry_list dispatch for registry_find — this stub unconditionally returns the
        // same 2-row set (mirroring `list`) so the ambiguous-match short-circuit this test
        // exercises is reachable via that path too.
        let find = ToolRegistration(
            name: "registry_find", module: "stub", tier: .open, description: "stub",
            inputSchema: .object(["type": .string("object")]),
            handler: { _ in ambiguousRows }
        )
        await router.register(find)
        let listener = LiveProcessingListener()
        let token = NotificationCenter.default.addObserver(
            forName: .memoryHubLiveProcessingDidChange, object: nil, queue: .main
        ) { _ in listener.fire() }
        defer { NotificationCenter.default.removeObserver(token) }

        let result = try await VoiceMemoProcessor.commit(args: .object([
            "memoId": .string(recording.id),
            "intentKind": .string(VoiceMemoIntentKind.registryUpdate.rawValue),
            "entityKey": .string("memory"),
            "entityHint": .string("Ambiguous"),
        ]), router: router)

        guard case .object(let env) = result, case .bool(let needsManual)? = env["needsManual"] else {
            try expect(false, "expected an object envelope with needsManual")
            return
        }
        try expect(needsManual == true, "an ambiguous registry target must short-circuit to needsManual")

        await MainActor.run {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let fired = await MainActor.run { listener.fireCount }
        try expect(fired == 0, "an ambiguous (non-committing) commit attempt must NOT post the live-processing channel, got \(fired) posts")

        let events = MemoryHubActivityLog.load().filter { $0.memoId == recording.id && $0.eventType == .memoCommitted }
        try expect(events.isEmpty, "an ambiguous (non-committing) commit attempt must not log a memoCommitted receipt")
    }
}
