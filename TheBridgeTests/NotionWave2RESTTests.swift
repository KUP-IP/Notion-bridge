import Foundation
import MCP
import TheBridgeLib

func runNotionWave2RESTTests() async {
    print("\n📝 Notion Wave 2 REST contracts")

    await test("#227 mergeQueryStatus echoes incomplete without ok:false") {
        var out: [String: Value] = ["count": .int(100)]
        NotionRESTContracts.mergeQueryStatus(from: [
            "has_more": false,
            "request_status": ["type": "incomplete", "incomplete_reason": "query_result_limit_reached"]
        ], into: &out)
        try expect(out["ok"] == nil, "must not set ok on a successful partial page")
        guard case .bool(true)? = out["truncated"] else {
            throw TestError.assertion("truncated should be true on incomplete")
        }
        guard case .object(let status)? = out["request_status"],
              case .string("incomplete")? = status["type"] else {
            throw TestError.assertion("request_status.type must echo incomplete")
        }
    }

    await test("#227 has_more also sets truncated") {
        var out: [String: Value] = [:]
        NotionRESTContracts.mergeQueryStatus(from: ["has_more": true, "next_cursor": "abc"], into: &out)
        guard case .bool(true)? = out["truncated"], case .bool(true)? = out["has_more"] else {
            throw TestError.assertion("has_more page should be truncated=true")
        }
        guard case .string("abc")? = out["next_cursor"] else {
            throw TestError.assertion("next_cursor missing")
        }
    }

    await test("#226 search body in_trash-only") {
        let body = try NotionRESTContracts.buildSearchBody(
            query: nil, pageSize: 10, startCursor: nil,
            objectFilter: nil, inTrash: true, sortJSON: nil
        )
        let filter = body["filter"] as? [String: Any]
        try expect((filter?["in_trash"] as? Bool) == true)
        try expect(filter?["property"] == nil, "in_trash-only filter must not invent object filter")
    }

    await test("#226 search body object+in_trash") {
        let body = try NotionRESTContracts.buildSearchBody(
            query: "x", pageSize: 25, startCursor: "c1",
            objectFilter: "page", inTrash: true, sortJSON: nil
        )
        let filter = body["filter"] as? [String: Any]
        try expect((filter?["property"] as? String) == "object")
        try expect((filter?["value"] as? String) == "page")
        try expect((filter?["in_trash"] as? Bool) == true)
        try expect((body["start_cursor"] as? String) == "c1")
    }

    await test("#226 search rejects invented object filter") {
        do {
            _ = try NotionRESTContracts.buildSearchBody(
                query: "x", pageSize: 10, startCursor: nil,
                objectFilter: "database", inTrash: nil, sortJSON: nil
            )
            throw TestError.assertion("database object filter must fail closed")
        } catch is TestError {
            throw TestError.assertion("database object filter must fail closed")
        } catch {
            // expected
        }
    }

    await test("#229 markdown XOR text") {
        do {
            _ = try NotionRESTContracts.CommentContentMode.parse(markdown: "a", text: "b")
            throw TestError.assertion("XOR both must fail")
        } catch is TestError { throw TestError.assertion("XOR both must fail") } catch {}
        do {
            _ = try NotionRESTContracts.CommentContentMode.parse(markdown: nil, text: nil)
            throw TestError.assertion("XOR neither must fail")
        } catch is TestError { throw TestError.assertion("XOR neither must fail") } catch {}
        let md = try NotionRESTContracts.CommentContentMode.parse(markdown: "hi", text: nil)
        try expect(md == .markdown("hi"))
    }

    await test("#229 create comment block parent") {
        let body = try NotionRESTContracts.buildCreateCommentBody(
            pageId: nil, discussionId: nil, blockId: "aaaa-bbbb", content: .markdown("note")
        )
        let parent = body["parent"] as? [String: Any]
        try expect((parent?["block_id"] as? String) == "aaaabbbb")
        try expect((body["markdown"] as? String) == "note")
        try expect(body["rich_text"] == nil)
    }

    await test("#229 create comment keeps discussion reply path") {
        let body = try NotionRESTContracts.buildCreateCommentBody(
            pageId: nil, discussionId: "disc-1", blockId: nil, content: .richText("reply")
        )
        try expect(body["parent"] == nil, "discussion reply must not send parent")
        try expect(body["discussion_id"] != nil)
        try expect(body["rich_text"] != nil)
    }

    await test("#230 template XOR children") {
        do {
            _ = try NotionRESTContracts.resolveTemplateXORChildren(
                templateId: "tmpl", templateType: nil, timezone: "America/Chicago",
                childrenJSON: "[{\"type\":\"paragraph\"}]", eraseContent: nil
            )
            throw TestError.assertion("template+children must fail")
        } catch is TestError { throw TestError.assertion("template+children must fail") } catch {}
    }

    await test("#230 erase_content refused") {
        do {
            _ = try NotionRESTContracts.resolveTemplateXORChildren(
                templateId: "tmpl", templateType: nil, timezone: nil,
                childrenJSON: nil, eraseContent: true
            )
            throw TestError.assertion("erase_content must be refused")
        } catch is TestError { throw TestError.assertion("erase_content must be refused") } catch {
            let d = "\(error)"
            try expect(d.contains("erase_content"), "got \(d)")
        }
    }

    await test("#230 template id + timezone only") {
        let r = try NotionRESTContracts.resolveTemplateXORChildren(
            templateId: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", templateType: nil,
            timezone: "America/Chicago", childrenJSON: nil, eraseContent: false
        )
        try expect(r.children == nil)
        try expect((r.template?["type"] as? String) == "template_id")
        try expect((r.template?["timezone"] as? String) == "America/Chicago")
    }

    await test("#231 single_part 20MB reject is default") {
        let msg = NotionRESTContracts.rejectSinglePartIfOversized(
            byteCount: NotionRESTContracts.singlePartMaxBytes + 1, mode: .singlePart
        )
        try expect(msg != nil, "20MB single_part must reject")
        let ok = NotionRESTContracts.rejectSinglePartIfOversized(
            byteCount: NotionRESTContracts.singlePartMaxBytes + 1, mode: .multiPart
        )
        try expect(ok == nil, "multi_part opt-in must allow >20MB")
    }

    await test("#228 page trash body is in_trash only") {
        let body = NotionRESTContracts.buildPageTrashBody(inTrash: true)
        try expect(body.keys.count == 1)
        try expect((body["in_trash"] as? Bool) == true)
        try expect(body["is_locked"] == nil)
    }

    await test("#225 viewId is dashboard parent, not duplicate-from") {
        do {
            _ = try NotionRESTContracts.viewCreateParentKind(
                databaseId: "db", dataSourceId: nil, viewId: "view"
            )
            throw TestError.assertion("viewId+databaseId must fail")
        } catch is TestError { throw TestError.assertion("viewId+databaseId must fail") } catch {
            let d = "\(error)"
            try expect(d.contains("dashboard"), "got \(d)")
        }
        let ok = try NotionRESTContracts.viewCreateParentKind(
            databaseId: nil, dataSourceId: nil, viewId: "dash"
        )
        try expect(ok.hasView)
    }

    await test("#237 async task envelope") {
        let json: [String: Any] = [
            "object": "async_task", "id": "task_1", "status": "queued",
            "status_url": "https://api.notion.com/v1/async_tasks/task_1",
            "poll_after_seconds": 2
        ]
        try expect(NotionRESTContracts.isAsyncTaskEnvelope(json))
        guard case .object(let o) = NotionRESTContracts.asyncTaskValue(json),
              case .bool(true)? = o["queued"] else {
            throw TestError.assertion("queued writes must not look like a complete page")
        }
        try expect(o["url"] == nil, "must not fake a page url")
    }

    let gate = SecurityGate(approvalProvider: TestSecurityApprovalProvider())
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await NotionModule.register(on: router)

    await test("Wave 2 request-tier tools refuse without confirm") {
        for name in ["notion_view_delete", "notion_page_trash", "notion_comment_delete"] {
            guard let tool = await router.registrations(forModule: "notion").first(where: { $0.name == name }) else {
                throw TestError.assertion("missing \(name)")
            }
            try expect(tool.tier == .request, "\(name) must be request-tier")
            try expect(!tool.neverAutoApprove, "\(name) must offer Always Allow")
            let result = try await tool.handler(.object(["viewId": .string("x"), "pageId": .string("x"), "commentId": .string("x"), "confirm": .bool(false)]))
            guard case .object(let o) = result, case .string(let err)? = o["error"] else {
                throw TestError.assertion("\(name) confirm:false must refuse")
            }
            try expect(err.contains("Refused"), "\(name) got \(err)")
        }
    }

    await test("notion_view_query rejects missing viewId") {
        do {
            _ = try await router.dispatch(toolName: "notion_view_query", arguments: .object([:]))
            throw TestError.assertion("expected missing viewId")
        } catch is ToolRouterError {}
    }

    await test("notion_async_task_get rejects missing taskId") {
        do {
            _ = try await router.dispatch(toolName: "notion_async_task_get", arguments: .object([:]))
            throw TestError.assertion("expected missing taskId")
        } catch is ToolRouterError {}
    }
}
