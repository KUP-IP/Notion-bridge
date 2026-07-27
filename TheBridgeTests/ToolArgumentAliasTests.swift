// ToolArgumentAliasTests.swift — PKT-1125
// Hint-only tool-argument alias coverage. These tests lock the advisory to
// the post-error path and prove it never mutates arguments or retries a handler.

import Foundation
import MCP
import TheBridgeLib

private actor AliasInvocationProbe {
    private var invocations = 0
    private var lastArguments: Value?

    func record(_ arguments: Value) {
        invocations += 1
        lastArguments = arguments
    }

    func snapshot() -> (count: Int, arguments: Value?) {
        (invocations, lastArguments)
    }
}

private func aliasTestRouter() -> ToolRouter {
    ToolRouter(
        securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
        auditLog: AuditLog(),
        licenseStatusProvider: { .trial(daysRemaining: 30) }
    )
}

private func aliasInputSchema(_ keys: [String]) -> Value {
    .object([
        "type": .string("object"),
        "properties": .object(Dictionary(uniqueKeysWithValues: keys.map {
            ($0, .object(["type": .string("string")]))
        }))
    ])
}

func runToolArgumentAliasTests() async {
    print("\n\u{1F9ED} Tool argument aliases (PKT-1125 · hint-only)")

    await test("named wrong keys produce exact deterministic hints") {
        let hint = BridgeToolAliases.didYouMean(providedKeys: [
            "page", "content", "data_source_id", "block", "parent_id"
        ])
        try expect(
            hint == "did you mean: block→blockId, content→text, data_source_id→dataSourceId, page→pageId, parent_id→parentId",
            "unexpected exact hint: \(String(describing: hint))"
        )
    }

    await test("accepted alias keys are suppressed without hiding other precise hints") {
        let hint = BridgeToolAliases.didYouMean(
            providedKeys: ["content", "page"],
            acceptedKeys: ["content", "text"]
        )
        try expect(hint == "did you mean: page→pageId", "accepted content key was misidentified: \(String(describing: hint))")
    }

    await test("known wrong key fails once with exact hint and no retry") {
        let router = aliasTestRouter()
        let probe = AliasInvocationProbe()
        await router.register(ToolRegistration(
            name: "alias_wrong_key",
            module: "alias-test",
            tier: .open,
            description: "test",
            inputSchema: aliasInputSchema(["text"]),
            handler: { arguments in
                await probe.record(arguments)
                throw ToolRouterError.invalidArguments(toolName: "alias_wrong_key", reason: "missing 'text'")
            }
        ))

        let (text, isError) = await router.dispatchFormatted(
            toolName: "alias_wrong_key",
            arguments: .object(["content": .string("caller value")])
        )
        let snapshot = await probe.snapshot()
        try expect(isError, "throwing handler must stay error-shaped")
        try expect(text.hasSuffix("did you mean: content→text"), "exact hint missing: \(text)")
        try expect(snapshot.count == 1, "handler was invoked \(snapshot.count) times")
    }

    await test("schema-accepted dual key gets no misleading post-error hint") {
        let router = aliasTestRouter()
        let probe = AliasInvocationProbe()
        await router.register(ToolRegistration(
            name: "alias_dual_key",
            module: "alias-test",
            tier: .open,
            description: "test",
            inputSchema: aliasInputSchema(["text", "content"]),
            handler: { arguments in
                await probe.record(arguments)
                throw ToolRouterError.invalidArguments(toolName: "alias_dual_key", reason: "different validation failed")
            }
        ))

        let (text, isError) = await router.dispatchFormatted(
            toolName: "alias_dual_key",
            arguments: .object(["content": .string("accepted")])
        )
        let snapshot = await probe.snapshot()
        try expect(isError, "throwing handler must stay error-shaped")
        try expect(!text.contains("did you mean"), "accepted content key received a false hint: \(text)")
        try expect(snapshot.count == 1, "handler was invoked \(snapshot.count) times")
    }

    await test("canonical key reaches handler unchanged and succeeds once") {
        let router = aliasTestRouter()
        let probe = AliasInvocationProbe()
        await router.register(ToolRegistration(
            name: "alias_canonical_key",
            module: "alias-test",
            tier: .open,
            description: "test",
            inputSchema: aliasInputSchema(["text"]),
            handler: { arguments in
                await probe.record(arguments)
                return .string("ok")
            }
        ))

        let original: Value = .object(["text": .string("canonical value")])
        let (text, isError) = await router.dispatchFormatted(
            toolName: "alias_canonical_key",
            arguments: original
        )
        let snapshot = await probe.snapshot()
        try expect(!isError && text == "ok", "canonical call changed behavior: \(text)")
        try expect(snapshot.count == 1, "handler was invoked \(snapshot.count) times")
        try expect(snapshot.arguments == original, "canonical arguments were mutated")
    }

    await test("unknown key keeps original error with no fabricated hint") {
        let router = aliasTestRouter()
        let probe = AliasInvocationProbe()
        await router.register(ToolRegistration(
            name: "alias_unknown_key",
            module: "alias-test",
            tier: .open,
            description: "test",
            inputSchema: aliasInputSchema(["text"]),
            handler: { arguments in
                await probe.record(arguments)
                throw ToolRouterError.invalidArguments(toolName: "alias_unknown_key", reason: "missing 'text'")
            }
        ))

        let (text, isError) = await router.dispatchFormatted(
            toolName: "alias_unknown_key",
            arguments: .object(["mystery": .string("value")])
        )
        let snapshot = await probe.snapshot()
        try expect(isError, "throwing handler must stay error-shaped")
        try expect(!text.contains("did you mean"), "unknown key received fabricated hint: \(text)")
        try expect(snapshot.count == 1, "handler was invoked \(snapshot.count) times")
    }

    await test("live Notion dual-key schemas declare every accepted handler alias") {
        let gate = SecurityGate(approvalProvider: TestSecurityApprovalProvider())
        let log = AuditLog()
        let router = ToolRouter(
            securityGate: gate,
            auditLog: log,
            licenseStatusProvider: { .trial(daysRemaining: 30) }
        )
        await NotionModule.register(on: router)

        func propertyKeys(_ name: String) async throws -> Set<String> {
            guard let registration = await router.allRegistrations().first(where: { $0.name == name }),
                  case .object(let schema) = registration.inputSchema,
                  case .object(let properties)? = schema["properties"] else {
                throw TestError.assertion("missing inspectable schema for \(name)")
            }
            return Set(properties.keys)
        }

        let commentKeys = try await propertyKeys("notion_comment_create")
        try expect(commentKeys.isSuperset(of: ["text", "content"]), "comment aliases missing from schema")
        try expect(
            BridgeToolAliases.didYouMean(providedKeys: ["content"], acceptedKeys: commentKeys) == nil,
            "accepted notion_comment_create.content would receive a false hint"
        )

        let appendKeys = try await propertyKeys("notion_blocks_append")
        try expect(appendKeys.isSuperset(of: ["blockId", "children", "pageId", "markdown"]), "append aliases missing from schema")

        let queryKeys = try await propertyKeys("notion_query")
        try expect(queryKeys.isSuperset(of: ["dataSourceId", "parentId", "parentType"]), "query aliases missing from schema")
    }

    await test("dispatchFormatted contains one handler call site and no error-path retry") {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TheBridge/Server/ToolRouter.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let handlerCalls = source.components(separatedBy: "try await tool.handler(arguments)").count - 1
        try expect(handlerCalls == 1, "ToolRouter handler call-site count drifted to \(handlerCalls)")

        guard let catchRange = source.range(of: "        } catch {\n            // v3.0·0.5: central param-misnomer recovery"),
              let helpersRange = source.range(of: "\n    // MARK: Helpers", range: catchRange.lowerBound..<source.endIndex) else {
            throw TestError.assertion("could not isolate dispatchFormatted error path")
        }
        let errorPath = String(source[catchRange.lowerBound..<helpersRange.lowerBound])
        try expect(!errorPath.contains("tool.handler"), "error path contains a handler retry")
    }
}
