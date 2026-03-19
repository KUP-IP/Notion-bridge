// GoogleDriveModule.swift — Google Drive MCP Tools
// NotionBridge · Modules
// PKT-368: 6 tools — list, search, read, download, upload, metadata
//
// Tiers: 🟢 .open (list, search, read, metadata)
//        🟡 .notify (download, upload)

import Foundation
import MCP

// MARK: - GoogleDriveModule

/// Provides Google Drive file operation tools via MCP.
/// Uses GoogleDriveClient (actor) for API calls with 10 req/sec rate limiting.
public enum GoogleDriveModule {

    public static let moduleName = "gdrive"

    /// Register all GoogleDriveModule tools on the given router.
    public static func register(on router: ToolRouter) async {

        let client = GoogleDriveClient.shared

        // MARK: C2 — gdrive_list (🟢 open)

        await router.register(ToolRegistration(
            name: "gdrive_list",
            module: moduleName,
            tier: .open,
            description: "List files and folders in Google Drive. Supports optional parent folder filter and pagination.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "parentId": .object([
                        "type": .string("string"),
                        "description": .string("ID of parent folder to list contents of. Omit for root/all files.")
                    ]),
                    "pageSize": .object([
                        "type": .string("integer"),
                        "description": .string("Number of files to return (default: 20, max: 100)")
                    ]),
                    "pageToken": .object([
                        "type": .string("string"),
                        "description": .string("Pagination token from a previous response")
                    ]),
                    "orderBy": .object([
                        "type": .string("string"),
                        "description": .string("Sort order (default: 'modifiedTime desc'). Options: name, modifiedTime, createdTime, folder")
                    ])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments else {
                    return .object(["error": .string("Invalid arguments")])
                }

                var parentId: String?
                if case .string(let v) = args["parentId"] { parentId = v }

                var pageSize = 20
                if case .int(let v) = args["pageSize"] { pageSize = v }

                var pageToken: String?
                if case .string(let v) = args["pageToken"] { pageToken = v }

                var orderBy = "modifiedTime desc"
                if case .string(let v) = args["orderBy"] { orderBy = v }

                let result = try await client.listFiles(
                    parentId: parentId,
                    pageSize: pageSize,
                    pageToken: pageToken,
                    orderBy: orderBy
                )
                return formatFileList(result)
            }
        ))

        // MARK: C3 — gdrive_search (🟢 open)

        await router.register(ToolRegistration(
            name: "gdrive_search",
            module: moduleName,
            tier: .open,
            description: "Full-text search across Google Drive files. Supports MIME type and date filters.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Search query text")
                    ]),
                    "mimeType": .object([
                        "type": .string("string"),
                        "description": .string("Filter by MIME type (e.g. 'application/pdf', 'application/vnd.google-apps.document')")
                    ]),
                    "modifiedAfter": .object([
                        "type": .string("string"),
                        "description": .string("Only files modified after this ISO 8601 datetime (e.g. '2024-01-01T00:00:00Z')")
                    ]),
                    "pageSize": .object([
                        "type": .string("integer"),
                        "description": .string("Number of results to return (default: 20, max: 100)")
                    ]),
                    "pageToken": .object([
                        "type": .string("string"),
                        "description": .string("Pagination token from a previous response")
                    ])
                ]),
                "required": .array([.string("query")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let query) = args["query"] else {
                    return .object(["error": .string("Missing required parameter: query")])
                }

                var mimeType: String?
                if case .string(let v) = args["mimeType"] { mimeType = v }

                var modifiedAfter: String?
                if case .string(let v) = args["modifiedAfter"] { modifiedAfter = v }

                var pageSize = 20
                if case .int(let v) = args["pageSize"] { pageSize = v }

                var pageToken: String?
                if case .string(let v) = args["pageToken"] { pageToken = v }

                let result = try await client.searchFiles(
                    query: query,
                    mimeType: mimeType,
                    modifiedAfter: modifiedAfter,
                    pageSize: pageSize,
                    pageToken: pageToken
                )
                return formatFileList(result)
            }
        ))

        // MARK: C4 — gdrive_read (🟢 open)

        await router.register(ToolRegistration(
            name: "gdrive_read",
            module: moduleName,
            tier: .open,
            description: "Read file content from Google Drive. Google Docs → plain text, Sheets → CSV, other files → raw content (≤10MB).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "fileId": .object([
                        "type": .string("string"),
                        "description": .string("The ID of the file to read")
                    ])
                ]),
                "required": .array([.string("fileId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let fileId) = args["fileId"] else {
                    return .object(["error": .string("Missing required parameter: fileId")])
                }

                let (content, mimeType) = try await client.readFileContent(fileId: fileId)
                return .object([
                    "content": .string(content),
                    "mimeType": .string(mimeType)
                ])
            }
        ))

        // MARK: C5 — gdrive_download (🟡 notify)

        await router.register(ToolRegistration(
            name: "gdrive_download",
            module: moduleName,
            tier: .notify,
            description: "Download a file from Google Drive to a local path. Google Workspace files are exported (Docs/Slides → PDF, Sheets → CSV). Max 10MB.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "fileId": .object([
                        "type": .string("string"),
                        "description": .string("The ID of the file to download")
                    ]),
                    "destinationPath": .object([
                        "type": .string("string"),
                        "description": .string("Local file path or directory to save to. If a directory, the original filename is used.")
                    ])
                ]),
                "required": .array([.string("fileId"), .string("destinationPath")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let fileId) = args["fileId"],
                      case .string(let destinationPath) = args["destinationPath"] else {
                    return .object(["error": .string("Missing required parameters: fileId, destinationPath")])
                }

                let (path, size) = try await client.downloadFile(fileId: fileId, destinationPath: destinationPath)
                return .object([
                    "path": .string(path),
                    "size": .int(Int(size)),
                    "message": .string("Downloaded to \(path) (\(formatBytes(size)))")
                ])
            }
        ))

        // MARK: C6 — gdrive_upload (🟠 notify)

        await router.register(ToolRegistration(
            name: "gdrive_upload",
            module: moduleName,
            tier: .notify,
            description: "Upload a local file to Google Drive (single-part, ≤10MB). Requires confirmation via SecurityGate notification.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "localPath": .object([
                        "type": .string("string"),
                        "description": .string("Absolute path to the local file to upload")
                    ]),
                    "parentId": .object([
                        "type": .string("string"),
                        "description": .string("ID of the Drive folder to upload into. Omit for root.")
                    ]),
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Name for the uploaded file in Drive. Defaults to local filename.")
                    ])
                ]),
                "required": .array([.string("localPath")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let localPath) = args["localPath"] else {
                    return .object(["error": .string("Missing required parameter: localPath")])
                }

                var parentId: String?
                if case .string(let v) = args["parentId"] { parentId = v }

                var name: String?
                if case .string(let v) = args["name"] { name = v }

                let file = try await client.uploadFile(
                    localPath: localPath,
                    parentId: parentId,
                    name: name
                )
                return formatFile(file, detail: true)
            }
        ))

        // MARK: C7 — gdrive_metadata (🟢 open)

        await router.register(ToolRegistration(
            name: "gdrive_metadata",
            module: moduleName,
            tier: .open,
            description: "Get detailed metadata for a Google Drive file: name, size, MIME type, modified date, sharing status, and permissions.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "fileId": .object([
                        "type": .string("string"),
                        "description": .string("The ID of the file to get metadata for")
                    ])
                ]),
                "required": .array([.string("fileId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let fileId) = args["fileId"] else {
                    return .object(["error": .string("Missing required parameter: fileId")])
                }

                let file = try await client.getFileMetadata(fileId: fileId)
                return formatFile(file, detail: true)
            }
        ))
    }

    // MARK: - Response Formatting

    /// Format a paginated file list for MCP response.
    private static func formatFileList(_ list: DriveFileList) -> Value {
        var result: [String: Value] = [
            "fileCount": .int(list.files.count)
        ]
        if let nextPageToken = list.nextPageToken {
            result["nextPageToken"] = .string(nextPageToken)
            result["hasMore"] = .bool(true)
        } else {
            result["hasMore"] = .bool(false)
        }
        result["files"] = .array(list.files.map { formatFile($0, detail: false) })
        return .object(result)
    }

    /// Format a single file for MCP response.
    /// - Parameter detail: If true, includes all metadata fields (permissions, owners, etc.)
    private static func formatFile(_ file: DriveFile, detail: Bool) -> Value {
        var obj: [String: Value] = [
            "id": .string(file.id),
            "name": .string(file.name),
            "mimeType": .string(file.mimeType),
            "isFolder": .bool(file.isFolder)
        ]

        if let size = file.size { obj["size"] = .string(size) }
        if let modified = file.modifiedTime { obj["modifiedTime"] = .string(modified) }
        if let link = file.webViewLink { obj["webViewLink"] = .string(link) }

        if detail {
            if let created = file.createdTime { obj["createdTime"] = .string(created) }
            if let parents = file.parents { obj["parents"] = .array(parents.map { .string($0) }) }
            if let trashed = file.trashed { obj["trashed"] = .bool(trashed) }
            if let starred = file.starred { obj["starred"] = .bool(starred) }
            if let shared = file.shared { obj["shared"] = .bool(shared) }
            if let desc = file.description { obj["description"] = .string(desc) }
            if let link = file.webContentLink { obj["webContentLink"] = .string(link) }

            if let owners = file.owners {
                obj["owners"] = .array(owners.map { owner in
                    var o: [String: Value] = [:]
                    if let name = owner.displayName { o["displayName"] = .string(name) }
                    if let email = owner.emailAddress { o["emailAddress"] = .string(email) }
                    return .object(o)
                })
            }

            if let perms = file.permissions {
                obj["permissions"] = .array(perms.map { perm in
                    var p: [String: Value] = [
                        "type": .string(perm.type),
                        "role": .string(perm.role)
                    ]
                    if let id = perm.id { p["id"] = .string(id) }
                    if let email = perm.emailAddress { p["emailAddress"] = .string(email) }
                    if let name = perm.displayName { p["displayName"] = .string(name) }
                    return .object(p)
                })
            }
        }

        return .object(obj)
    }

    /// Human-readable byte size formatting.
    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
    }
}
