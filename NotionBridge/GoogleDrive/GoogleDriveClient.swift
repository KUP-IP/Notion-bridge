// GoogleDriveClient.swift — Google Drive API v3 Client
// NotionBridge · GoogleDrive
// PKT-368: OAuth2 token management, URLSession-based, 10 req/sec rate limiting
//
// Token resolution: GOOGLE_DRIVE_TOKEN env var → config.json fallback
// Manual token paste for now (like Notion pre-V3); browser OAuth deferred to V3.

import Foundation

// MARK: - Token Resolution

/// Resolves the Google Drive OAuth2 token from environment or config file.
public enum GoogleDriveTokenResolver {

    /// V3-QUALITY A1: Delegates to ConfigManager (eliminates config split-brain).
    @available(*, deprecated, message: "Use ConfigManager.shared.googleDriveToken directly")
    private static let configFilePath: String = ConfigManager.shared.configFileURL.path

    /// Resolve the OAuth2 token from all sources.
    /// Priority: GOOGLE_DRIVE_TOKEN env → config file
    public static func resolve() -> (token: String, source: String)? {
        print("[GDriveTokenResolver] Starting token resolution...")

        // 0. Keychain (V3-QUALITY B2: primary secure storage)
        if let token = KeychainManager.shared.read(key: KeychainManager.Key.googleDriveToken),
           !token.isEmpty {
            print("[GDriveTokenResolver] ✅ Found token via Keychain")
            return (token, "keychain:google_drive_token")
        }
        print("[GDriveTokenResolver] Keychain — no token stored")

        // 1. Environment variable
        if let token = ProcessInfo.processInfo.environment["GOOGLE_DRIVE_TOKEN"],
           !token.isEmpty {
            print("[GDriveTokenResolver] ✅ Found token via env:GOOGLE_DRIVE_TOKEN")
            return (token, "env:GOOGLE_DRIVE_TOKEN")
        }
        print("[GDriveTokenResolver] env:GOOGLE_DRIVE_TOKEN — not set or empty")

        // 2. Config file fallback — V3-QUALITY A1: via ConfigManager
        if let token = ConfigManager.shared.googleDriveToken, !token.isEmpty {
            print("[GDriveTokenResolver] ✅ Found token via ConfigManager:google_drive_token")
            return (token, "config:google_drive_token")
        }
        print("[GDriveTokenResolver] ⚠️ No token found in ConfigManager")
        return nil
    }

    /// Check whether any token is configured (fast, no network).
    public static var isConfigured: Bool {
        resolve() != nil
    }
}

// MARK: - Google Drive Client

/// Actor-based Google Drive API client with rate limiting and OAuth2 token management.
/// Rate limit: 10 req/sec via ContinuousClock throttle.
public actor GoogleDriveClient {

    // MARK: - Constants

    private static let baseURL = "https://www.googleapis.com/drive/v3"
    private static let uploadURL = "https://www.googleapis.com/upload/drive/v3"
    private static let maxDownloadSize: Int64 = 10_485_760  // 10 MB
    private static let maxUploadSize: Int64 = 10_485_760    // 10 MB

    /// Standard fields to request for file metadata.
    private static let defaultFileFields =
        "id,name,mimeType,size,createdTime,modifiedTime,parents,webViewLink," +
        "webContentLink,iconLink,owners(displayName,emailAddress)," +
        "permissions(id,type,role,emailAddress,displayName),trashed,starred,shared,description"

    // MARK: - Rate Limiting

    private let clock = ContinuousClock()
    private var lastRequestTime: ContinuousClock.Instant?
    private let minRequestInterval: Duration = .milliseconds(100)  // 10 req/sec

    // MARK: - Session

    private let session: URLSession

    // MARK: - Singleton

    public static let shared = GoogleDriveClient()

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    // MARK: - Token Resolution

    private func resolveToken() throws -> String {
        guard let resolved = GoogleDriveTokenResolver.resolve() else {
            throw GoogleDriveClientError.noToken
        }
        return resolved.token
    }

    // MARK: - Rate Limiting

    private func throttle() async {
        if let last = lastRequestTime {
            let elapsed = clock.now - last
            if elapsed < minRequestInterval {
                try? await clock.sleep(for: minRequestInterval - elapsed)
            }
        }
        lastRequestTime = clock.now
    }

    // MARK: - HTTP Helpers

    private func makeRequest(
        url: String,
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        await throttle()
        let token = try resolveToken()

        guard let requestURL = URL(string: url) else {
            throw GoogleDriveClientError.networkError("Invalid URL: \(url)")
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let contentType = contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GoogleDriveClientError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleDriveClientError.networkError("Invalid response type")
        }

        if httpResponse.statusCode == 404 {
            let fileId = url.components(separatedBy: "/files/").last?
                .components(separatedBy: "?").first ?? "unknown"
            throw GoogleDriveClientError.fileNotFound(fileId: fileId)
        }

        if httpResponse.statusCode < 200 || httpResponse.statusCode >= 300 {
            if let apiError = try? JSONDecoder().decode(DriveAPIError.self, from: data) {
                throw GoogleDriveClientError.invalidResponse(
                    statusCode: httpResponse.statusCode,
                    message: apiError.error.message
                )
            }
            let bodyStr = String(data: data, encoding: .utf8) ?? "(binary data)"
            throw GoogleDriveClientError.invalidResponse(
                statusCode: httpResponse.statusCode,
                message: bodyStr
            )
        }

        return (data, httpResponse)
    }

    // MARK: - API Methods

    /// List files in Google Drive with optional parent folder filter and pagination.
    public func listFiles(
        parentId: String? = nil,
        pageSize: Int = 20,
        pageToken: String? = nil,
        orderBy: String = "modifiedTime desc",
        includeTrash: Bool = false
    ) async throws -> DriveFileList {
        var queryParts: [String] = []
        if !includeTrash {
            queryParts.append("trashed = false")
        }
        if let parentId = parentId {
            queryParts.append("'\(parentId)' in parents")
        }

        var params: [String] = [
            "pageSize=\(min(pageSize, 100))",
            "orderBy=\(orderBy.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? orderBy)",
            "fields=nextPageToken,incompleteSearch,files(\(Self.defaultFileFields))"
        ]
        if !queryParts.isEmpty {
            let q = queryParts.joined(separator: " and ")
            params.append("q=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)")
        }
        if let pageToken = pageToken {
            params.append("pageToken=\(pageToken)")
        }

        let url = "\(Self.baseURL)/files?\(params.joined(separator: "&"))"
        let (data, _) = try await makeRequest(url: url)

        do {
            return try JSONDecoder().decode(DriveFileList.self, from: data)
        } catch {
            throw GoogleDriveClientError.decodingError(error.localizedDescription)
        }
    }

    /// Full-text search across Drive files with optional MIME type and date filters.
    public func searchFiles(
        query: String,
        mimeType: String? = nil,
        modifiedAfter: String? = nil,
        pageSize: Int = 20,
        pageToken: String? = nil
    ) async throws -> DriveFileList {
        var queryParts: [String] = [
            "trashed = false",
            "fullText contains '\(query.replacingOccurrences(of: "'", with: "\\'"))'"
        ]
        if let mimeType = mimeType {
            queryParts.append("mimeType = '\(mimeType)'")
        }
        if let modifiedAfter = modifiedAfter {
            queryParts.append("modifiedTime > '\(modifiedAfter)'")
        }

        let q = queryParts.joined(separator: " and ")
        var params: [String] = [
            "pageSize=\(min(pageSize, 100))",
            "q=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)",
            "fields=nextPageToken,incompleteSearch,files(\(Self.defaultFileFields))"
        ]
        if let pageToken = pageToken {
            params.append("pageToken=\(pageToken)")
        }

        let url = "\(Self.baseURL)/files?\(params.joined(separator: "&"))"
        let (data, _) = try await makeRequest(url: url)

        do {
            return try JSONDecoder().decode(DriveFileList.self, from: data)
        } catch {
            throw GoogleDriveClientError.decodingError(error.localizedDescription)
        }
    }

    /// Read file content — exports Google Workspace docs, reads other files directly (≤10MB).
    /// Google Docs → plain text, Sheets → CSV, Slides → plain text, Drawings → SVG.
    public func readFileContent(fileId: String) async throws -> (content: String, mimeType: String) {
        let file = try await getFileMetadata(fileId: fileId)

        let exportMimeMap: [String: String] = [
            "application/vnd.google-apps.document": "text/plain",
            "application/vnd.google-apps.spreadsheet": "text/csv",
            "application/vnd.google-apps.presentation": "text/plain",
            "application/vnd.google-apps.drawing": "image/svg+xml"
        ]

        if file.isGoogleWorkspace {
            guard let exportMime = exportMimeMap[file.mimeType] else {
                throw GoogleDriveClientError.exportNotSupported(mimeType: file.mimeType)
            }
            let encodedMime = exportMime.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? exportMime
            let url = "\(Self.baseURL)/files/\(fileId)/export?mimeType=\(encodedMime)"
            let (data, _) = try await makeRequest(url: url)
            let content = String(data: data, encoding: .utf8) ?? "(binary content, \(data.count) bytes)"
            return (content, exportMime)
        } else {
            if let sizeStr = file.size, let size = Int64(sizeStr), size > Self.maxDownloadSize {
                throw GoogleDriveClientError.fileTooLarge(size: size, maxSize: Self.maxDownloadSize)
            }
            let url = "\(Self.baseURL)/files/\(fileId)?alt=media"
            let (data, _) = try await makeRequest(url: url)
            let content = String(data: data, encoding: .utf8) ?? "(binary content, \(data.count) bytes)"
            return (content, file.mimeType)
        }
    }

    /// Download a file to a local path (≤10MB). Google Workspace files are exported
    /// (Docs/Slides → PDF, Sheets → CSV, Drawings → PNG).
    public func downloadFile(fileId: String, destinationPath: String) async throws -> (path: String, size: Int64) {
        let file = try await getFileMetadata(fileId: fileId)

        let exportMimeMap: [String: String] = [
            "application/vnd.google-apps.document": "application/pdf",
            "application/vnd.google-apps.spreadsheet": "text/csv",
            "application/vnd.google-apps.presentation": "application/pdf",
            "application/vnd.google-apps.drawing": "image/png"
        ]

        let downloadURL: String
        if file.isGoogleWorkspace {
            guard let exportMime = exportMimeMap[file.mimeType] else {
                throw GoogleDriveClientError.exportNotSupported(mimeType: file.mimeType)
            }
            let encodedMime = exportMime.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? exportMime
            downloadURL = "\(Self.baseURL)/files/\(fileId)/export?mimeType=\(encodedMime)"
        } else {
            if let sizeStr = file.size, let size = Int64(sizeStr), size > Self.maxDownloadSize {
                throw GoogleDriveClientError.fileTooLarge(size: size, maxSize: Self.maxDownloadSize)
            }
            downloadURL = "\(Self.baseURL)/files/\(fileId)?alt=media"
        }

        let (data, _) = try await makeRequest(url: downloadURL)

        // Resolve destination — if directory, append filename
        var finalPath = destinationPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: destinationPath, isDirectory: &isDir), isDir.boolValue {
            finalPath = (destinationPath as NSString).appendingPathComponent(file.name)
        }

        // Create parent directories if needed
        let parentDir = (finalPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        try data.write(to: URL(fileURLWithPath: finalPath))
        return (finalPath, Int64(data.count))
    }

    /// Upload a local file to Google Drive (single-part multipart/related, ≤10MB).
    public func uploadFile(
        localPath: String,
        parentId: String? = nil,
        name: String? = nil
    ) async throws -> DriveFile {
        let fileURL = URL(fileURLWithPath: localPath)
        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            throw GoogleDriveClientError.uploadFailed("Cannot read file: \(error.localizedDescription)")
        }

        guard Int64(fileData.count) <= Self.maxUploadSize else {
            throw GoogleDriveClientError.fileTooLarge(
                size: Int64(fileData.count),
                maxSize: Self.maxUploadSize
            )
        }

        let fileName = name ?? fileURL.lastPathComponent
        let fileMimeType = Self.mimeType(for: fileURL.pathExtension)

        // Build multipart/related upload body
        let boundary = UUID().uuidString
        var multipart = Data()

        // Part 1: JSON metadata
        var metadata: [String: Any] = ["name": fileName]
        if let parentId = parentId {
            metadata["parents"] = [parentId]
        }
        let metadataJSON = try JSONSerialization.data(withJSONObject: metadata)

        multipart.append("--\(boundary)\r\n".data(using: .utf8)!)
        multipart.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        multipart.append(metadataJSON)
        multipart.append("\r\n".data(using: .utf8)!)

        // Part 2: File content
        multipart.append("--\(boundary)\r\n".data(using: .utf8)!)
        multipart.append("Content-Type: \(fileMimeType)\r\n\r\n".data(using: .utf8)!)
        multipart.append(fileData)
        multipart.append("\r\n".data(using: .utf8)!)
        multipart.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let url = "\(Self.uploadURL)/files?uploadType=multipart&fields=\(Self.defaultFileFields)"
        let (responseData, _) = try await makeRequest(
            url: url,
            method: "POST",
            body: multipart,
            contentType: "multipart/related; boundary=\(boundary)"
        )

        do {
            return try JSONDecoder().decode(DriveFile.self, from: responseData)
        } catch {
            throw GoogleDriveClientError.decodingError(error.localizedDescription)
        }
    }

    /// Get detailed metadata for a single file.
    public func getFileMetadata(fileId: String) async throws -> DriveFile {
        let url = "\(Self.baseURL)/files/\(fileId)?fields=\(Self.defaultFileFields)"
        let (data, _) = try await makeRequest(url: url)

        do {
            return try JSONDecoder().decode(DriveFile.self, from: data)
        } catch {
            throw GoogleDriveClientError.decodingError(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    /// Basic MIME type lookup from file extension.
    private static func mimeType(for ext: String) -> String {
        let map: [String: String] = [
            "txt": "text/plain", "html": "text/html", "css": "text/css",
            "js": "application/javascript", "json": "application/json",
            "xml": "application/xml", "csv": "text/csv", "md": "text/markdown",
            "pdf": "application/pdf", "png": "image/png", "jpg": "image/jpeg",
            "jpeg": "image/jpeg", "gif": "image/gif", "svg": "image/svg+xml",
            "mp4": "video/mp4", "mp3": "audio/mpeg", "zip": "application/zip",
            "doc": "application/msword",
            "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "xls": "application/vnd.ms-excel",
            "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "ppt": "application/vnd.ms-powerpoint",
            "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "swift": "text/x-swift", "py": "text/x-python",
        ]
        return map[ext.lowercased()] ?? "application/octet-stream"
    }
}
