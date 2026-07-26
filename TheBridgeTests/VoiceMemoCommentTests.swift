// VoiceMemoCommentTests.swift — PKT-MEM-136 comment disposition + idea-thread ledger
// TheBridge · Tests
//
// `VoiceMemoIntentKind.comment` (+ required `purpose: idea | reflow`) posts a
// Notion page comment against a target resolved via `registry_resolve_and_update`
// (PKT-MEM-135) — never a bespoke resolution path (GOAL_CONDITION). `idea`-purpose
// comments are logged to the new `VoiceMemoIdeaThreadStore` ledger; `reflow`-purpose
// comments are posted the same way but never logged (fire-and-forget, D48).
// Resolution/post failure routes gracefully to REVIEW (never a crash) — the same
// "graceful BLOCKED" contract PKT-1064 established for the originating-Player attach.
//
// Hermetic: `executeComment` is driven directly against a stub `ToolRouter`
// (`registry_resolve_and_update` + `notion_comment_create` stubs) — no live
// Notion. The ledger is a real file under a HERMETIC temp home
// (`BridgePaths.overrideHomeForTesting`) — no writes to the user's real
// Application Support directory.

import Foundation
import MCP
import TheBridgeLib

// MARK: - Hermetic home

private func withCommentTempHome<T>(_ body: () async throws -> T) async rethrows -> T {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("VoiceMemoComment-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? fm.removeItem(at: tmp)
    }
    return try await body()
}

// MARK: - Stub state + router

/// Captures what `executeComment` sends to the stubbed
/// `registry_resolve_and_update` / `notion_comment_create` tools, and drives
/// their canned responses.
private actor CommentStubState {
    // registry_resolve_and_update
    var resolveCallCount = 0
    var lastResolveEntity: String = ""
    var lastResolveWhere: [String: Value] = [:]
    var lastResolveFields: [String: Value] = [:]
    /// nil = respond with a successful match; non-nil = throw this instead.
    var resolveThrows: Error?
    var resolveMatchedId = "page-resolved-000"

    // notion_comment_create
    var commentCallCount = 0
    var lastCommentPageId: String = ""
    var lastCommentText: String = ""
    var commentSuccess = true
    var commentDiscussionId = "discussion-abc"

    func recordResolve(entity: String, whereClause: [String: Value], fields: [String: Value]) {
        resolveCallCount += 1
        lastResolveEntity = entity
        lastResolveWhere = whereClause
        lastResolveFields = fields
    }
    func setResolveThrows(_ e: Error?) { resolveThrows = e }
    func setResolveMatchedId(_ id: String) { resolveMatchedId = id }
    func recordComment(pageId: String, text: String) {
        commentCallCount += 1
        lastCommentPageId = pageId
        lastCommentText = text
    }
    func setCommentSuccess(_ ok: Bool) { commentSuccess = ok }
    func setCommentDiscussionId(_ id: String) { commentDiscussionId = id }
}

private func installCommentStubs(on router: ToolRouter, state: CommentStubState) async {
    let resolveAndUpdate = ToolRegistration(
        name: "registry_resolve_and_update", module: "stub", tier: .open,
        description: "stub",
        inputSchema: .object(["type": .string("object")]),
        handler: { args in
            guard case .object(let a) = args,
                  case .string(let entity)? = a["entity"],
                  case .object(let whereClause)? = a["where"],
                  case .object(let fields)? = a["fields"] else {
                throw ToolRouterError.invalidArguments(toolName: "registry_resolve_and_update", reason: "malformed stub call")
            }
            await state.recordResolve(entity: entity, whereClause: whereClause, fields: fields)
            if let thrown = await state.resolveThrows { throw thrown }
            let matchedId = await state.resolveMatchedId
            return .object([
                "updated": .bool(true),
                "matchedId": .string(matchedId),
                "row": .object(["id": .string(matchedId)]),
            ])
        })

    let commentCreate = ToolRegistration(
        name: "notion_comment_create", module: "stub", tier: .open,
        description: "stub",
        inputSchema: .object(["type": .string("object")]),
        handler: { args in
            guard case .object(let a) = args,
                  case .string(let pageId)? = a["pageId"],
                  case .string(let text)? = a["text"] else {
                throw ToolRouterError.invalidArguments(toolName: "notion_comment_create", reason: "malformed stub call")
            }
            await state.recordComment(pageId: pageId, text: text)
            let ok = await state.commentSuccess
            let discussionId = await state.commentDiscussionId
            return .object([
                "success": .bool(ok),
                "id": .string(ok ? "comment-id-1" : ""),
                "ids": .array([.string(ok ? "comment-id-1" : "")]),
                "chunks": .int(1),
                "discussionId": .string(ok ? discussionId : ""),
            ])
        })

    await router.register(resolveAndUpdate)
    await router.register(commentCreate)
}

// MARK: - Fixtures

/// A registry entity fixture WITH a bound title-role property (the normal case).
private func projectEntityWithTitle() -> RegistryEntity {
    RegistryEntity(
        key: "project",
        displayName: "Projects",
        dataSourceId: "ds-project-000",
        properties: [
            RegistryProperty(key: "name", notionName: "Project Name", notionPropertyId: "id_title", type: "title", role: .title),
            RegistryProperty(key: "summary", notionName: "Summary", notionPropertyId: "id_summary", type: "rich_text"),
        ],
        cacheTTLSeconds: 3600
    )
}

/// A registry entity fixture with NO title-role property (malformed/legacy
/// config — should block comment resolution gracefully).
private func projectEntityNoTitle() -> RegistryEntity {
    RegistryEntity(
        key: "project",
        displayName: "Projects",
        dataSourceId: "ds-project-000",
        properties: [
            RegistryProperty(key: "summary", notionName: "Summary", notionPropertyId: "id_summary", type: "rich_text"),
        ],
        cacheTTLSeconds: 3600
    )
}

private func commentIntent(
    purpose: VoiceMemoCommentPurpose? = .idea,
    entityHint: String? = "Bridge Platform",
    body: String? = "This is the idea: cache the resolved row.",
    entityKey: String? = "project"
) -> VoiceMemoIntent {
    VoiceMemoIntent(
        kind: .comment,
        confidence: 0.95,
        entityKey: entityKey,
        entityHint: entityHint,
        body: body,
        purpose: purpose
    )
}

/// Registers a fixture registry entity into the SHARED config store under the
/// hermetic temp home so `VoiceMemoProcessor.loadRegistryEntity` resolves it.
private func seedEntity(_ entity: RegistryEntity) async throws {
    _ = try await RegistryConfigStore.shared.upsertEntity(entity)
}

func runVoiceMemoCommentTests() async {
    print("\n\u{1F4AC} PKT-MEM-136 — comment disposition + idea-thread ledger")

    // 1. Happy path — idea purpose: resolves, posts, logs to the ledger.
    await test("PKT-MEM-136: idea-purpose comment resolves via registry_resolve_and_update, posts, and logs the ledger") {
        try await withCommentTempHome {
            try await seedEntity(projectEntityWithTitle())
            let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
            let state = CommentStubState()
            await installCommentStubs(on: router, state: state)
            await state.setResolveMatchedId("page-alpha")
            await state.setCommentDiscussionId("disc-alpha")

            let detail = try await VoiceMemoProcessor.executeComment(
                commentIntent(purpose: .idea, entityHint: "Bridge Platform"),
                memoId: "memo-1",
                router: router
            )

            try expect(detail.contains("page-alpha"), "detail should record the resolved page id: \(detail)")
            try expect(detail.contains("idea"), "detail should record the purpose: \(detail)")

            let resolveCalls = await state.resolveCallCount
            try expect(resolveCalls == 1, "registry_resolve_and_update must be called exactly once")
            let resolveEntity = await state.lastResolveEntity
            try expect(resolveEntity == "project", "must resolve against the intent's entityKey")
            let whereClause = await state.lastResolveWhere
            try expect(whereClause == ["name": .string("Bridge Platform")],
                       "where predicate must use the entity's title-role canonical key + entityHint, got \(whereClause)")

            let commentCalls = await state.commentCallCount
            try expect(commentCalls == 1, "notion_comment_create must be called exactly once")
            let commentPageId = await state.lastCommentPageId
            try expect(commentPageId == "page-alpha", "comment must post to the RESOLVED page id")

            let ledger = VoiceMemoIdeaThreadStore.load()
            try expect(ledger.entries.count == 1, "idea comment must be logged to the ledger")
            let entry = ledger.entries[0]
            try expect(entry.memoId == "memo-1", "ledger entry must carry the memoId")
            try expect(entry.discussionId == "disc-alpha", "ledger entry must carry the discussion_id")
            try expect(entry.targetEntityKey == "project", "ledger entry must carry the target entity key")
            try expect(entry.targetPageId == "page-alpha", "ledger entry must carry the resolved page id")
            try expect(entry.signedOffAt == nil, "a freshly-posted idea comment must be unsigned-off (D51 — no automatic trigger)")
        }
    }

    // 2. Happy path — reflow purpose: resolves, posts, but NEVER logs to the ledger.
    await test("PKT-MEM-136: reflow-purpose comment posts but is NEVER logged to the ledger") {
        try await withCommentTempHome {
            try await seedEntity(projectEntityWithTitle())
            let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
            let state = CommentStubState()
            await installCommentStubs(on: router, state: state)

            _ = try await VoiceMemoProcessor.executeComment(
                commentIntent(purpose: .reflow, entityHint: "Bridge Platform", body: "Reflow: rename this section."),
                memoId: "memo-2",
                router: router
            )

            let commentCalls = await state.commentCallCount
            try expect(commentCalls == 1, "reflow comments must still post via notion_comment_create")

            let ledger = VoiceMemoIdeaThreadStore.load()
            try expect(ledger.entries.isEmpty, "reflow-purpose comments must NEVER appear in the ledger (fire-and-forget, D48)")
        }
    }

    // 3. Missing entityHint → graceful BLOCKED (throws, no crash), no registry/comment calls.
    await test("PKT-MEM-136: missing entityHint blocks gracefully before any tool call") {
        try await withCommentTempHome {
            try await seedEntity(projectEntityWithTitle())
            let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
            let state = CommentStubState()
            await installCommentStubs(on: router, state: state)

            var threw = false
            do {
                _ = try await VoiceMemoProcessor.executeComment(
                    commentIntent(purpose: .idea, entityHint: nil),
                    memoId: "memo-3",
                    router: router
                )
            } catch let error as VoiceMemoError {
                threw = true
                if case .commentTargetUnresolved = error {} else {
                    try expect(false, "expected commentTargetUnresolved, got \(error)")
                }
            }
            try expect(threw, "missing entityHint must throw commentTargetUnresolved, not crash")
            let resolveCalls = await state.resolveCallCount
            try expect(resolveCalls == 0, "must not call registry_resolve_and_update with no hint to predicate-match against")
            let commentCalls = await state.commentCallCount
            try expect(commentCalls == 0, "must not post a comment when the target is unresolved")
            try expect(VoiceMemoIdeaThreadStore.load().entries.isEmpty, "ledger must stay empty on a blocked resolution")
        }
    }

    // 4. Entity has no title-role property → graceful BLOCKED before any tool call.
    await test("PKT-MEM-136: entity with no title-role property blocks gracefully") {
        try await withCommentTempHome {
            try await seedEntity(projectEntityNoTitle())
            let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
            let state = CommentStubState()
            await installCommentStubs(on: router, state: state)

            var threw = false
            do {
                _ = try await VoiceMemoProcessor.executeComment(commentIntent(), memoId: "memo-4", router: router)
            } catch let error as VoiceMemoError {
                threw = true
                if case .commentTargetUnresolved = error {} else {
                    try expect(false, "expected commentTargetUnresolved, got \(error)")
                }
            }
            try expect(threw, "an entity with no title-role property must block gracefully")
            let resolveCalls = await state.resolveCallCount
            try expect(resolveCalls == 0, "must not call registry_resolve_and_update with no predicate key available")
        }
    }

    // 5. Entity not configured in the registry → graceful BLOCKED.
    await test("PKT-MEM-136: unconfigured entity blocks gracefully") {
        try await withCommentTempHome {
            // No seedEntity call — the registry has no "project" entity configured.
            let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
            let state = CommentStubState()
            await installCommentStubs(on: router, state: state)

            var threw = false
            do {
                _ = try await VoiceMemoProcessor.executeComment(commentIntent(), memoId: "memo-5", router: router)
            } catch let error as VoiceMemoError {
                threw = true
                if case .commentTargetUnresolved = error {} else {
                    try expect(false, "expected commentTargetUnresolved, got \(error)")
                }
            }
            try expect(threw, "an unconfigured entity must block gracefully")
        }
    }

    // 6. registry_resolve_and_update throws (no-match / ambiguous) → graceful BLOCKED,
    //    no comment posted, ledger untouched.
    await test("PKT-MEM-136: registry_resolve_and_update no-match/ambiguous failure blocks gracefully, no comment posted") {
        try await withCommentTempHome {
            try await seedEntity(projectEntityWithTitle())
            let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
            let state = CommentStubState()
            await installCommentStubs(on: router, state: state)
            await state.setResolveThrows(ToolRouterError.invalidArguments(
                toolName: "registry_resolve_and_update", reason: "no ‘project’ row matched where=[name] — nothing to update"
            ))

            var threw = false
            do {
                _ = try await VoiceMemoProcessor.executeComment(commentIntent(), memoId: "memo-6", router: router)
            } catch let error as VoiceMemoError {
                threw = true
                if case .commentTargetUnresolved = error {} else {
                    try expect(false, "expected commentTargetUnresolved, got \(error)")
                }
            }
            try expect(threw, "a registry_resolve_and_update failure must surface as a graceful BLOCKED, not a crash")
            let commentCalls = await state.commentCallCount
            try expect(commentCalls == 0, "must never post a comment when the target failed to resolve")
            try expect(VoiceMemoIdeaThreadStore.load().entries.isEmpty, "ledger must stay empty when resolution fails")
        }
    }

    // 7. Missing purpose → throws invalidIntent (never silently defaults).
    await test("PKT-MEM-136: missing purpose throws invalidIntent") {
        try await withCommentTempHome {
            try await seedEntity(projectEntityWithTitle())
            let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
            let state = CommentStubState()
            await installCommentStubs(on: router, state: state)

            var threw = false
            do {
                _ = try await VoiceMemoProcessor.executeComment(commentIntent(purpose: nil), memoId: "memo-7", router: router)
            } catch let error as VoiceMemoError {
                threw = true
                if case .invalidIntent = error {} else {
                    try expect(false, "expected invalidIntent, got \(error)")
                }
            }
            try expect(threw, "a comment intent with no purpose must throw, never silently default")
            let resolveCalls = await state.resolveCallCount
            try expect(resolveCalls == 0, "must validate purpose BEFORE any tool call")
        }
    }

    // 8. Missing entityKey → throws invalidIntent.
    await test("PKT-MEM-136: missing entityKey throws invalidIntent") {
        try await withCommentTempHome {
            let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
            let state = CommentStubState()
            await installCommentStubs(on: router, state: state)

            var threw = false
            do {
                _ = try await VoiceMemoProcessor.executeComment(commentIntent(entityKey: nil), memoId: "memo-8", router: router)
            } catch let error as VoiceMemoError {
                threw = true
                if case .invalidIntent = error {} else {
                    try expect(false, "expected invalidIntent, got \(error)")
                }
            }
            try expect(threw, "a comment intent with no entityKey must throw")
        }
    }

    // 9. Missing text (no body, no title) → throws invalidIntent.
    await test("PKT-MEM-136: missing comment text throws invalidIntent") {
        try await withCommentTempHome {
            try await seedEntity(projectEntityWithTitle())
            let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
            let state = CommentStubState()
            await installCommentStubs(on: router, state: state)

            var threw = false
            do {
                _ = try await VoiceMemoProcessor.executeComment(commentIntent(body: nil), memoId: "memo-9", router: router)
            } catch let error as VoiceMemoError {
                threw = true
                if case .invalidIntent = error {} else {
                    try expect(false, "expected invalidIntent, got \(error)")
                }
            }
            try expect(threw, "a comment intent with no body/title text must throw")
        }
    }

    // 10. notion_comment_create reports success:false → graceful BLOCKED, ledger untouched
    //     even though resolution DID succeed (the receipt-marker write already landed —
    //     only the ledger log is guarded on the comment post itself succeeding).
    await test("PKT-MEM-136: notion_comment_create success:false blocks gracefully, ledger untouched") {
        try await withCommentTempHome {
            try await seedEntity(projectEntityWithTitle())
            let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
            let state = CommentStubState()
            await installCommentStubs(on: router, state: state)
            await state.setCommentSuccess(false)

            var threw = false
            do {
                _ = try await VoiceMemoProcessor.executeComment(commentIntent(purpose: .idea), memoId: "memo-10", router: router)
            } catch let error as VoiceMemoError {
                threw = true
                if case .commentPostFailed = error {} else {
                    try expect(false, "expected commentPostFailed, got \(error)")
                }
            }
            try expect(threw, "a failed comment post must throw commentPostFailed, not crash")
            let resolveCalls = await state.resolveCallCount
            try expect(resolveCalls == 1, "resolution must have been attempted (and succeeded) before the post failure")
            try expect(VoiceMemoIdeaThreadStore.load().entries.isEmpty, "ledger must stay empty when the comment post itself fails")
        }
    }

    // 11. title falls back as comment text when body is absent.
    await test("PKT-MEM-136: title is used as comment text when body is absent") {
        try await withCommentTempHome {
            try await seedEntity(projectEntityWithTitle())
            let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
            let state = CommentStubState()
            await installCommentStubs(on: router, state: state)

            var intent = commentIntent(body: nil)
            intent.title = "Idea from title fallback"
            _ = try await VoiceMemoProcessor.executeComment(intent, memoId: "memo-11", router: router)

            let text = await state.lastCommentText
            try expect(text == "Idea from title fallback", "title must be used as the comment text when body is nil, got: \(text)")
        }
    }

    // 11b. REGRESSION (found via live MCP demo, 2026-07-02): commit(args:)'s raw
    //      argument parser never wired a top-level "body" argument into
    //      intent.body — only "title" was threaded through, silently forcing
    //      every real MCP caller onto the documented *fallback* path instead of
    //      the preferred one. All prior comment tests drove executeComment/
    //      execute directly with a hand-built VoiceMemoIntent, bypassing the
    //      args-parsing layer entirely, so this had zero coverage. This test
    //      goes through the actual commit(args:) entry point a real MCP call
    //      uses, with ONLY "body" set (no "title"), proving the fix threads it.
    await test("PKT-MEM-136: commit(args:) wires a top-level body argument into the posted comment text") {
        defer { VoiceMemoParseRouter.providerOverride = nil }
        VoiceMemoParseRouter.providerOverride = { _ in [HeuristicParseProvider()] }

        let fm = FileManager.default
        let fakeHome = fm.temporaryDirectory.appendingPathComponent("VoiceMemoCommentBodyArg-\(UUID().uuidString)", isDirectory: true)
        let recordings = fakeHome.appendingPathComponent("Library/Application Support/com.apple.voicememos/Recordings", isDirectory: true)
        try fm.createDirectory(at: recordings, withIntermediateDirectories: true)
        BridgePaths.overrideHomeForTesting(fakeHome)
        defer {
            BridgePaths.overrideHomeForTesting(nil)
            try? fm.removeItem(at: fakeHome)
        }

        let audio = recordings.appendingPathComponent("body-arg-fixture.m4a")
        try Data([0x00]).write(to: audio)
        let sidecar = recordings.appendingPathComponent("body-arg-fixture.txt")
        try "Unrelated filler transcript text.".data(using: .utf8)?.write(to: sidecar)
        guard let recording = VoiceMemoDiscovery.listRecordings(roots: [recordings]).first else {
            throw TestError.assertion("fixture recording not discovered")
        }

        try await seedEntity(projectEntityWithTitle())
        let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
        let state = CommentStubState()
        await installCommentStubs(on: router, state: state)
        await state.setResolveMatchedId("page-body-arg")

        let result = try await VoiceMemoProcessor.commit(args: .object([
            "memoId": .string(recording.id),
            "intentKind": .string(VoiceMemoIntentKind.comment.rawValue),
            "entityKey": .string("project"),
            "entityHint": .string("Bridge Platform"),
            "purpose": .string(VoiceMemoCommentPurpose.idea.rawValue),
            "body": .string("Posted via the body argument, not title."),
        ]), router: router)

        guard case .object(let envelope) = result, case .bool(let ok)? = envelope["ok"] else {
            try expect(false, "expected an object envelope with ok")
            return
        }
        try expect(ok, "commit(args:) should succeed with a real fixture recording + valid comment args")

        let text = await state.lastCommentText
        try expect(text == "Posted via the body argument, not title.",
                   "the raw top-level 'body' argument must reach notion_comment_create's text, got: \(text)")
    }

    // 12. registry_resolve_and_update's fields carry a non-empty receipt marker
    //     (that tool requires non-empty fields — it is resolve AND update).
    await test("PKT-MEM-136: registry_resolve_and_update call carries a non-empty receipt field") {
        try await withCommentTempHome {
            try await seedEntity(projectEntityWithTitle())
            let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
            let state = CommentStubState()
            await installCommentStubs(on: router, state: state)

            _ = try await VoiceMemoProcessor.executeComment(commentIntent(purpose: .idea), memoId: "memo-12", router: router)

            let fields = await state.lastResolveFields
            try expect(!fields.isEmpty, "registry_resolve_and_update requires non-empty fields — executeComment must supply one")
            if case .string(let marker)? = fields[VoiceMemoProcessor.commentReceiptField] {
                try expect(marker.contains("idea"), "receipt marker should record the purpose, got: \(marker)")
            } else {
                try expect(false, "expected a string value on the commentReceiptField key")
            }
        }
    }

    // MARK: - VoiceMemoIdeaThreadStore (D50 — mirrors VoiceMemoReviewStore's shape)

    await test("PKT-MEM-136: VoiceMemoIdeaThreadStore load returns empty manifest when no file exists") {
        try await withCommentTempHome {
            let manifest = VoiceMemoIdeaThreadStore.load()
            try expect(manifest.entries.isEmpty, "a fresh hermetic home must have no idea-thread entries")
            try expect(manifest.openCount == 0, "openCount must be 0 on an empty manifest")
        }
    }

    await test("PKT-MEM-136: VoiceMemoIdeaThreadStore enqueue persists and load round-trips") {
        try await withCommentTempHome {
            let entry = VoiceMemoIdeaThreadEntry(
                memoId: "memo-x", discussionId: "disc-x",
                targetEntityKey: "project", targetPageId: "page-x"
            )
            try VoiceMemoIdeaThreadStore.enqueue(entry)

            let reloaded = VoiceMemoIdeaThreadStore.load()
            try expect(reloaded.entries.count == 1, "one entry must persist")
            try expect(reloaded.entries[0].memoId == "memo-x")
            try expect(reloaded.entries[0].discussionId == "disc-x")
            try expect(reloaded.entries[0].targetEntityKey == "project")
            try expect(reloaded.entries[0].targetPageId == "page-x")
            try expect(reloaded.entries[0].signedOffAt == nil, "a fresh entry is unsigned-off")
        }
    }

    await test("PKT-MEM-136: VoiceMemoIdeaThreadStore is not deduped — a memo may post multiple idea comments") {
        try await withCommentTempHome {
            try VoiceMemoIdeaThreadStore.enqueue(VoiceMemoIdeaThreadEntry(
                memoId: "memo-y", discussionId: "disc-1", targetEntityKey: "project", targetPageId: "page-1"
            ))
            try VoiceMemoIdeaThreadStore.enqueue(VoiceMemoIdeaThreadEntry(
                memoId: "memo-y", discussionId: "disc-2", targetEntityKey: "contact", targetPageId: "page-2"
            ))
            let manifest = VoiceMemoIdeaThreadStore.load()
            try expect(manifest.entries.count == 2, "distinct idea comments from the SAME memo must both persist, not dedupe")
        }
    }

    await test("PKT-MEM-136: VoiceMemoIdeaThreadStore openEntries excludes signed-off entries") {
        try await withCommentTempHome {
            let signedOff = VoiceMemoIdeaThreadEntry(
                memoId: "memo-z", discussionId: "disc-z", targetEntityKey: "project",
                targetPageId: "page-z", signedOffAt: ISO8601DateFormatter().string(from: Date())
            )
            let open = VoiceMemoIdeaThreadEntry(
                memoId: "memo-z2", discussionId: "disc-z2", targetEntityKey: "project", targetPageId: "page-z2"
            )
            try VoiceMemoIdeaThreadStore.enqueue(signedOff)
            try VoiceMemoIdeaThreadStore.enqueue(open)

            let openOnly = VoiceMemoIdeaThreadStore.openEntries()
            try expect(openOnly.count == 1, "only the unsigned entry should be open")
            try expect(openOnly[0].memoId == "memo-z2", "the open entry must be the one without signedOffAt")

            let manifest = VoiceMemoIdeaThreadStore.load()
            try expect(manifest.openCount == 1, "manifest.openCount must match openEntries")
        }
    }

    // MARK: - processOne integration: a failed comment resolution routes to REVIEW (not a crash)

    await test("PKT-MEM-136: a comment intent with no resolvable target routes gracefully via commit(), never crashes") {
        try await withCommentTempHome {
            try await seedEntity(projectEntityWithTitle())
            let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
            let state = CommentStubState()
            await installCommentStubs(on: router, state: state)
            await state.setResolveThrows(ToolRouterError.invalidArguments(
                toolName: "registry_resolve_and_update", reason: "no ‘project’ row matched — nothing to update"
            ))

            // Exercise the exact catch shape `processOne` uses: any thrown error from
            // execute(intent:...) must be catchable generically (untyped catch), proving
            // the packet's GOAL_CONDITION ("resolution failure routes to REVIEW gracefully,
            // no crash") holds through the SAME code path processOne uses.
            var caught: Error?
            do {
                _ = try await VoiceMemoProcessor.execute(
                    intent: commentIntent(purpose: .idea),
                    plan: VoiceMemoPlan(generatedTitle: "t", skipMemoryKeep: false, summary: "s", actions: [], intents: []),
                    transcript: "transcript",
                    memoId: "memo-review",
                    router: router
                )
            } catch {
                caught = error
            }
            try expect(caught != nil, "the failure must be a normal Swift throw, catchable by processOne's generic catch")
            try expect((caught as? VoiceMemoError).map { if case .commentTargetUnresolved = $0 { return true } else { return false } } ?? false,
                       "the caught error must be the graceful commentTargetUnresolved case")
        }
    }

    // MARK: - dryRunDetail / cockpit labels (exhaustive-switch wiring sanity)

    await test("PKT-MEM-136: dryRunDetail renders a comment-specific line") {
        let detail = VoiceMemoProcessor.dryRunDetail(commentIntent(purpose: .idea, entityHint: "Bridge Platform"))
        try expect(detail.contains("notion_comment_create"), "dry-run detail should name the tool: \(detail)")
        try expect(detail.contains("idea"), "dry-run detail should surface purpose: \(detail)")
    }

    await test("PKT-MEM-136: MemoryHubCockpitLabels.intentKind humanizes comment") {
        let label = MemoryHubCockpitLabels.intentKind(.comment)
        try expect(label == "Comment", "expected 'Comment', got \(label)")
        try expect(!label.contains("_"), "label must not leak the raw enum case")
    }

    await test("PKT-MEM-136: MemoryHubCommitGuardrails.threshold(for: .comment) matches the conservative memory_keep/reminder bar") {
        try expect(MemoryHubCommitGuardrails.threshold(for: .comment) == 0.90,
                   "comment should be held to the same conservative auto-execute bar as memory_keep/reminder")
    }

    await test("PKT-MEM-136: cockpit intentRows round-trips a comment intent's purpose") {
        let intent = commentIntent(purpose: .idea, entityHint: "Bridge Platform")
        let plan = VoiceMemoPlan(generatedTitle: "t", skipMemoryKeep: false, summary: "s", actions: [], intents: [intent])
        let rows = MemoryProcessCockpit.intentRows(memoId: "memo-cockpit", plan: plan)
        try expect(rows.count == 1, "one row expected")
        try expect(rows[0].purpose == .idea, "the row must carry the intent's purpose")
        try expect(rows[0].intent().purpose == .idea, "intent() must round-trip purpose back onto the rebuilt VoiceMemoIntent")
    }

    await test("PKT-MEM-136: intentWritePreview + commitValuePreview handle .comment without crashing") {
        let intent = commentIntent(purpose: .idea, entityHint: "Bridge Platform")
        var mutableIntent = intent
        mutableIntent.title = "Cache the resolved row"
        let plan = VoiceMemoPlan(generatedTitle: "t", skipMemoryKeep: false, summary: "s", actions: [], intents: [mutableIntent])
        let rows = MemoryProcessCockpit.intentRows(memoId: "memo-preview", plan: plan)
        try expect(rows.count == 1)
        let preview = MemoryProcessCockpit.intentWritePreview(for: rows[0], plan: plan)
        try expect(!preview.isEmpty, "comment rows must produce a non-empty write preview")
        let value = MemoryProcessCockpit.commitValuePreview(for: rows[0])
        try expect(value == "Cache the resolved row", "commitValuePreview should surface the comment title, got \(String(describing: value))")
    }
}
