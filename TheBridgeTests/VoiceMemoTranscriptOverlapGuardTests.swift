// VoiceMemoTranscriptOverlapGuardTests.swift — PKT-MEM-132 transcript-overlap write guard
// TheBridge · Tests
//
// D49 length + contiguous-substring hybrid check: pure-logic core (length
// floor / run threshold / normalization / boundary exactness) plus wiring
// into executeMemoryKeep and executeRegistryUpdate — both Notion-bound write
// paths named in the packet's Scope IN. Verbatim transcript paste (agent
// `fields` override) must throw `transcriptOverlapRejected` BEFORE any
// registry_create/registry_update dispatch (graceful BLOCKED → REVIEW, no
// crash, no silent write) — the same pattern PKT-1064's
// `playerRelationUnbound` established. Hermetic: stub ToolRouter, no live
// Notion.

import Foundation
import MCP
import TheBridgeLib

// MARK: - Fixtures (lengths/overlaps verified offline; see inline comments)

/// 479 chars — long enough to clear both the length floor (80) and the
/// contiguous-run threshold (200) on its own.
private let overlapTranscript = """
Okay so I want to talk through the plan for the Bridge v4 launch. We need to \
make sure the registry tools are fully tested before we ship the data source \
binding work to production. The main risk right now is that the Notion \
property ids could drift if someone renames a column in the workspace \
without going through the introspect flow first. I also want to loop in the \
reviewer on the payment integration before Friday so we are not blocked on \
Stripe webhooks over the weekend.
"""

/// A raw substring of `overlapTranscript`, 220 chars, embedded inside
/// otherwise-original wrapper text (269 chars total) — models an agent that
/// wraps a transcript chunk in a sentence or two rather than pasting the
/// whole thing. Longest shared contiguous run with `overlapTranscript` = 220
/// (>= 200 threshold) ⇒ must reject.
private let embeddedVerbatimRun: String = {
    let chars = Array(overlapTranscript)
    let snippet = String(chars[20..<240])
    return "Notes from the call: \(snippet) — will follow up next week."
}()

/// Same shape as `embeddedVerbatimRun` but the embedded run is 199 chars —
/// one character UNDER `contiguousRunThreshold` (200). Sharpest possible
/// boundary case: must NOT reject.
private let underThresholdEmbeddedRun: String = {
    let chars = Array(overlapTranscript)
    let snippet = String(chars[20..<219])
    return "Notes: \(snippet) end."
}()

/// 64 chars (under the 80 length floor) that legitimately reuses a few real
/// transcript terms ("Bridge v4 launch", "registry testing"). Must pass —
/// never even reaches the contiguous-run check.
private let shortReuseSummary = "Discussed Bridge v4 launch plan and registry testing priorities."

/// 331 chars — clears the length floor comfortably — but is genuinely
/// original prose (paraphrased, reordered, different words throughout).
/// Longest shared contiguous run with `overlapTranscript` is a handful of
/// characters, well under the 200 threshold. Must pass.
private let longOriginalSummary = """
Summary: the operator wants registry coverage locked down before the v4 \
data-source binding ships, flagged property-id drift as the main risk when \
columns get renamed outside introspect, and asked to pull the reviewer into \
the payment workstream ahead of the Friday cutoff so the Stripe webhook \
work does not slip into the weekend.
"""

// MARK: - Pure-logic tests

func runVoiceMemoTranscriptOverlapGuardTests() async {
    print("\n\u{1F6A7} PKT-MEM-132 — transcript-overlap write guard (D49)")

    // MARK: Named constants (locked values, not magic numbers elsewhere)

    await test("overlap_constants_lockedValues") {
        try expect(VoiceMemoTranscriptOverlapGuard.minimumLengthFloor == 80, "length floor is 80")
        try expect(VoiceMemoTranscriptOverlapGuard.contiguousRunThreshold == 200, "run threshold is 200")
    }

    // MARK: Length floor — short text never checked, regardless of overlap

    await test("overlap_belowLengthFloor_alwaysPasses_evenWithRealOverlap") {
        let verdict = VoiceMemoTranscriptOverlapGuard.evaluate(text: shortReuseSummary, transcript: overlapTranscript)
        try expect(verdict == .ok, "short summary reusing a few real terms passes (below length floor)")
    }

    await test("overlap_emptyOrTinyText_passes") {
        try expect(VoiceMemoTranscriptOverlapGuard.evaluate(text: "", transcript: overlapTranscript) == .ok, "empty text passes")
        try expect(VoiceMemoTranscriptOverlapGuard.evaluate(text: "Inbox", transcript: overlapTranscript) == .ok, "tiny status value passes")
    }

    // MARK: Verbatim paste — the packet's primary DoD case

    await test("overlap_verbatimTranscriptPaste_rejected") {
        let verdict = VoiceMemoTranscriptOverlapGuard.evaluate(text: overlapTranscript, transcript: overlapTranscript)
        guard case .rejected(let runLength) = verdict else {
            try expect(false, "full verbatim transcript paste must be rejected, got \(verdict)")
            return
        }
        try expect(runLength >= VoiceMemoTranscriptOverlapGuard.contiguousRunThreshold, "reported run length clears the threshold, got \(runLength)")
    }

    await test("overlap_embeddedVerbatimRun_220chars_rejected") {
        let verdict = VoiceMemoTranscriptOverlapGuard.evaluate(text: embeddedVerbatimRun, transcript: overlapTranscript)
        guard case .rejected(let runLength) = verdict else {
            try expect(false, "a 220-char verbatim run embedded in otherwise-original text must be rejected, got \(verdict)")
            return
        }
        try expect(runLength == 220, "reports the exact embedded run length, got \(runLength)")
    }

    // MARK: Boundary exactness — one character under threshold must pass

    await test("overlap_run199chars_oneUnderThreshold_passes") {
        let verdict = VoiceMemoTranscriptOverlapGuard.evaluate(text: underThresholdEmbeddedRun, transcript: overlapTranscript)
        try expect(verdict == .ok, "a 199-char run (one under the 200 threshold) must pass, got \(verdict)")
    }

    // MARK: Long-but-genuinely-original — the packet's third DoD case

    await test("overlap_longOriginalSummary_passes") {
        let verdict = VoiceMemoTranscriptOverlapGuard.evaluate(text: longOriginalSummary, transcript: overlapTranscript)
        try expect(verdict == .ok, "a long, genuinely original (paraphrased) summary passes, got \(verdict)")
    }

    // MARK: Normalization — re-casing/re-wrapping the same paste still trips it

    await test("overlap_reCasedAndReWrapped_stillRejected") {
        let recased = overlapTranscript.uppercased()
        let verdict = VoiceMemoTranscriptOverlapGuard.evaluate(text: recased, transcript: overlapTranscript)
        guard case .rejected = verdict else {
            try expect(false, "re-casing the same verbatim paste must not evade the check, got \(verdict)")
            return
        }
    }

    await test("overlap_reWrappedWhitespace_stillRejected") {
        let rewrapped = overlapTranscript.replacingOccurrences(of: " ", with: "\n")
        let verdict = VoiceMemoTranscriptOverlapGuard.evaluate(text: rewrapped, transcript: overlapTranscript)
        guard case .rejected = verdict else {
            try expect(false, "re-wrapping whitespace in the same verbatim paste must not evade the check, got \(verdict)")
            return
        }
    }

    // MARK: firstRejectedField — whole-field-map convenience

    await test("overlap_firstRejectedField_scansEveryKey_notJustSummary") {
        let fields = ["title": "Preferred stack", "notes": overlapTranscript, "status": "Inbox"]
        let rejected = VoiceMemoTranscriptOverlapGuard.firstRejectedField(in: fields, transcript: overlapTranscript)
        try expect(rejected?.key == "notes", "flags the offending field regardless of its key name, got \(String(describing: rejected))")
    }

    await test("overlap_firstRejectedField_allFieldsClean_returnsNil") {
        let fields = ["title": "Preferred stack", "summary": longOriginalSummary, "status": "Inbox"]
        let rejected = VoiceMemoTranscriptOverlapGuard.firstRejectedField(in: fields, transcript: overlapTranscript)
        try expect(rejected == nil, "no field over threshold ⇒ nil, got \(String(describing: rejected))")
    }

    await test("overlap_firstRejectedField_emptyMap_returnsNil") {
        try expect(VoiceMemoTranscriptOverlapGuard.firstRejectedField(in: [:], transcript: overlapTranscript) == nil, "empty field map never rejects")
    }

    // MARK: - Wiring: executeMemoryKeep

    await test("overlap_executeMemoryKeep_verbatimFieldsOverride_throwsBeforeAnyWrite") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let state = OverlapStubState()
        await installOverlapStubs(on: router, state: state, pageId: "page-overlap-1")

        var threw = false
        do {
            _ = try await VoiceMemoProcessor.executeMemoryKeep(
                entityKey: "memory",
                intent: VoiceMemoIntent(
                    kind: .memoryKeep, confidence: 0.95, entityKey: "memory", title: "Call notes",
                    fields: ["title": "Call notes", "summary": overlapTranscript]
                ),
                plan: overlapPlan(),
                transcript: overlapTranscript,
                router: router,
                entity: overlapMemoryEntity()
            )
        } catch let error as VoiceMemoError {
            threw = true
            if case .transcriptOverlapRejected(let entity, let field, let runLength) = error {
                try expect(entity == "memory", "error carries the entity key")
                try expect(field == "summary", "error identifies the offending field, got \(field)")
                try expect(runLength >= VoiceMemoTranscriptOverlapGuard.contiguousRunThreshold, "error carries a run length clearing the threshold")
            } else {
                try expect(false, "expected transcriptOverlapRejected, got \(error)")
            }
        }
        try expect(threw, "an agent-supplied fields override pasting the raw transcript must throw, not write")
        let creates = await state.createCallCount
        try expect(creates == 0, "no registry_create dispatched — the guard runs before any Notion write")
    }

    await test("overlap_executeMemoryKeep_shortReusePasses_writesNormally") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let state = OverlapStubState()
        await installOverlapStubs(on: router, state: state, pageId: "page-overlap-2")

        let detail = try await VoiceMemoProcessor.executeMemoryKeep(
            entityKey: "memory",
            intent: VoiceMemoIntent(
                kind: .memoryKeep, confidence: 0.95, entityKey: "memory", title: "Call notes",
                fields: ["title": "Call notes", "summary": shortReuseSummary]
            ),
            plan: overlapPlan(),
            transcript: overlapTranscript,
            router: router,
            entity: overlapMemoryEntity()
        )
        try expect(detail.contains("registry_create"), "short reuse summary is written normally, got \(detail)")
        let creates = await state.createCallCount
        try expect(creates == 1, "exactly one registry_create dispatched")
    }

    await test("overlap_executeMemoryKeep_longOriginalPasses_writesNormally") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let state = OverlapStubState()
        await installOverlapStubs(on: router, state: state, pageId: "page-overlap-3")

        let detail = try await VoiceMemoProcessor.executeMemoryKeep(
            entityKey: "memory",
            intent: VoiceMemoIntent(
                kind: .memoryKeep, confidence: 0.95, entityKey: "memory", title: "Call notes",
                fields: ["title": "Call notes", "summary": longOriginalSummary]
            ),
            plan: overlapPlan(),
            transcript: overlapTranscript,
            router: router,
            entity: overlapMemoryEntity()
        )
        try expect(detail.contains("registry_create"), "a long, genuinely original summary is written normally, got \(detail)")
        let creates = await state.createCallCount
        try expect(creates == 1, "exactly one registry_create dispatched")
    }

    await test("overlap_executeMemoryKeep_heuristicPath_neverContainsTranscript_unaffected") {
        // The automated (non-fields-override) path derives fields from plan.summary,
        // which never contains the raw transcript — must be completely unaffected by
        // the guard's addition.
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let state = OverlapStubState()
        await installOverlapStubs(on: router, state: state, pageId: "page-overlap-4")

        let detail = try await VoiceMemoProcessor.executeMemoryKeep(
            entityKey: "memory",
            intent: VoiceMemoIntent(kind: .memoryKeep, confidence: 0.95, entityKey: "memory", title: "Preferred stack"),
            plan: overlapPlan(),
            transcript: overlapTranscript,
            router: router,
            entity: overlapMemoryEntity()
        )
        try expect(detail.contains("registry_create"), "heuristic-derived fields path is unaffected by the guard, got \(detail)")
    }

    // MARK: - Wiring: executeRegistryUpdate

    await test("overlap_executeRegistryUpdate_verbatimFieldsOverride_throwsBeforeAnyWrite") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let state = OverlapStubState()
        await installOverlapStubs(on: router, state: state, pageId: "page-overlap-5")
        await state.setListRows([.object(["id": .string("row-1"), "title": .string("Bridge v4")])])

        let intent = VoiceMemoIntent(
            kind: .registryUpdate, confidence: 1.0, entityKey: "project", entityHint: "Bridge v4",
            fields: ["notes": overlapTranscript]
        )
        var threw = false
        do {
            _ = try await VoiceMemoProcessor.executeRegistryUpdate(intent, transcript: overlapTranscript, router: router)
        } catch let error as VoiceMemoError {
            threw = true
            if case .transcriptOverlapRejected(let entity, let field, _) = error {
                try expect(entity == "project", "error carries the entity key")
                try expect(field == "notes", "error identifies the offending field, got \(field)")
            } else {
                try expect(false, "expected transcriptOverlapRejected, got \(error)")
            }
        }
        try expect(threw, "an agent-supplied fields override pasting the raw transcript must throw, not write")
        let updates = await state.updateCallCount
        try expect(updates == 0, "no registry_update dispatched — the guard runs before any Notion write")
    }

    await test("overlap_executeRegistryUpdate_explicitRowIdPath_alsoGuarded") {
        // The explicitRowId path (used by voice_memo_review_resolve's rowId param)
        // must be guarded exactly like the hint-resolved path — it is the SAME
        // registry_update write vector.
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let state = OverlapStubState()
        await installOverlapStubs(on: router, state: state, pageId: "page-overlap-6")

        let intent = VoiceMemoIntent(
            kind: .registryUpdate, confidence: 1.0, entityKey: "project",
            fields: ["notes": overlapTranscript]
        )
        var threw = false
        do {
            _ = try await VoiceMemoProcessor.executeRegistryUpdate(
                intent, explicitRowId: "row-explicit", transcript: overlapTranscript, router: router
            )
        } catch let error as VoiceMemoError {
            threw = true
            if case .transcriptOverlapRejected = error {} else {
                try expect(false, "expected transcriptOverlapRejected, got \(error)")
            }
        }
        try expect(threw, "explicit-rowId registry_update path is guarded too")
        let updates = await state.updateCallCount
        try expect(updates == 0, "no registry_update dispatched on the explicit-rowId path either")
    }

    await test("overlap_executeRegistryUpdate_shortReusePasses_writesNormally") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let state = OverlapStubState()
        await installOverlapStubs(on: router, state: state, pageId: "page-overlap-7")

        let intent = VoiceMemoIntent(
            kind: .registryUpdate, confidence: 1.0, entityKey: "project",
            fields: ["status": "shipping"]
        )
        let detail = try await VoiceMemoProcessor.executeRegistryUpdate(
            intent, explicitRowId: "row-7", transcript: overlapTranscript, router: router
        )
        try expect(detail.contains("registry_update"), "short, non-overlapping field write proceeds normally, got \(detail)")
        let updates = await state.updateCallCount
        try expect(updates == 1, "exactly one registry_update dispatched")
    }

    await test("overlap_executeRegistryUpdate_checksMergedAppendField_stillCatchesEmbeddedTranscript") {
        // "notes" is not one of the append-only protected fields, so this exercises
        // the merged-field-map path without append-wrapping noise; the raw proposed
        // value (a verbatim transcript run embedded in otherwise-original text)
        // must still trip the guard after merge.
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let state = OverlapStubState()
        await installOverlapStubs(on: router, state: state, pageId: "page-overlap-8")

        let intent = VoiceMemoIntent(
            kind: .registryUpdate, confidence: 1.0, entityKey: "project",
            fields: ["notes": embeddedVerbatimRun]
        )
        var threw = false
        do {
            _ = try await VoiceMemoProcessor.executeRegistryUpdate(
                intent, explicitRowId: "row-8", transcript: overlapTranscript, router: router
            )
        } catch let error as VoiceMemoError {
            threw = true
            if case .transcriptOverlapRejected = error {} else {
                try expect(false, "expected transcriptOverlapRejected, got \(error)")
            }
        }
        try expect(threw, "an embedded (not full-paste) verbatim run in a proposed field is still caught")
        let updates = await state.updateCallCount
        try expect(updates == 0, "no write on the embedded-verbatim-run case")
    }
}

// MARK: - Shared stub router (registry_create / registry_get / registry_update / registry_list / notion_blocks_append)

private actor OverlapStubState {
    var createCallCount = 0
    var updateCallCount = 0
    var listRows: [Value] = []

    func recordCreate() { createCallCount += 1 }
    func recordUpdate() { updateCallCount += 1 }
    func setListRows(_ rows: [Value]) { listRows = rows }
}

private func installOverlapStubs(on router: ToolRouter, state: OverlapStubState, pageId: String) async {
    let create = ToolRegistration(
        name: "registry_create", module: "stub", tier: .open,
        description: "stub", inputSchema: .object(["type": .string("object")]),
        handler: { args in
            await state.recordCreate()
            guard case .object(let a) = args, case .string(let entity)? = a["entity"] else {
                return .object(["created": .bool(false)])
            }
            return .object([
                "created": .bool(true),
                "row": .object([
                    "entity": .string(entity), "id": .string(pageId),
                    "title": .string("Memo"), "url": .string(""), "properties": .object([:]),
                ]),
            ])
        })
    let get = ToolRegistration(
        name: "registry_get", module: "stub", tier: .open,
        description: "stub", inputSchema: .object(["type": .string("object")]),
        handler: { _ in
            // Mirrors the default originating Player id (PKT-1064) so the post-write
            // verify read-back in executeMemoryKeep passes on the "writes normally" tests.
            .object([
                "entity": .string("memory"), "id": .string(pageId),
                "properties": .object(["title": .string("Memo"), "players": .array([.string("dc8e8f3f-e607-4b5d-809e-ae289574f40c")])]),
            ])
        })
    let update = ToolRegistration(
        name: "registry_update", module: "stub", tier: .open,
        description: "stub", inputSchema: .object(["type": .string("object")]),
        handler: { args in
            await state.recordUpdate()
            guard case .object(let a) = args, case .string(let entity)? = a["entity"], case .string(let id)? = a["id"] else {
                return .object(["updated": .bool(false)])
            }
            return .object(["updated": .bool(true), "entity": .string(entity), "id": .string(id)])
        })
    let list = ToolRegistration(
        name: "registry_list", module: "stub", tier: .open,
        description: "stub", inputSchema: .object(["type": .string("object")]),
        handler: { _ in .object(["rows": .array(await state.listRows)]) })
    // PKT-MEM-131 (merged after this branch was cut) swapped resolveRegistryRowId's
    // registry_list + client-side matching for a direct registry_find dispatch — this
    // stub keeps that resolution path working for every test in this file that goes
    // through executeRegistryUpdate's hint-based resolution, mirroring `list`'s same
    // backing rows.
    let find = ToolRegistration(
        name: "registry_find", module: "stub", tier: .open,
        description: "stub", inputSchema: .object(["type": .string("object")]),
        handler: { _ in .object(["rows": .array(await state.listRows)]) })
    let append = ToolRegistration(
        name: "notion_blocks_append", module: "stub", tier: .open,
        description: "stub", inputSchema: .object(["type": .string("object")]),
        handler: { _ in .object(["ok": .bool(true)]) })

    await router.register(create)
    await router.register(get)
    await router.register(update)
    await router.register(list)
    await router.register(find)
    await router.register(append)
}

private func overlapPlan() -> VoiceMemoPlan {
    // Real (if terse) sentence, not a filler fragment — clears
    // VoiceMemoContentQualityGate's minimum-information floor (GH #81) so this
    // fixture continues to exercise ONLY the transcript-overlap guard, the
    // concern this file actually tests.
    VoiceMemoPlan(generatedTitle: "Call notes", skipMemoryKeep: false, summary: "Call notes summary covering the Bridge v4 launch plan.", actions: [], intents: [])
}

private func overlapMemoryEntity() -> RegistryEntity {
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
