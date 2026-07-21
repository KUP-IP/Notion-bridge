// VoiceMemoReliabilitySlice2Tests.swift — Closeout-A SC2/4/5/6/8 + SC1 hermetic
import Foundation
import MCP
import TheBridgeLib

func runVoiceMemoReliabilitySlice2Tests() async {
    print("\n🎙 Voice Memo Reliability Slice-2 (SC2/4/5/6/8/1)")

    await test("SC6_reminderTitleGate_rejectsMidClause_usesStableFallback") {
        let transcript = "I need you to remind me to call Greg about the proposal tomorrow morning."
        let bad = "too, but anyway, I'm trying to remediate this issue, issue"
        guard case .rejected(_, let fallback) = VoiceMemoReminderTitleGate.evaluate(bad, transcript: transcript) else {
            try expect(false, "SC6 mid-clause title must reject")
            return
        }
        try expect(!fallback.isEmpty, "SC6 fallback non-empty")
        try expect(!fallback.lowercased().hasPrefix("too"), "SC6 fallback not mid-clause")

        guard case .ok(let t) = VoiceMemoReminderTitleGate.evaluate("Call Greg about proposal", transcript: transcript) else {
            try expect(false, "SC6 clean title should pass")
            return
        }
        try expect(t.contains("Greg") || t.lowercased().contains("call"), "SC6 good title ok")
    }

    await test("SC5_degradedPreview_isSectioned") {
        let long = """
        Today I decided we will ship the bridge closeout first. I need to follow up with Greg Flicek.
        Also remind me to email the proposal. The topics include registry reliability and voice memos.
        """
        let preview = VoiceMemoDegradedPreviewBuilder.build(from: long)
        try expect(!preview.summary.isEmpty, "SC5 summary non-empty")
        try expect(
            preview.summary.contains("Topics:") || preview.summary.contains("Actions:") || preview.summary.contains("Decisions:"),
            "SC5 summary sectioned"
        )
        try expect(!preview.actions.isEmpty || preview.summary.contains("Actions:"), "SC5 has actions signal")
    }

    await test("SC2_memoryKeep_unboundSummary_preflightFailsClosed") {
        let unboundEntity = RegistryEntity(
            key: "memory",
            displayName: "Memory",
            dataSourceId: "ds-test",
            properties: [
                RegistryProperty(key: "title", notionName: "Memory", notionPropertyId: "title", type: "title", role: .title),
                RegistryProperty(key: "summary", notionName: "Relevant:", notionPropertyId: nil, type: "rich_text"),
                RegistryProperty(key: "players", notionName: "PLAYERS", notionPropertyId: "rel1", type: "relation", role: .relation),
            ],
            cacheTTLSeconds: 3600,
            hasBody: true
        )
        var threw = false
        do {
            try VoiceMemoProcessor.preflightMemoryKeepBindings(
                entity: unboundEntity,
                fields: ["title": "Memo", "summary": "A real eight word summary about the topic here"]
            )
        } catch let error as VoiceMemoError {
            if case .requiredFieldsUnbound(_, let unbound, _) = error {
                threw = unbound.contains("summary")
            }
        }
        try expect(threw, "SC2 unbound summary → requiredFieldsUnbound")

        let boundEntity = RegistryEntity(
            key: "memory",
            displayName: "Memory",
            dataSourceId: "ds-test",
            properties: [
                RegistryProperty(key: "title", notionName: "Memory", notionPropertyId: "title", type: "title", role: .title),
                RegistryProperty(key: "summary", notionName: "Relevant", notionPropertyId: "sum1", type: "rich_text"),
            ],
            cacheTTLSeconds: 3600,
            hasBody: true
        )
        try VoiceMemoProcessor.preflightMemoryKeepBindings(
            entity: boundEntity,
            fields: ["title": "Memo", "summary": "A real eight word summary about the topic here"]
        )
    }

    await test("SC8_memoryFallbackPolicy_defaultsToReview") {
        let prior = UserDefaults.standard.string(forKey: BridgeDefaults.voiceMemoMemoryFallbackPolicy)
        defer {
            if let prior {
                UserDefaults.standard.set(prior, forKey: BridgeDefaults.voiceMemoMemoryFallbackPolicy)
            } else {
                UserDefaults.standard.removeObject(forKey: BridgeDefaults.voiceMemoMemoryFallbackPolicy)
            }
        }
        UserDefaults.standard.removeObject(forKey: BridgeDefaults.voiceMemoMemoryFallbackPolicy)
        try expect(
            BridgeDefaults.voiceMemoMemoryFallbackPolicyEffective == .review,
            "SC8 default policy=review"
        )
        UserDefaults.standard.set("agentMemory", forKey: BridgeDefaults.voiceMemoMemoryFallbackPolicy)
        try expect(
            BridgeDefaults.voiceMemoMemoryFallbackPolicyEffective == .agentMemory,
            "SC8 agentMemory parse"
        )
        UserDefaults.standard.set("off", forKey: BridgeDefaults.voiceMemoMemoryFallbackPolicy)
        try expect(
            BridgeDefaults.voiceMemoMemoryFallbackPolicyEffective == .off,
            "SC8 off parse"
        )
    }

    await test("SC4_firstNameUnique_resolvesViaListAfterExactMiss") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let schema: Value = .object(["type": .string("object")])
        await router.register(ToolRegistration(
            name: "registry_find",
            module: "registry",
            tier: .open,
            description: "stub",
            inputSchema: schema,
            handler: { _ in .object(["rows": .array([])]) }
        ))
        await router.register(ToolRegistration(
            name: "registry_list",
            module: "registry",
            tier: .open,
            description: "stub",
            inputSchema: schema,
            handler: { _ in
                .object([
                    "rows": .array([
                        .object([
                            "id": .string("contact-greg"),
                            "title": .string("Greg Flicek"),
                        ]),
                    ]),
                ])
            }
        ))
        let id = try await VoiceMemoProcessor.resolveRegistryRowId(
            entityKey: "contact", hint: "Greg", router: router
        )
        try expect(id == "contact-greg", "SC4 unique first-name → id, got \(id)")
    }

    await test("SC1_commitReceipt_exposesMemoStateAndCompletedIntents") {
        let receipt = VoiceMemoProcessor.commitReceipt(
            ok: true,
            memoId: "memo-sc1-unique-\(UUID().uuidString)",
            intentKind: "reminder",
            intentState: "committed",
            detail: "reminders_create: x",
            markedProcessed: false
        )
        guard case .object(let obj) = receipt else {
            try expect(false, "SC1 receipt object")
            return
        }
        guard case .string(let state)? = obj["memoState"] else {
            try expect(false, "SC1 memoState present")
            return
        }
        try expect(
            state == "partially_committed" || state == "committed",
            "SC1 memoState present (\(state))"
        )
        guard case .bool(let marked)? = obj["markedProcessed"] else {
            try expect(false, "SC1 markedProcessed present")
            return
        }
        try expect(marked == false, "SC1 not fully processed")
        guard case .array(let completed)? = obj["completedIntents"] else {
            try expect(false, "SC1 completedIntents present")
            return
        }
        try expect(!completed.isEmpty, "SC1 completedIntents non-empty on ok")
    }
}
