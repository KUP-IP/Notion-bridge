import Foundation
import MCP

/// Pure builders/parsers for Wave 2 Notion REST contracts (#225–#231, #236–#237).
/// Keep request-body construction out of live `NotionClient` so hermetic tests
/// can assert wire shape without a token.
public enum NotionRESTContracts {

    // MARK: - JSON → MCP.Value

    public static func mcpValue(fromJSON any: Any) -> Value {
        if any is NSNull { return .null }
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            let d = n.doubleValue
            if d == Double(n.intValue) { return .int(n.intValue) }
            return .double(d)
        }
        if let b = any as? Bool { return .bool(b) }
        if let i = any as? Int { return .int(i) }
        if let d = any as? Double { return .double(d) }
        if let s = any as? String { return .string(s) }
        if let dicts = any as? [[String: Any]] {
            return .array(dicts.map { mcpValue(fromJSON: $0) })
        }
        if let a = any as? [Any] { return .array(a.map(mcpValue(fromJSON:))) }
        if let o = any as? [String: Any] {
            return .object(o.mapValues { mcpValue(fromJSON: $0) })
        }
        return .string("\(any)")
    }

    // MARK: - Query status echo (#227)

    /// Merge Notion `has_more` / `next_cursor` / `request_status` into a tool
    /// envelope. A successful partial page stays successful: never flip `ok`
    /// to false when `request_status.type == incomplete`.
    public static func mergeQueryStatus(
        from json: [String: Any],
        into result: inout [String: Value]
    ) {
        if let hasMore = json["has_more"] as? Bool {
            result["has_more"] = .bool(hasMore)
            if hasMore { result["truncated"] = .bool(true) }
        }
        if let cursor = json["next_cursor"] as? String, !cursor.isEmpty {
            result["next_cursor"] = .string(cursor)
        }
        if let status = json["request_status"] as? [String: Any] {
            result["request_status"] = mcpValue(fromJSON: status)
            if (status["type"] as? String) == "incomplete" {
                result["truncated"] = .bool(true)
            }
        }
    }

    // MARK: - Search (#226)

    public static func buildSearchBody(
        query: String?,
        pageSize: Int,
        startCursor: String?,
        objectFilter: String?,
        inTrash: Bool?,
        sortJSON: String?
    ) throws -> [String: Any] {
        let size = min(max(pageSize, 1), 100)
        var body: [String: Any] = ["page_size": size]
        if let query, !query.isEmpty { body["query"] = query }
        if let startCursor, !startCursor.isEmpty { body["start_cursor"] = startCursor }
        if let objectFilter, !objectFilter.isEmpty {
            let allowed = Set(["page", "data_source"])
            guard allowed.contains(objectFilter) else {
                throw NotionClientError.decodingError(
                    "search filter.value must be 'page' or 'data_source' (got \(objectFilter))"
                )
            }
            var filter: [String: Any] = ["property": "object", "value": objectFilter]
            if let inTrash { filter["in_trash"] = inTrash }
            body["filter"] = filter
        } else if let inTrash {
            body["filter"] = ["in_trash": inTrash]
        }
        if let sortJSON, !sortJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let data = sortJSON.data(using: .utf8),
                  let sortObj = try? JSONSerialization.jsonObject(with: data) else {
                throw NotionClientError.decodingError("search sort must be valid JSON")
            }
            body["sort"] = sortObj
        }
        return body
    }

    // MARK: - Comments (#229)

    public enum CommentContentMode: Equatable {
        case markdown(String)
        case richText(String)

        public static func parse(markdown: String?, text: String?) throws -> CommentContentMode {
            let md = markdown?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let tx = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hasMD = !md.isEmpty
            let hasText = !tx.isEmpty
            guard hasMD != hasText else {
                throw NotionClientError.decodingError(
                    "exactly one of markdown or text/rich_text is required (XOR)"
                )
            }
            return hasMD ? .markdown(md) : .richText(tx)
        }
    }

    public static func buildCreateCommentBody(
        pageId: String?,
        discussionId: String?,
        blockId: String?,
        content: CommentContentMode
    ) throws -> [String: Any] {
        let hasPage = !(pageId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasDiscussion = !(discussionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasBlock = !(blockId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let parentCount = [hasPage, hasDiscussion, hasBlock].filter { $0 }.count
        guard parentCount == 1 else {
            throw NotionClientError.decodingError(
                "createComment requires exactly one of pageId, discussionId, or blockId"
            )
        }
        var body: [String: Any] = [:]
        switch content {
        case .markdown(let md):
            body["markdown"] = md
        case .richText(let text):
            body["rich_text"] = [["type": "text", "text": ["content": text]]]
        }
        if hasDiscussion, let discussionId {
            body["discussion_id"] = discussionId.replacingOccurrences(of: "-", with: "")
            return body
        }
        if hasBlock, let blockId {
            body["parent"] = ["block_id": blockId.replacingOccurrences(of: "-", with: "")]
            return body
        }
        body["parent"] = ["page_id": NotionClient.normalizePageId(pageId!)]
        return body
    }

    public static func buildUpdateCommentBody(content: CommentContentMode) -> [String: Any] {
        switch content {
        case .markdown(let md):
            return ["markdown": md]
        case .richText(let text):
            return ["rich_text": [["type": "text", "text": ["content": text]]]]
        }
    }

    // MARK: - Templates (#230)

    /// `template` XOR `children`. Template apply is async; erase_content is refused.
    public static func resolveTemplateXORChildren(
        templateId: String?,
        templateType: String?,
        timezone: String?,
        childrenJSON: String?,
        eraseContent: Bool?
    ) throws -> (template: [String: Any]?, children: Data?) {
        if eraseContent == true {
            throw NotionClientError.decodingError(
                "erase_content is not supported — refused (irreversible; not exposed)"
            )
        }
        let hasTemplateId = !(templateId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let type = (templateType ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasType = !type.isEmpty && type != "none"
        let hasTemplate = hasTemplateId || hasType
        let childrenTrimmed = childrenJSON?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasChildren = !childrenTrimmed.isEmpty
        if hasTemplate && hasChildren {
            throw NotionClientError.decodingError("template XOR children — pass one, not both")
        }
        var template: [String: Any]? = nil
        if hasTemplate {
            var t: [String: Any] = [:]
            if hasTemplateId {
                t["type"] = "template_id"
                t["template_id"] = templateId!.replacingOccurrences(of: "-", with: "")
            } else {
                t["type"] = type
            }
            if let timezone, !timezone.isEmpty { t["timezone"] = timezone }
            template = t
        }
        let children: Data? = hasChildren ? childrenTrimmed.data(using: .utf8) : nil
        return (template, children)
    }

    // MARK: - Async task (#237)

    public static func isAsyncTaskEnvelope(_ json: [String: Any]) -> Bool {
        (json["object"] as? String) == "async_task"
    }

    public static func asyncTaskValue(_ json: [String: Any]) -> Value {
        var out: [String: Value] = [
            "queued": .bool(true),
            "object": .string("async_task"),
            "id": .string(json["id"] as? String ?? ""),
            "status": .string(json["status"] as? String ?? "queued")
        ]
        if let url = json["status_url"] as? String { out["status_url"] = .string(url) }
        if let n = json["poll_after_seconds"] as? Int {
            out["poll_after_seconds"] = .int(n)
        } else if let n = json["poll_after_seconds"] as? Double {
            out["poll_after_seconds"] = .int(Int(n))
        }
        if let op = json["operation"] as? String { out["operation"] = .string(op) }
        return .object(out)
    }

    // MARK: - File upload (#231)

    public static let singlePartMaxBytes = 20 * 1024 * 1024
    public static let multiPartMaxBytes = 5 * 1024 * 1024 * 1024
    public static let multiPartChunkBytes = 10 * 1024 * 1024

    public enum FileUploadMode: String {
        case singlePart = "single_part"
        case multiPart = "multi_part"
        case externalURL = "external_url"
    }

    public static func parseFileUploadMode(_ raw: String?) -> FileUploadMode {
        switch (raw ?? "single_part").trimmingCharacters(in: .whitespacesAndNewlines) {
        case "multi_part": return .multiPart
        case "external_url": return .externalURL
        default: return .singlePart
        }
    }

    public static func rejectSinglePartIfOversized(byteCount: Int, mode: FileUploadMode) -> String? {
        if mode == .singlePart, byteCount > singlePartMaxBytes {
            return "File exceeds 20MB single_part limit (\(byteCount) bytes). Pass mode:'multi_part' (opt-in, up to 5GB) or mode:'external_url'."
        }
        if mode == .multiPart, byteCount > multiPartMaxBytes {
            return "File exceeds 5GB multi_part limit (\(byteCount) bytes)"
        }
        return nil
    }

    public static func numberOfParts(byteCount: Int) -> Int {
        max(1, Int(ceil(Double(byteCount) / Double(multiPartChunkBytes))))
    }

    // MARK: - Page trash (#228)

    public static func buildPageTrashBody(inTrash: Bool) -> [String: Any] {
        ["in_trash": inTrash]
    }

    // MARK: - View create extras (#225)

    /// `viewId` is dashboard-widget parent, not duplicate-from.
    public static func viewCreateParentKind(
        databaseId: String?,
        dataSourceId: String?,
        viewId: String?
    ) throws -> (hasDB: Bool, hasDS: Bool, hasView: Bool) {
        let hasDB = !(databaseId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasDS = !(dataSourceId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasView = !(viewId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if hasView && hasDB {
            throw NotionClientError.decodingError(
                "viewId is the dashboard-widget parent, mutually exclusive with databaseId (not a duplicate-from source)"
            )
        }
        guard hasDB || hasDS || hasView else {
            throw NotionClientError.decodingError(
                "at least one of databaseId, dataSourceId, or viewId (dashboard parent) is required"
            )
        }
        return (hasDB, hasDS, hasView)
    }
}
