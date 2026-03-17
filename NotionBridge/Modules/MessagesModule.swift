// MessagesModule.swift – V1-PATCH-001 iMessage Tools
// NotionBridge · Modules
//
// Six tools: messages_search, messages_recent, messages_chat,
// messages_content, messages_participants, messages_send.
// Read tools use native SQLite C API on ~/Library/Messages/chat.db.
// Send uses in-process AppleScript (NSAppleScript). Tier: notify (5 open, 1 notify).
//
// V1-PATCH-001 changes:
// - Replaced runSQLite CLI helper with SQLiteConnection (native sqlite3 C API)
// - Single persistent read-only connection with WAL journal mode
// - Added extractText() fallback: text → NSKeyedUnarchiver(attributedBody) → nil
// - All 4 read queries now SELECT m.attributedBody for decoding
// - messages_search WHERE clause includes attributedBody CAST fallback

import Foundation
import SQLite3
import MCP

// MARK: - SQLiteConnection

/// Persistent read-only SQLite connection using native C API.
/// Replaces per-query sqlite3 CLI process spawning to eliminate
/// "database is locked" errors from concurrent tool calls.
/// Thread-safe: uses SQLite's default serialized threading mode.
final class SQLiteConnection {
    private var db: OpaquePointer?

    /// Open a read-only SQLite connection with WAL journal mode.
    /// - Parameter path: Absolute path to the database file.
    /// - Throws: `SQLiteConnectionError.openFailed` if the database cannot be opened.
    init(path: String) throws {
        let flags = SQLITE_OPEN_READONLY
        let result = sqlite3_open_v2(path, &db, flags, nil)
        guard result == SQLITE_OK, db != nil else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            throw SQLiteConnectionError.openFailed(msg)
        }
        // Enable WAL journal mode for concurrent read access
        executeRaw("PRAGMA journal_mode=WAL")
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    /// Execute a raw SQL statement (no results expected).
    private func executeRaw(_ sql: String) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    /// Execute a read-only query with positional string parameters (?1, ?2, ...).
    /// Returns an array of dictionaries mapping column names to values.
    /// BLOB columns are returned as `Data`. NULL columns are returned as `NSNull`.
    func query(_ sql: String, params: [String] = []) throws -> [[String: Any]] {
        var stmt: OpaquePointer?
        let prepResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepResult == SQLITE_OK, let statement = stmt else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Prepare failed"
            throw SQLiteConnectionError.queryFailed(msg)
        }
        defer { sqlite3_finalize(statement) }

        // Bind string parameters (1-indexed)
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, param) in params.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), param, -1, SQLITE_TRANSIENT)
        }

        var rows: [[String: Any]] = []
        let colCount = sqlite3_column_count(statement)

        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<colCount {
                let name = String(cString: sqlite3_column_name(statement, i))
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER:
                    row[name] = Int(sqlite3_column_int64(statement, i))
                case SQLITE_FLOAT:
                    row[name] = sqlite3_column_double(statement, i)
                case SQLITE_TEXT:
                    if let cStr = sqlite3_column_text(statement, i) {
                        row[name] = String(cString: cStr)
                    } else {
                        row[name] = NSNull()
                    }
                case SQLITE_BLOB:
                    if let bytes = sqlite3_column_blob(statement, i) {
                        let length = Int(sqlite3_column_bytes(statement, i))
                        row[name] = Data(bytes: bytes, count: length)
                    } else {
                        row[name] = NSNull()
                    }
                case SQLITE_NULL:
                    row[name] = NSNull()
                default:
                    row[name] = NSNull()
                }
            }
            rows.append(row)
        }

        return rows
    }
}

enum SQLiteConnectionError: Error, LocalizedError {
    case openFailed(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "SQLite open failed: \(msg)"
        case .queryFailed(let msg): return "SQLite query failed: \(msg)"
        }
    }
}

// MARK: - MessagesModule

/// Provides iMessage/SMS read and send tools.
/// Read operations query chat.db via native SQLite C API (read-only, WAL).
/// Send uses in-process AppleScript through NSAppleScript.
public enum MessagesModule {

    public static let moduleName = "messages"

    private static let chatDBPath: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db").path
    }()

    /// Shared persistent SQLite connection for all read queries.
    /// Lazy initialization; reconnects if needed via getConnection().
    nonisolated(unsafe) private static var connection: SQLiteConnection? = {
        try? SQLiteConnection(path: chatDBPath)
    }()

    /// Get or re-establish the shared SQLite connection.
    private static func getConnection() throws -> SQLiteConnection {
        if let conn = connection { return conn }
        let conn = try SQLiteConnection(path: chatDBPath)
        connection = conn
        return conn
    }

    // MARK: - Text Extraction

    /// Decode an `attributedBody` NSKeyedArchiver blob to plain text.
    /// Returns nil on any decoding failure (graceful fallback via try?).
    private static func decodeAttributedBody(_ data: Data) -> String? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        defer { unarchiver.finishDecoding() }
        guard let attrStr = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSAttributedString else { return nil }
        let text = attrStr.string
        return text.isEmpty ? nil : text
    }

    /// Extract text from a query result row with attributedBody fallback.
    /// Priority: text column → decoded attributedBody → nil.
    private static func extractText(row: [String: Any], textKey: String = "text") -> String? {
        // 1. Try text column
        if let str = row[textKey] as? String, !str.isEmpty {
            return str
        }
        // 2. Try attributedBody decode
        if let data = row["attributedBody"] as? Data {
            return decodeAttributedBody(data)
        }
        return nil
    }

    // MARK: - Result Conversion

    /// Convert query result rows to MCP Value, applying extractText fallback on the text column.
    /// The raw `attributedBody` blob is excluded from output.
    private static func rowsToValue(_ rows: [[String: Any]], textKey: String = "text") -> Value {
        let valueRows: [Value] = rows.map { row in
            var result: [String: Value] = [:]
            for (key, val) in row {
                // Never expose raw attributedBody blob to caller
                if key == "attributedBody" { continue }
                if key == textKey {
                    // Apply text extraction with attributedBody fallback
                    let extracted = extractText(row: row, textKey: textKey)
                    result[key] = extracted.map { .string($0) } ?? .null
                } else if let s = val as? String {
                    result[key] = .string(s)
                } else if let i = val as? Int {
                    result[key] = .int(i)
                } else if let d = val as? Double {
                    result[key] = .double(d)
                } else {
                    result[key] = .null
                }
            }
            return .object(result)
        }
        return .object(["rows": .array(valueRows), "count": .int(valueRows.count)])
    }

    /// Convert query result rows to MCP Value without text extraction (for non-message queries).
    private static func rawRowsToValue(_ rows: [[String: Any]]) -> Value {
        let valueRows: [Value] = rows.map { row in
            var result: [String: Value] = [:]
            for (key, val) in row {
                if let s = val as? String {
                    result[key] = .string(s)
                } else if let i = val as? Int {
                    result[key] = .int(i)
                } else if let d = val as? Double {
                    result[key] = .double(d)
                } else {
                    result[key] = .null
                }
            }
            return .object(result)
        }
        return .object(["rows": .array(valueRows), "count": .int(valueRows.count)])
    }

    // MARK: - Tool Registration

    /// Register all MessagesModule tools on the given router.
    public static func register(on router: ToolRouter) async {

        // MARK: 1. messages_search – open
        await router.register(ToolRegistration(
            name: "messages_search",
            module: moduleName,
            tier: .open,
            description: "Search iMessage/SMS messages by keyword. Returns matching messages with sender, date, and chat context. Uses native SQLite on chat.db (read-only).",
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
                    throw ToolRouterError.invalidArguments(toolName: "messages_search", reason: "missing 'query'")
                }
                let limit: Int = { if case .int(let l) = args["limit"] { return l }; return 50 }()

                let conn = try getConnection()
                // Search text column directly + attributedBody fallback via CAST for blob keyword match
                let sql = """
                    SELECT m.ROWID, m.text, m.attributedBody, m.is_from_me,
                           h.id AS handle_id,
                           datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime') AS date_str
                    FROM message m
                    LEFT JOIN handle h ON m.handle_id = h.ROWID
                    WHERE m.text LIKE '%' || ?1 || '%'
                       OR (m.text IS NULL AND m.attributedBody IS NOT NULL
                           AND CAST(m.attributedBody AS TEXT) LIKE '%' || ?1 || '%')
                    ORDER BY m.date DESC
                    LIMIT ?2
                    """
                let rows = try conn.query(sql, params: [query, String(limit)])
                return rowsToValue(rows)
            }
        ))

        // MARK: 2. messages_recent – open
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

                let conn = try getConnection()
                let sql = """
                    SELECT c.ROWID, c.chat_identifier, c.display_name,
                           m.text AS last_message, m.attributedBody,
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
                let rows = try conn.query(sql, params: [String(limit)])
                return rowsToValue(rows, textKey: "last_message")
            }
        ))

        // MARK: 3. messages_chat – open
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
                    throw ToolRouterError.invalidArguments(toolName: "messages_chat", reason: "missing 'contact'")
                }
                let limit: Int = { if case .int(let l) = args["limit"] { return l }; return 50 }()

                let conn = try getConnection()
                let sql = """
                    SELECT m.ROWID, m.text, m.attributedBody, m.is_from_me,
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
                let rows = try conn.query(sql, params: [contact, String(limit)])
                return rowsToValue(rows)
            }
        ))

        // MARK: 4. messages_content – open
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
                    throw ToolRouterError.invalidArguments(toolName: "messages_content", reason: "missing 'messageId'")
                }

                let conn = try getConnection()
                let sql = """
                    SELECT m.ROWID, m.text, m.attributedBody, m.is_from_me, m.service,
                           m.cache_has_attachments,
                           h.id AS handle_id,
                           datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime') AS date_str
                    FROM message m
                    LEFT JOIN handle h ON m.handle_id = h.ROWID
                    WHERE m.ROWID = ?1
                    """
                let rows = try conn.query(sql, params: [String(msgId)])
                return rowsToValue(rows)
            }
        ))

        // MARK: 5. messages_participants – open
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
                    throw ToolRouterError.invalidArguments(toolName: "messages_participants", reason: "missing 'chatIdentifier'")
                }

                let conn = try getConnection()
                let sql = """
                    SELECT h.ROWID, h.id AS handle_id, h.service
                    FROM handle h
                    JOIN chat_handle_join chj ON chj.handle_id = h.ROWID
                    JOIN chat c ON c.ROWID = chj.chat_id
                    WHERE c.chat_identifier LIKE '%' || ?1 || '%'
                    """
                let rows = try conn.query(sql, params: [chatId])
                return rawRowsToValue(rows)
            }
        ))

        // MARK: 6. messages_send – notify
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
                    throw ToolRouterError.invalidArguments(toolName: "messages_send", reason: "missing required parameters")
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

                let appleScript = NSAppleScript(source: script)
                var errorInfo: NSDictionary?
                _ = appleScript?.executeAndReturnError(&errorInfo)

                if errorInfo == nil {
                    return .object([
                        "sent": .bool(true),
                        "recipient": .string(recipient),
                        "bodyLength": .int(body.utf8.count)
                    ])
                } else {
                    let errorMessage = errorInfo?[NSAppleScript.errorMessage] as? String ?? "AppleScript execution failed"
                    let errorNumber = errorInfo?[NSAppleScript.errorNumber] as? Int ?? -1
                    return .object([
                        "sent": .bool(false),
                        "error": .string(errorMessage),
                        "errorNumber": .int(errorNumber)
                    ])
                }
            }
        ))
    }
}
