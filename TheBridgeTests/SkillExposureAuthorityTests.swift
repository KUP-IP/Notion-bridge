// SkillExposureAuthorityTests.swift — Runtime enrollment/exposure contract

import Foundation
import MCP
import TheBridgeLib

private let exposureNow = Date(timeIntervalSince1970: 1_785_196_800) // 2026-07-28T00:00:00Z; fixed
private let exposureUUIDA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
private let exposureUUIDB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

private func exposureSchema() -> [String: String] {
    SkillExposureCompiler.requiredSchema
}

private func exposureRow(
    id: String = exposureUUIDA,
    name: String = "Alpha",
    slug: String = "alpha",
    status: String? = "Testing",
    maturity: String? = "Stable",
    date: Date? = nil,
    desired: SkillRuntimeExposure? = .standard
) -> SkillRegistryExposureRow {
    .init(notionPageUUID: id, displayName: name, slug: slug,
          status: status, maturity: maturity, deprecationDate: date,
          desiredExposure: desired, url: "https://www.notion.so/\(id)",
          notionLastEditedTime: "2026-07-28T00:00:00.000Z")
}

private func exposureSnapshot(
    rows: [SkillRegistryExposureRow] = [exposureRow()],
    schema: [String: String] = exposureSchema(),
    complete: Bool = true
) -> SkillRegistryExposureSnapshot {
    .init(snapshotID: "snapshot-1", capturedAt: exposureNow,
          schemaColumns: schema, paginationComplete: complete, rows: rows)
}

private func baseline(_ exposure: SkillRuntimeExposure = .standard,
                      id: String = exposureUUIDA,
                      name: String = "Alpha") -> SkillExposureBaselineEntry {
    .init(notionPageUUID: id, displayName: name, exposure: exposure)
}

private func approval(previous: SkillRuntimeExposure?, requested: SkillRuntimeExposure,
                      id: String = exposureUUIDA) -> SkillExposureApproval {
    .init(id: "approval-1", kind: .routeReceipt, notionPageUUID: id,
          previousExposure: previous, requestedExposure: requested,
          routeID: "R4", authorizedAt: exposureNow)
}

private func compile(
    snapshot: SkillRegistryExposureSnapshot,
    previous: SkillRuntimeGeneration? = nil,
    baseline entries: [SkillExposureBaselineEntry] = [],
    approvals: [SkillExposureApproval] = [],
    denylist: Set<String> = [],
    publish: Bool = false
) -> SkillExposureCompilationResult {
    SkillExposureCompiler.compile(snapshot: snapshot, previousGeneration: previous,
        baseline: entries, approvals: approvals, emergencyDenylist: denylist,
        requireReviewedPublishedRows: publish, now: exposureNow)
}

private func publishedGeneration(
    exposure: SkillRuntimeExposure = .routing,
    compiledAt: Date = exposureNow,
    id: String = exposureUUIDA
) -> SkillRuntimeGeneration {
    .init(generationID: "generation-1", snapshotID: "snapshot-1",
          compilerVersion: "1.0.0", compiledAt: compiledAt,
          entries: [.init(notionPageUUID: id, displayName: "Alpha", slug: "alpha",
                          desiredExposure: exposure, publishedExposure: exposure,
                          lifecycleOverrideReason: nil, approvalID: "approval-1",
                          notionLastEditedTime: "2026-07-28T00:00:00.000Z",
                          url: "https://www.notion.so/\(id)")])
}

private func statusProperty(_ key: String, _ value: String) -> [String: Any] {
    [key: ["type": key == "Status" ? "status" : "select",
           key == "Status" ? "status" : "select": ["name": value]]]
}

private func dateProperty(_ value: String) -> [String: Any] {
    ["Deprecation Date": ["type": "date", "date": ["start": value]]]
}

func runSkillExposureAuthorityTests() async {
    print("\n🔐 Skill Runtime Exposure Authority")

    await test("exposure compiler blocks incomplete pagination") {
        let result = compile(snapshot: exposureSnapshot(complete: false))
        try expect(result.candidate == nil, "incomplete snapshot must not compile")
        try expect(result.errors == ["snapshot_incomplete_pagination"], "wrong error: \(result.errors)")
    }

    await test("exposure compiler blocks missing Runtime Exposure schema") {
        var schema = exposureSchema()
        schema.removeValue(forKey: "Runtime Exposure")
        let result = compile(snapshot: exposureSnapshot(schema: schema))
        try expect(result.candidate == nil, "missing required column must block")
        try expect(result.errors.contains("schema_missing:Runtime Exposure"), "missing schema reason absent")
    }

    await test("Unreviewed preserves baseline in shadow mode") {
        let result = compile(snapshot: exposureSnapshot(rows: [exposureRow(desired: nil)]),
                             baseline: [baseline(.routing)])
        let entry = result.candidate?.entry(pageID: exposureUUIDA)
        try expect(entry?.publishedExposure == .routing, "shadow must preserve known-good exposure")
        try expect(result.warnings.contains(where: { $0.hasPrefix("unreviewed_preserved:") }), "warning absent")
    }

    await test("Unreviewed blocks publication for a published row") {
        let result = compile(snapshot: exposureSnapshot(rows: [exposureRow(desired: nil)]),
                             baseline: [baseline(.routing)], publish: true)
        try expect(result.candidate == nil, "publication must block until the row is reviewed")
        try expect(result.errors.contains(where: { $0.hasPrefix("published_row_unreviewed:") }), "review error absent")
    }

    await test("future deprecation date does not retire early") {
        let future = exposureNow.addingTimeInterval(86_400)
        let result = compile(snapshot: exposureSnapshot(rows: [exposureRow(date: future, desired: .routing)]),
                             baseline: [baseline(.routing)])
        try expect(result.candidate?.entry(pageID: exposureUUIDA)?.publishedExposure == .routing,
                   "future deprecation must remain active")
    }

    await test("effective deprecation date forces Off without approval") {
        let past = exposureNow.addingTimeInterval(-86_400)
        let result = compile(snapshot: exposureSnapshot(rows: [exposureRow(date: past, desired: .routing)]),
                             baseline: [baseline(.routing)])
        try expect(result.candidate?.entry(pageID: exposureUUIDA) == nil, "retired row must be absent")
        try expect(result.changes.contains(where: { $0.contains("deprecation_date_effective") }), "retirement reason absent")
    }

    await test("Revoked and Desolved force Off") {
        let revoked = exposureRow(id: exposureUUIDA, status: "Revoked", desired: .routing)
        let desolved = exposureRow(id: exposureUUIDB, name: "Beta", slug: "beta",
                                   maturity: "Desolved", desired: .standard)
        let result = compile(snapshot: exposureSnapshot(rows: [revoked, desolved]),
                             baseline: [baseline(.routing), baseline(.standard, id: exposureUUIDB, name: "Beta")])
        try expect(result.candidate?.entries.isEmpty == true, "both retired rows must be excluded")
        try expect(result.changes.count == 2, "expected two removal changes")
    }

    await test("new Standard exposure requires route authorization") {
        let result = compile(snapshot: exposureSnapshot())
        try expect(result.candidate == nil, "unapproved enrollment must block")
        try expect(result.errors.contains(where: { $0.hasPrefix("approval_required:") }), "approval error absent")
    }

    await test("approved expansion publishes requested exposure") {
        let result = compile(snapshot: exposureSnapshot(), approvals: [approval(previous: nil, requested: .standard)])
        try expect(result.candidate?.entry(pageID: exposureUUIDA)?.publishedExposure == .standard,
                   "approved Standard exposure not compiled")
    }

    await test("Routing to Command is an authorization-gated surface switch") {
        let row = exposureRow(desired: .command)
        let blocked = compile(snapshot: exposureSnapshot(rows: [row]), baseline: [baseline(.routing)])
        try expect(blocked.candidate == nil, "surface switch must block without approval")
        let allowed = compile(snapshot: exposureSnapshot(rows: [row]), baseline: [baseline(.routing)],
                              approvals: [approval(previous: .routing, requested: .command)])
        try expect(allowed.candidate?.entry(pageID: exposureUUIDA)?.publishedExposure == .command,
                   "approved surface switch failed")
    }

    await test("orphaned baseline identity blocks cutover") {
        let result = compile(snapshot: exposureSnapshot(rows: []), baseline: [baseline()])
        try expect(result.candidate == nil, "orphan must block")
        try expect(result.errors.contains(where: { $0.hasPrefix("orphan_local_skill:") }), "orphan reason absent")
    }

    await test("degraded generation keeps exact fetch but suppresses ambient surfaces") {
        let stale = publishedGeneration(compiledAt: exposureNow.addingTimeInterval(-25 * 3600))
        let gate = SkillRuntimeExposureGate(generation: stale)
        try expect(gate.allows(pageID: exposureUUIDA, surface: .exactFetch, now: exposureNow), "exact fetch should survive")
        try expect(gate.allows(pageID: exposureUUIDA, surface: .bodyCache, now: exposureNow), "body cache should survive")
        try expect(!gate.allows(pageID: exposureUUIDA, surface: .routing, now: exposureNow), "routing must be suppressed")
        try expect(!gate.allows(pageID: exposureUUIDA, surface: .command, now: exposureNow), "command must be suppressed")
        try expect(!gate.allows(pageID: exposureUUIDA, surface: .specialist, now: exposureNow), "specialist must be suppressed")
    }

    await test("emergency denylist reduces every runtime surface") {
        let gate = SkillRuntimeExposureGate(generation: publishedGeneration(), emergencyDenylist: [exposureUUIDA])
        try expect(!gate.allows(pageID: exposureUUIDA, surface: .exactFetch, now: exposureNow), "denylist must block exact fetch")
        try expect(!gate.allows(pageID: exposureUUIDA, surface: .routing, now: exposureNow), "denylist must block routing")
    }

    await test("generation store stages, promotes, and reads back atomically") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-exposure-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillRuntimeGenerationStore(baseDirectory: root)
        // Reconciliation timestamps normally carry fractional seconds. The
        // persisted generation must preserve that precision or exact staged
        // read-back verification rejects an otherwise valid publication.
        let generation = publishedGeneration(
            compiledAt: Date(timeIntervalSince1970: exposureNow.timeIntervalSince1970 + 0.875123456)
        )
        _ = try await store.stage(generation)
        try expect(await store.activeGeneration() == nil, "staging must not activate")
        _ = try await store.promote(generationID: generation.generationID)
        try expect(await store.activeGeneration() == generation, "promoted generation failed read-back")
    }

    await test("routing snapshot is healthy only with a fresh non-empty Runtime Exposure projection") {
        let row: Value = .object(["name": .string("Alpha"), "source": .string("notion")])
        let freshGate = SkillRuntimeExposureGate(generation: publishedGeneration())
        let healthy = runtimeRoutingSnapshotForTesting(items: [row], gate: freshGate, now: exposureNow)
        try expect(healthy.metadata.status == .healthy)
        try expect(healthy.metadata.source == .runtimeExposureGeneration)
        try expect(healthy.metadata.snapshotID == "generation-1")
        try expect(healthy.metadata.count == 1)
        try expect(healthy.skills.count == 1)

        let empty = runtimeRoutingSnapshotForTesting(items: [], gate: freshGate, now: exposureNow)
        try expect(empty.metadata.status == .empty, "zero routing entries must never be healthy")
        try expect(empty.metadata.count == 0)
    }

    await test("stale Runtime Exposure suppresses routing and reports degraded evidence") {
        let row: Value = .object(["name": .string("Alpha")])
        let stale = SkillRuntimeExposureGate(
            generation: publishedGeneration(compiledAt: exposureNow.addingTimeInterval(-25 * 3600))
        )
        let snapshot = runtimeRoutingSnapshotForTesting(items: [row], gate: stale, now: exposureNow)
        try expect(snapshot.metadata.status == .degraded)
        try expect(snapshot.metadata.count == 0, "suppressed routing must report the effective zero count")
        try expect(snapshot.skills.isEmpty, "degraded ambient routing must fail closed")
        try expect(snapshot.metadata.reason == "runtime_exposure_freshness_expired")
    }

    await test("unchanged complete shadow renews freshness without publishing a generation") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-exposure-renewal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillRuntimeGenerationStore(baseDirectory: root)
        let staleGeneration = publishedGeneration(compiledAt: exposureNow.addingTimeInterval(-48 * 3600))
        _ = try await store.stage(staleGeneration)
        _ = try await store.promote(generationID: staleGeneration.generationID)
        let receipt = SkillExposureReconciliationReceipt(
            mode: .shadow,
            outcome: .shadowReady,
            attemptedAt: exposureNow,
            snapshotID: staleGeneration.snapshotID,
            candidateGenerationID: "unpublished-candidate",
            activeGenerationID: staleGeneration.generationID,
            errors: [],
            warnings: [],
            changes: []
        )
        try await store.writeReceipt(receipt)
        guard case .active(let gate) = await store.routingAuthority() else {
            throw TestError.assertion("expected active routing authority")
        }
        try expect(!gate.isDegraded(now: exposureNow), "unchanged shadow must renew freshness")
        try expect(gate.freshnessRenewedAt == exposureNow)
        try expect(await store.activeGenerationID() == staleGeneration.generationID,
                   "shadow renewal must not activate its candidate")
    }

    await test("changed shadow does not renew freshness and still requires publish") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-exposure-changed-shadow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillRuntimeGenerationStore(baseDirectory: root)
        let staleGeneration = publishedGeneration(compiledAt: exposureNow.addingTimeInterval(-48 * 3600))
        _ = try await store.stage(staleGeneration)
        _ = try await store.promote(generationID: staleGeneration.generationID)
        try await store.writeReceipt(.init(
            mode: .shadow, outcome: .shadowReady, attemptedAt: exposureNow,
            snapshotID: staleGeneration.snapshotID,
            candidateGenerationID: "changed-unpublished-candidate",
            activeGenerationID: staleGeneration.generationID,
            errors: [], warnings: [], changes: ["exposure:Alpha:Routing->Standard"]
        ))
        guard case .active(let gate) = await store.routingAuthority() else {
            throw TestError.assertion("expected active routing authority")
        }
        try expect(gate.isDegraded(now: exposureNow), "a changed shadow must not renew active policy")
        try expect(gate.freshnessRenewedAt == nil)
        try expect(await store.activeGenerationID() == staleGeneration.generationID)
    }

    await test("corrupt active generation pointer is explicit missing authority, never legacy fallback") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-exposure-corrupt-pointer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{\"generationID\":\"missing-generation\"}".utf8)
            .write(to: root.appendingPathComponent("active.json"), options: .atomic)
        let store = SkillRuntimeGenerationStore(baseDirectory: root)
        guard case .corrupt(let pointerID) = await store.routingAuthority() else {
            throw TestError.assertion("corrupt pointer must not fall back to legacy routing")
        }
        try expect(pointerID == "missing-generation")
    }

    await test("malformed active pointer is explicit missing authority, never legacy fallback") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-exposure-malformed-pointer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: root.appendingPathComponent("active.json"), options: .atomic)
        let store = SkillRuntimeGenerationStore(baseDirectory: root)
        guard case .corrupt(let pointerID) = await store.routingAuthority() else {
            throw TestError.assertion("malformed pointer must not fall back to legacy routing")
        }
        try expect(pointerID == "unreadable-active-pointer")
    }

    await test("specialist lifecycle recognizes Revoked, Desolved, and effective dates") {
        try expect(!SpecialistFilter.isActiveSpecialist(properties: statusProperty("Status", "Revoked"), now: exposureNow),
                   "Revoked specialist remained active")
        try expect(!SpecialistFilter.isActiveSpecialist(properties: statusProperty("Maturity", "Desolved"), now: exposureNow),
                   "Desolved specialist remained active")
        try expect(!SpecialistFilter.isActiveSpecialist(properties: dateProperty("2026-07-27"), now: exposureNow),
                   "effective date remained active")
        try expect(SpecialistFilter.isActiveSpecialist(properties: dateProperty("2026-07-29"), now: exposureNow),
                   "future date retired early")
        try expect(SpecialistFilter.isActiveSpecialist(properties: dateProperty("not-a-date"), now: exposureNow),
                   "malformed date must fail open")
    }
}
