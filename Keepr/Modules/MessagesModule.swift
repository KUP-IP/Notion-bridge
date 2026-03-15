// MessagesModule.swift – V1-05 iMessage Tools
// KeeprBridge · Modules
//
// Six tools: messages_search, messages_recent, messages_chat,
// messages_content, messages_participants, messages_send.
// Read tools use SQLite on ~/Library/Messages/chat.db.
// Send uses AppleScript (osascript). Tier: 🔴 Red.

import Foundation
import MCP

// MARK: - MessagesModule

/// Provides iMessage/SMS read and send tools.
/// Read operations query chat.db via sqlite3 CLI (read-only).
/// Send uses AppleScript through osascript.
public enum MessagesModule {

    public static let moduleName = "messages"

    private static let chatDBPath: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db").path
    }()

    /// Register all MessagesModule tools on the given router.
    public static func register(on router: ToolRouter) async {

        // MARK: 1. messages_search – 🟢 Green
        await router.register(ToolRegistration(
            name: "messages_search",
            module: moduleName,
            tier: .open,
            description: "Search iMessage/SMS messages by keyword. Returns matching messages with sender, date, and chat context. Uses SQLite on chat.db (read-only).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string"), "description": .string("Keyword to search for in message text")]),
                    "limit": .object(["type": .string("integer"), "description": .string("Max results to return (default: 50)")])
                ]),
                "required": .array([.string("query")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let query) = args["query"] else {
                    throw ToolRouterError.unknownTool("messages_search: missing 'query'")
                }
                let limit: Int = { if case .int(let l) = args["limit"] { return l }; return 50 }()

                let sql = """
                    SELECT m.ROWID, m.text, m.is_from_me,
                           h.id AS handle_id,
                           datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime') AS date_str
                    FROM message m
                    LEFT JOIN handle h ON m.handle_id = h.ROWID
                    WHERE m.text LIKE '%' || ?1 || '%'
                    ORDER BY m.date DESC
                    LIMIT ?2
                    """
                return try runSQLite(db: chatDBPath, sql: sql, params: [query, String(limit)])
            }
        ))

        // MARK: 2. messages_recent – 🟢 Green
        await router.register(ToolRegistration(
            name: "messages_recent",
            module: moduleName,
            tier: .open,
            description: "List recent conversations with last message preview, ordered by recency.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object(["type": .string("integer"), "description": .string("Max conversations to return (default: 20)")])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let limit: Int = {
                    if case .object(let args) = arguments,
                       case .int(let l) = args["limit"] { return l }
                    return 20
                }()

                let sql = """
                    SELECT c.ROWID, c.chat_identifier, c.display_name,
                           m.text AS last_message,
                           m.is_from_me,
                           datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime') AS date_str
                    FROM chat c
                    JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
                    JOIN message m ON m.ROWID = cmj.message_id
                    WHERE m.ROWID = (
                        SELECT cmj2.message_id FROM chat_message_join cmj2
                        JOIN message m2 ON m2.ROWID = cmj2.message_id
                        WHERE cmj2.chat_id = c.ROWID
                        ORDER BY m2.date DESC LIMIT 1
                    )
                    ORDER BY m.date DESC
                    LIMIT ?1
                    """
                return try runSQLite(db: chatDBPath, sql: sql, params: [String(limit)])
            }
        ))

        // MARK: 3. messages_chat – 🟢 Green
        await router.register(ToolRegistration(
            name: "messages_chat",
            module: moduleName,
            tier: .open,
            description: "Get message thread with a specific contact (phone number or email).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "contact": .object(["type": .string("string"), "description": .string("Contact phone number or email")]),
                    "limit": .object(["type": .string("integer"), "description": .string("Max messages to return (default: 50)")])
                ]),
                "required": .array([.string("contact")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let contact) = args["contact"] else {
                    throw ToolRouterError.unknownTool("messages_chat: missing 'contact'")
                }
                let limit: Int = { if case .int(let l) = args["limit"] { return l }; return 50 }()

                let sql = """
                    SELECT m.ROWID, m.text, m.is_from_me,
                           h.id AS handle_id,
                           datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime') AS date_str
                    FROM message m
                    LEFT JOIN handle h ON m.handle_id = h.ROWID
                    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                    JOIN chat c ON c.ROWID = cmj.chat_id
                    WHERE c.chat_identifier LIKE '%' || ?1 || '%'
                       OR h.id LIKE '%' || ?1 || '%'
                    ORDER BY m.date DESC
                    LIMIT ?2
                    """
                return try runSQLite(db: chatDBPath, sql: sql, params: [contact, String(limit)])
            }
        ))

        // MARK: 4. messages_content – 🟢 Green
        await router.register(ToolRegistration(
            name: "messages_content",
            module: moduleName,
            tier: .open,
            description: "Get a single message by its ROWID with full metadata.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "messageId": .object(["type": .string("integer"), "description": .string("Message ROWID")])
                ]),
                "required": .array([.string("messageId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .int(let msgId) = args["messageId"] else {
                    throw ToolRouterError.unknownTool("messages_content: missing 'messageId'")
                }

                let sql = """
                    SELECT m.ROWID, m.text, m.is_from_me, m.service,
                           m.cache_has_attachments,
                           h.id AS handle_id,
                           datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime') AS date_str
                    FROM message m
                    LEFT JOIN handle h ON m.handle_id = h.ROWID
                    WHERE m.ROWID = ?1
                    """
                return try runSQLite(db: chatDBPath, sql: sql, params: [String(msgId)])
            }
        ))

        // MARK: 5. messages_participants – 🟢 Green
        await router.register(ToolRegistration(
            name: "messages_participants",
            module: moduleName,
            tier: .open,
            description: "List participants (handles) in a chat identified by chat_identifier.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "chatIdentifier": .object(["type": .string("string"), "description": .string("Chat identifier (phone number, email, or group ID)")])
                ]),
                "required": .array([.string("chatIdentifier")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let chatId) = args["chatIdentifier"] else {
                    throw ToolRouterError.unknownTool("messages_participants: missing 'chatIdentifier'")
                }

                let sql = """
                    SELECT h.ROWID, h.id AS handle_id, h.service
                    FROM handle h
                    JOIN chat_handle_join chj ON chj.handle_id = h.ROWID
                    JOIN chat c ON c.ROWID = chj.chat_id
                    WHERE c.chat_identifier LIKE '%' || ?1 || '%'
                    """
                return try runSQLite(db: chatDBPath, sql: sql, params: [chatId])
            }
        ))

        // MARK: 6. messages_send – 🔴 Red (Destructive-Confirm)
        await router.register(ToolRegistration(
            name: "messages_send",
            module: moduleName,
            tier: .notify,
            description: "Send an iMessage via AppleScript. Requires explicit confirm='SEND' parameter. SecurityGate enforces red-tier confirmation.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "recipient": .object(["type": .string("string"), "description": .string("Recipient phone number or email")]),
                    "body": .object(["type": .string("string"), "description": .string("Message body text")]),
                    "confirm": .object(["type": .string("string"), "description": .string("Must be exactly 'SEND' to proceed")])
                ]),
                "required": .array([.string("recipient"), .string("body"), .string("confirm")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let recipient) = args["recipient"],
                      case .string(let body) = args["body"],
                      case .string(let confirm) = args["confirm"] else {
                    throw ToolRouterError.unknownTool("messages_send: missing required parameters")
                }

                guard confirm == "SEND" else {
                    return .object([
                        "error": .string("messages_send requires confirm: 'SEND'"),
                        "sent": .bool(false)
                    ])
                }

                // Sanitize inputs for AppleScript
                let safeRecipient = recipient
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let safeBody = body
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")

                let script = """
                    tell application "Messages"
                        set targetService to 1st service whose service type = iMessage
                        set targetBuddy to buddy "\(safeRecipient)" of targetService
                        send "\(safeBody)" to targetBuddy
                    end tell
                    """

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                try process.run()
                process.waitUntilExit()

                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                if process.terminationStatus == 0 {
                    return .object([
                        "sent": .bool(true),
                        "recipient": .string(recipient),
                        "bodyLength": .int(body.utf8.count)
                    ])
                } else {
                    return .object([
                        "sent": .bool(false),
                        "error": .string(stderr.isEmpty ? "AppleScript execution failed" : stderr)
                    ])
                }
            }
        ))
    }

    // MARK: - SQLite Helper

    /// Run a read-only SQLite query via sqlite3 CLI and return structured results.
    /// Parameters use positional placeholders (?1, ?2, etc.) expanded before execution.
    private static func runSQLite(db: String, sql: String, params: [String]) throws -> Value {
        var expandedSQL = sql
        for (index, param) in params.enumerated() {
            let placeholder = "?\(index + 1)"
            let escaped = param.replacingOccurrences(of: "'", with: "''")
            expandedSQL = expandedSQL.replacingOccurrences(of: placeholder, with: "'\(escaped)'")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-json", "-readonly", db, expandedSQL]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            return .object(["error": .string(stderr.isEmpty ? "SQLite query failed" : stderr)])
        }

        let trimmed = (String(data: stdoutData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .object(["rows": .array([]), "count": .int(0)])
        }

        guard let parsed = try? JSONSerialization.jsonObject(with: stdoutData) else {
            return .object(["rows": .string(trimmed), "count": .int(0)])
        }

        let rows = jsonToValue(parsed)
        let count: Int
        if case .array(let arr) = rows { count = arr.count } else { count = 1 }

        return .object(["rows": rows, "count": .int(count)])
    }

    /// Convert a JSONSerialization result into an MCP Value tree.
    private static func jsonToValue(_ obj: Any) -> Value {
        if let dict = obj as? [String: Any] {
            var result: [String: Value] = [:]
            for (k, v) in dict { result[k] = jsonToValue(v) }
            return .object(result)
        }
        if let arr = obj as? [Any] {
            return .array(arr.map { jsonToValue($0) })
        }
        if let str = obj as? String {
            return .string(str)
        }
        if obj is NSNull {
            return .null
        }
        if let num = obj as? Int {
            return .int(num)
        }
        if let num = obj as? Double {
            return .double(num)
        }
        return .string(String(describing: obj))
    }
}
