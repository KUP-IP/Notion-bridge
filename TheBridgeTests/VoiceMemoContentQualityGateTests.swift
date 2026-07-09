// VoiceMemoContentQualityGateTests.swift — GH #81 quality gate + GH #73 stage timeouts
// TheBridge · Tests
//
// GH #81: voice_memo_commit could mark a memory_keep record markedProcessed:true
// even when the resulting Notion Memory page body was a weak transcript-opening
// fragment or disfluency-dominated filler. GH #73: voice_memo_process could stall
// with no completion payload and no review-queue entry.
//
// Per this session's own PKT-MEM-136 lesson (AGENT_FEEDBACK 2026-07-02): a test
// suite that only drives a hand-built VoiceMemoIntent / calls executeMemoryKeep
// directly can hide a real args-parsing wiring bug. Every quality-gate and
// stage-timeout regression test below drives the REAL MCP entry point —
// VoiceMemoProcessor.commit(args:) or VoiceMemoProcessor.process(args:) — with a
// real on-disk recording fixture, exactly like VoiceMemoCommentTests' "wires a
// top-level body argument" test. Pure VoiceMemoContentQualityGate.evaluate unit
// tests are ALSO included (fast calibration evidence against the exact GH #81
// repro strings), but they supplement, not replace, the args:-driven tests.

import Foundation
import MCP
import TheBridgeLib

// MARK: - Hermetic recording fixture (mirrors VoiceMemoCommentTests' body-arg test)

private struct QualityGateFixture {
    let home: URL
    let recording: VoiceMemoRecording
}

private func makeFixture(name: String, transcript: String) throws -> QualityGateFixture {
    let fm = FileManager.default
    let fakeHome = fm.temporaryDirectory.appendingPathComponent("VoiceMemoQualityGate-\(UUID().uuidString)", isDirectory: true)
    let recordings = fakeHome.appendingPathComponent("Library/Application Support/com.apple.voicememos/Recordings", isDirectory: true)
    try fm.createDirectory(at: recordings, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(fakeHome)

    let audio = recordings.appendingPathComponent("\(name).m4a")
    try Data([0x00]).write(to: audio)
    let sidecar = recordings.appendingPathComponent("\(name).txt")
    try transcript.data(using: .utf8)?.write(to: sidecar)

    guard let recording = VoiceMemoDiscovery.listRecordings(roots: [recordings]).first else {
        throw TestError.assertion("fixture recording not discovered for \(name)")
    }
    return QualityGateFixture(home: fakeHome, recording: recording)
}

private func teardownFixture(_ fixture: QualityGateFixture) {
    BridgePaths.overrideHomeForTesting(nil)
    try? FileManager.default.removeItem(at: fixture.home)
}

// MARK: - Stub registry (memory entity WITH bound PLAYERS, mirrors VoiceMemoPlayerAttachTests)

private actor QualityGateStubState {
    var createCallCount = 0
    var createdFields: [String: Value] = [:]
    var appendCallCount = 0
    var readbackPlayerIds: [String] = ["dc8e8f3f-e607-4b5d-809e-ae289574f40c"]

    func recordCreate(fields: [String: Value]) { createCallCount += 1; createdFields = fields }
    func recordAppend() { appendCallCount += 1 }
}

private func memoryEntityWithPlayers() -> RegistryEntity {
    RegistryEntity(
        key: "memory",
        displayName: "Memory",
        dataSourceId: "8a39359f-2246-40a2-8614-a487ba9abd23",
        properties: [
            RegistryProperty(key: "title", notionName: "Memory", notionPropertyId: "title", type: "title", role: .title),
            RegistryProperty(key: "summary", notionName: "Relevant:", notionPropertyId: "sum1", type: "rich_text"),
            RegistryProperty(key: "players", notionName: "PLAYERS", notionPropertyId: "rel1", type: "relation", role: .relation),
        ],
        cacheTTLSeconds: 3600,
        hasBody: true
    )
}

private func installQualityGateStubs(on router: ToolRouter, state: QualityGateStubState, pageId: String) async {
    let create = ToolRegistration(
        name: "registry_create", module: "stub", tier: .open,
        description: "stub",
        inputSchema: .object(["type": .string("object")]),
        handler: { args in
            guard case .object(let a) = args, case .object(let fields)? = a["fields"] else {
                return .object(["created": .bool(false)])
            }
            await state.recordCreate(fields: fields)
            return .object([
                "created": .bool(true),
                "row": .object(["id": .string(pageId)]),
            ])
        })
    let get = ToolRegistration(
        name: "registry_get", module: "stub", tier: .open,
        description: "stub",
        inputSchema: .object(["type": .string("object")]),
        handler: { _ in
            let ids = await state.readbackPlayerIds
            return .object([
                "entity": .string("memory"),
                "id": .string(pageId),
                "properties": .object(["players": .array(ids.map { .string($0) })]),
            ])
        })
    let append = ToolRegistration(
        name: "notion_blocks_append", module: "stub", tier: .open,
        description: "stub",
        inputSchema: .object(["type": .string("object")]),
        handler: { _ in await state.recordAppend(); return .object(["ok": .bool(true)]) })

    await router.register(create)
    await router.register(get)
    await router.register(append)
}

private func seedMemoryEntity() async throws {
    _ = try await RegistryConfigStore.shared.upsertEntity(memoryEntityWithPlayers())
}

// MARK: - GH #81's exact 3 repro filler strings

private let gh81FillerSamples: [(memo: String, filler: String)] = [
    ("20260116 184800-4C53C2CF.m4a-3041483-1768612397", "I'm having fun with this idea"),
    ("20260107 185731-D876F185.m4a-20300883-1768421352", "At these at these days, okay"),
    ("20260107 193746-9413247E.m4a-11632602-1768421350", "We, uh, terrible the sea"),
]

func runVoiceMemoContentQualityGateTests() async {
    print("\n\u{1F6E1}\u{FE0F} GH #81/#73 — content quality gate + stage timeouts")

    // MARK: Pure VoiceMemoContentQualityGate.evaluate — calibration evidence

    await test("GH #81: all 3 real repro filler summaries fail the gate") {
        for (memoId, filler) in gh81FillerSamples {
            let verdict = VoiceMemoContentQualityGate.evaluate(filler)
            guard case .rejected = verdict else {
                try expect(false, "memo \(memoId) filler '\(filler)' should be rejected, got \(verdict)")
                continue
            }
        }
    }

    await test("Quality gate: empty summary is rejected") {
        guard case .rejected(let reason) = VoiceMemoContentQualityGate.evaluate("") else {
            try expect(false, "empty string must be rejected")
            return
        }
        try expect(reason.contains("empty"), "reason should mention empty, got: \(reason)")
    }

    await test("Quality gate: whitespace-only summary is rejected") {
        guard case .rejected = VoiceMemoContentQualityGate.evaluate("   \n\t  ") else {
            try expect(false, "whitespace-only must be rejected")
            return
        }
    }

    await test("Quality gate: a genuine short-but-real 8-word memo PASSES (no false positive)") {
        let verdict = VoiceMemoContentQualityGate.evaluate("Call Sarah about the Q3 budget by Friday")
        try expect(verdict == .ok, "a real 8-word instruction must not be rejected, got \(verdict)")
    }

    await test("Quality gate: a real multi-sentence summary with one 'uh' still passes (not disfluency-dominated)") {
        let verdict = VoiceMemoContentQualityGate.evaluate(
            "Construction on Student Central is, uh, scheduled to begin next month and will affect the ministry schedule and sermon framework."
        )
        try expect(verdict == .ok, "one incidental 'uh' in a long real sentence must not trip the ceiling, got \(verdict)")
    }

    await test("Quality gate: 7 words (just under the floor) is rejected; 8 words (at the floor) passes") {
        guard case .rejected = VoiceMemoContentQualityGate.evaluate("one two three four five six seven") else {
            try expect(false, "7 words must be rejected")
            return
        }
        let ok = VoiceMemoContentQualityGate.evaluate("one two three four five six seven eight")
        try expect(ok == .ok, "8 words must pass, got \(ok)")
    }

    await test("Quality gate: disfluency-dominated long text is rejected even above the word floor") {
        // 10 words, 5 are disfluency tokens (um/uh/okay/like) = 50% >= 40% ceiling.
        let verdict = VoiceMemoContentQualityGate.evaluate("um uh okay like um the meeting notes are here today")
        guard case .rejected(let reason) = verdict else {
            try expect(false, "50% filler-word text must be rejected even at 10 words, got \(verdict)")
            return
        }
        try expect(reason.contains("filler") || reason.contains("disfluency"), "reason should mention filler, got: \(reason)")
    }

    // MARK: commit(args:) — the real MCP entry point (PKT-MEM-136 lesson)

    await test("GH #81: commit(args:) memory_keep with a filler-only plan summary is BLOCKED — never markedProcessed") {
        defer { VoiceMemoParseRouter.providerOverride = nil }
        VoiceMemoParseRouter.providerOverride = { _ in [HeuristicParseProvider()] }

        // A transcript engineered so the heuristic parser's firstSentence-derived
        // plan.summary is exactly the GH #81 style filler fragment, AND the memo
        // routes to memory_keep (heuristic "agents should know" / explicit memory
        // trigger keeps this deterministic without relying on Ollama).
        let transcript = "I'm having fun with this idea. Let's save a memory about it."
        // makeFixture switches BridgePaths to a fresh hermetic home — seed the
        // registry entity AFTER that switch so RegistryConfigStore.shared (which
        // resolves its path dynamically per call) writes into the SAME hermetic
        // home commit(args:) will read from, not whatever home was active before.
        let fixture = try makeFixture(name: "filler-fixture", transcript: transcript)
        defer { teardownFixture(fixture) }
        try await seedMemoryEntity()

        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let state = QualityGateStubState()
        await installQualityGateStubs(on: router, state: state, pageId: "page-filler")

        let result = try await VoiceMemoProcessor.commit(args: .object([
            "memoId": .string(fixture.recording.id),
            "intentKind": .string(VoiceMemoIntentKind.memoryKeep.rawValue),
            "entityKey": .string("memory"),
            // Force the exact GH #81 filler string as the candidate summary via the
            // real fields.summary passthrough (pre-existing path) so this test is
            // deterministic regardless of what the heuristic parser's firstSentence
            // extraction happens to produce for this transcript.
            "fields": .object(["summary": .string("I'm having fun with this idea")]),
        ]), router: router)

        guard case .object(let envelope) = result, case .bool(let ok)? = envelope["ok"] else {
            try expect(false, "expected an object envelope with ok")
            return
        }
        try expect(!ok, "a filler-only summary must not report ok:true")
        if case .bool(let marked)? = envelope["markedProcessed"] {
            try expect(!marked, "a filler-only summary must NEVER set markedProcessed:true")
        } else {
            try expect(false, "envelope missing markedProcessed")
        }
        let creates = await state.createCallCount
        try expect(creates == 0, "no Notion registry_create should happen for a gate-rejected summary")

        let pending = VoiceMemoReviewStore.pendingEntries().filter { $0.memoId == fixture.recording.id }
        try expect(!pending.isEmpty, "a gate-rejected commit must land in the review queue (GH #81 requirement)")
        try expect(pending.contains { ($0.reason).lowercased().contains("filler") || $0.reason.lowercased().contains("word") },
                   "the review entry's reason should state the gate's rejection reason")
    }

    await test("GH #81: commit(args:) memory_keep with a substantive summary succeeds and marks processed") {
        defer { VoiceMemoParseRouter.providerOverride = nil }
        VoiceMemoParseRouter.providerOverride = { _ in [HeuristicParseProvider()] }

        let transcript = "Let's save a memory about the roadmap discussion."
        let fixture = try makeFixture(name: "good-fixture", transcript: transcript)
        defer { teardownFixture(fixture) }
        try await seedMemoryEntity()

        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let state = QualityGateStubState()
        await installQualityGateStubs(on: router, state: state, pageId: "page-good")

        let result = try await VoiceMemoProcessor.commit(args: .object([
            "memoId": .string(fixture.recording.id),
            "intentKind": .string(VoiceMemoIntentKind.memoryKeep.rawValue),
            "entityKey": .string("memory"),
            "fields": .object(["summary": .string("We reviewed the Q3 roadmap and agreed to ship the registry vertical slice before the sale-ready milestone.")]),
        ]), router: router)

        guard case .object(let envelope) = result, case .bool(let ok)? = envelope["ok"] else {
            try expect(false, "expected an object envelope with ok")
            return
        }
        try expect(ok, "a substantive summary must succeed")
        if case .bool(let marked)? = envelope["markedProcessed"] {
            try expect(marked, "a substantive summary must be marked processed")
        } else {
            try expect(false, "envelope missing markedProcessed")
        }
        let creates = await state.createCallCount
        try expect(creates == 1, "exactly one registry_create for a passing summary")
    }

    // MARK: First-class `summary` schema parameter (Success Criterion 3)

    await test("Schema: voice_memo_commit documents a top-level 'summary' parameter") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await VoiceMemoModule.register(on: router)
        let tools = await router.registrations(forModule: "voice")
        guard let commitTool = tools.first(where: { $0.name == "voice_memo_commit" }) else {
            try expect(false, "voice_memo_commit not registered")
            return
        }
        guard case .object(let schema) = commitTool.inputSchema,
              case .object(let props)? = schema["properties"],
              case .object(let summaryProp)? = props["summary"] else {
            try expect(false, "voice_memo_commit schema must document a top-level 'summary' property")
            return
        }
        guard case .string(let desc)? = summaryProp["description"], !desc.isEmpty else {
            try expect(false, "'summary' schema property must have a non-empty description")
            return
        }
    }

    await test("GH #81 item 2: top-level 'summary' arg reaches the write, overriding the heuristic plan.summary") {
        defer { VoiceMemoParseRouter.providerOverride = nil }
        VoiceMemoParseRouter.providerOverride = { _ in [HeuristicParseProvider()] }

        let transcript = "Let's save a memory about this."
        let fixture = try makeFixture(name: "summary-override-fixture", transcript: transcript)
        defer { teardownFixture(fixture) }
        try await seedMemoryEntity()

        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let state = QualityGateStubState()
        await installQualityGateStubs(on: router, state: state, pageId: "page-override")

        let override = "The team decided to ship the registry vertical slice ahead of the sale-ready milestone review."
        let result = try await VoiceMemoProcessor.commit(args: .object([
            "memoId": .string(fixture.recording.id),
            "intentKind": .string(VoiceMemoIntentKind.memoryKeep.rawValue),
            "entityKey": .string("memory"),
            "summary": .string(override),
        ]), router: router)

        guard case .object(let envelope) = result, case .bool(true)? = envelope["ok"] else {
            try expect(false, "commit with a real top-level summary override should succeed")
            return
        }
        let fields = await state.createdFields
        try expect(fields["summary"] == .string(override),
                   "top-level 'summary' must reach registry_create's fields.summary verbatim, got \(String(describing: fields["summary"]))")
    }

    // MARK: process(args:) batch path (Success Criterion 1 — batch, not just commit)

    await test("GH #81: process(args:) single-mode routes a filler memory_keep summary to review, not processed") {
        defer { VoiceMemoParseRouter.providerOverride = nil }
        VoiceMemoParseRouter.providerOverride = { _ in [FillerPlanStubProvider()] }

        let fixture = try makeFixture(name: "batch-filler-fixture", transcript: "irrelevant, the stub provider supplies the plan")
        defer { teardownFixture(fixture) }
        try await seedMemoryEntity()

        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let state = QualityGateStubState()
        await installQualityGateStubs(on: router, state: state, pageId: "page-batch-filler")

        _ = try await VoiceMemoProcessor.process(args: .object([
            "mode": .string("single"),
            "memoId": .string(fixture.recording.id),
            "dryRun": .bool(false),
        ]), router: router)

        try expect(!VoiceMemoProcessedStore.isProcessed(id: fixture.recording.id),
                   "a filler-summary memory_keep lane must not be marked processed by the batch path")
        let creates = await state.createCallCount
        try expect(creates == 0, "no Notion write should happen for a gate-rejected batch memory_keep lane")
        let pending = VoiceMemoReviewStore.pendingEntries().filter { $0.memoId == fixture.recording.id }
        try expect(!pending.isEmpty, "the batch path must also enqueue a review entry for a gate-rejected summary")
    }

    // MARK: Stage timeouts (GH #73) — pure VoiceMemoStageTimeout unit tests

    await test("GH #73: VoiceMemoStageTimeout.run returns the fast operation's result") {
        let result = try await VoiceMemoStageTimeout.run(stage: "unit-fast", seconds: 2) {
            "fast-result"
        }
        try expect(result == "fast-result", "fast operation should win the race")
    }

    await test("GH #73: VoiceMemoStageTimeout.run throws timedOut when the operation exceeds the budget") {
        var threw = false
        do {
            _ = try await VoiceMemoStageTimeout.run(stage: "unit-slow", seconds: 0.05) {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return "should never get here"
            }
        } catch let error as VoiceMemoStageTimeoutError {
            threw = true
            if case .timedOut(let stage, _) = error {
                try expect(stage == "unit-slow", "timeout error should carry the stage name")
            }
        }
        try expect(threw, "an operation that exceeds its budget must throw VoiceMemoStageTimeoutError")
    }

    await test("GH #73: a rejecting/throwing operation still propagates its own error (not swallowed by the timer)") {
        struct StubError: Error {}
        var threw = false
        do {
            _ = try await VoiceMemoStageTimeout.run(stage: "unit-throw", seconds: 5) {
                throw StubError()
            }
        } catch is StubError {
            threw = true
        }
        try expect(threw, "the operation's own thrown error must propagate, not get lost behind the timer")
    }

    // MARK: Stage timeouts — real process(args:)/commit(args:) entry points never hang (GH #73 Success Criterion 2)

    await test("GH #73: process(args:) single-mode terminates (review-queued, never processed, never hangs) when Understand exceeds its stage budget") {
        defer {
            VoiceMemoParseRouter.providerOverride = nil
            VoiceMemoStageTimeout.testBudgetScale = nil
        }
        // A provider chain whose only rung sleeps 3s. Scale every stage budget down
        // to ~0.3% of production (VoiceMemoStageTimeout.testBudgetScale) so the 200s
        // understandSeconds budget becomes ~0.6s — well under the provider's 3s sleep
        // — forcing the SAME timeout path a real production stall would take,
        // without waiting out real minutes in CI. The named constants themselves
        // (the documented, reviewable rule) are untouched; only the race's effective
        // duration is scaled for this test.
        VoiceMemoStageTimeout.testBudgetScale = 0.003
        VoiceMemoParseRouter.providerOverride = { _ in [HangingParseProvider()] }

        let fixture = try makeFixture(name: "stall-fixture", transcript: "some transcript text for the stalled memo")
        defer { teardownFixture(fixture) }

        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let state = QualityGateStubState()
        await installQualityGateStubs(on: router, state: state, pageId: "page-stall")

        let start = ContinuousClock.now
        let result = try await VoiceMemoProcessor.process(args: .object([
            "mode": .string("single"),
            "memoId": .string(fixture.recording.id),
            "dryRun": .bool(false),
        ]), router: router)
        let elapsed = ContinuousClock.now - start

        guard case .object(let envelope) = result, case .int? = envelope["processedCount"] else {
            try expect(false, "process(args:) must return a structured envelope, never hang with no payload")
            return
        }
        try expect(elapsed < .seconds(10), "the call must terminate promptly once the scaled-down understand budget elapses — got \(elapsed)")
        try expect(!VoiceMemoProcessedStore.isProcessed(id: fixture.recording.id),
                   "a memo whose Understand stage timed out and degraded to the heuristic floor must not be silently marked processed without review")
    }

    await test("GH #73: VoiceMemoStageTimeout.testBudgetScale actually forces the timeout branch (not just a fast-enough real sleep)") {
        defer { VoiceMemoStageTimeout.testBudgetScale = nil }
        VoiceMemoStageTimeout.testBudgetScale = 0.01 // 200s → 2s
        var threw = false
        do {
            _ = try await VoiceMemoStageTimeout.run(stage: "scaled", seconds: VoiceMemoStageTimeout.understandSeconds) {
                try await Task.sleep(nanoseconds: 4_000_000_000) // 4s > scaled 2s budget
                return "unreachable"
            }
        } catch is VoiceMemoStageTimeoutError {
            threw = true
        }
        try expect(threw, "scaling the production understandSeconds budget down must make a 4s operation time out")
    }

    await test("GH #73 parity (2026-07-09): voice_memo_get understand:true degrades gracefully on a transcribe-stage timeout instead of throwing") {
        defer {
            VoiceMemoDiscovery.resolveTranscriptOverride = nil
            VoiceMemoStageTimeout.testBudgetScale = nil
        }
        // Force the transcribe stage itself to hang, via the dedicated test seam —
        // deterministic and fast, unlike trying to stall the real sidecar/Apple/
        // Parakeet ladder (which has no other injection point).
        VoiceMemoStageTimeout.testBudgetScale = 0.01 // transcribeSeconds -> ~2s
        VoiceMemoDiscovery.resolveTranscriptOverride = { _ in
            try await Task.sleep(nanoseconds: 4_000_000_000) // 4s > scaled ~2s budget
            return VoiceMemoTranscriptResolution(text: "unreachable", source: .sidecar)
        }

        let fixture = try makeFixture(name: "get-stall-fixture", transcript: "irrelevant — override wins")
        defer { teardownFixture(fixture) }

        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let start = ContinuousClock.now
        let result = try await VoiceMemoProcessor.get(args: .object([
            "memoId": .string(fixture.recording.id),
            "understand": .bool(true),
        ]), router: router)
        let elapsed = ContinuousClock.now - start

        try expect(elapsed < .seconds(10), "get(args:) must terminate promptly once the scaled-down transcribe budget elapses — got \(elapsed), it previously would have propagated the raw timeout error but NOT necessarily hung; this asserts it also returns a real payload fast")
        guard case .object(let envelope) = result else {
            try expect(false, "voice_memo_get must return a structured envelope on a transcribe-stage timeout, not throw")
            return
        }
        try expect(envelope["understood"] == .bool(false), "a timed-out understand attempt must report understood:false, got \(envelope["understood"] as Any)")
        try expect(envelope["needsManual"] == .bool(true), "must signal needsManual:true, matching processOne/commit's degradation shape")
        try expect(envelope["timedOut"] == .bool(true), "must signal timedOut:true")
        try expect(envelope["memo"] != nil, "must still return the memo identity even on a degraded outcome")
    }
}

// MARK: - Test-only stub providers

/// Always available; returns a plan whose lone memory_keep intent's fields.summary
/// is the exact GH #81 "I'm having fun with this idea" filler string — used to
/// drive the BATCH (process(args:)) path deterministically without depending on
/// the heuristic parser's phrase-matching for a specific transcript.
private struct FillerPlanStubProvider: VoiceMemoParseProvider {
    var provenance: ParseProvenance { .heuristic }
    func isAvailable() -> Bool { true }
    func parse(transcript: String, fallbackTitle: String, recordingPath: String) async -> VoiceMemoPlan? {
        VoiceMemoPlan(
            generatedTitle: fallbackTitle,
            skipMemoryKeep: false,
            summary: "I'm having fun with this idea",
            actions: [],
            intents: [
                VoiceMemoIntent(
                    kind: .memoryKeep,
                    confidence: 0.95,
                    entityKey: "memory",
                    title: fallbackTitle,
                    fields: ["summary": "I'm having fun with this idea"]
                ),
            ],
            provenance: .heuristic,
            degraded: false
        )
    }
}

/// Simulates the GH #73 stall symptom: a provider that is available but never
/// resolves quickly. Used only with a deliberately short window to prove the
/// orchestration races it rather than awaiting it unbounded.
private struct HangingParseProvider: VoiceMemoParseProvider {
    var provenance: ParseProvenance { .local }
    func isAvailable() -> Bool { true }
    func parse(transcript: String, fallbackTitle: String, recordingPath: String) async -> VoiceMemoPlan? {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        return VoiceMemoPlan(
            generatedTitle: fallbackTitle, skipMemoryKeep: true, summary: "", actions: [], intents: [],
            provenance: .local, degraded: false
        )
    }
}
