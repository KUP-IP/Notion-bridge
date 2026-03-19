// GoogleDriveModels.swift — Google Drive API Response Models
// NotionBridge · GoogleDrive
// PKT-368: Codable models for Drive API v3 responses

import Foundation

// MARK: - API Response Models

/// Represents a file or folder in Google Drive.
public struct DriveFile: Codable, Sendable {
    public let id: String
    public let name: String
    public let mimeType: String
    public let size: String?
    public let createdTime: String?
    public let modifiedTime: String?
    public let parents: [String]?
    public let webViewLink: String?
    public let webContentLink: String?
    public let iconLink: String?
    public let owners: [DriveUser]?
    public let permissions: [DrivePermission]?
    public let trashed: Bool?
    public let starred: Bool?
    public let shared: Bool?
    public let description: String?

    /// Whether this item is a folder.
    public var isFolder: Bool {
        mimeType == "application/vnd.google-apps.folder"
    }

    /// Whether this is a Google Workspace document (Docs, Sheets, Slides, etc.).
    public var isGoogleWorkspace: Bool {
        mimeType.hasPrefix("application/vnd.google-apps.")
    }
}

/// Paginated list of Drive files.
public struct DriveFileList: Codable, Sendable {
    public let files: [DriveFile]
    public let nextPageToken: String?
    public let incompleteSearch: Bool?
}

/// A user reference in Drive (owner, sharing target).
public struct DriveUser: Codable, Sendable {
    public let displayName: String?
    public let emailAddress: String?
    public let photoLink: String?
}

/// Sharing permission on a Drive file.
public struct DrivePermission: Codable, Sendable {
    public let id: String?
    public let type: String       // "user", "group", "domain", "anyone"
    public let role: String       // "owner", "organizer", "writer", "commenter", "reader"
    public let emailAddress: String?
    public let displayName: String?
}

/// Google Drive API error response envelope.
public struct DriveAPIError: Codable, Sendable {
    public let error: DriveErrorBody

    public struct DriveErrorBody: Codable, Sendable {
        public let code: Int
        public let message: String
        public let errors: [DriveErrorDetail]?
    }

    public struct DriveErrorDetail: Codable, Sendable {
        public let domain: String?
        public let reason: String?
        public let message: String?
    }
}

// MARK: - Client Errors

public enum GoogleDriveClientError: Error, LocalizedError, Sendable {
    case noToken
    case invalidResponse(statusCode: Int, message: String)
    case fileTooLarge(size: Int64, maxSize: Int64)
    case fileNotFound(fileId: String)
    case exportNotSupported(mimeType: String)
    case networkError(String)
    case decodingError(String)
    case uploadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noToken:
            return "No Google Drive token configured. Set GOOGLE_DRIVE_TOKEN env var or add 'google_drive_token' to config.json."
        case .invalidResponse(let code, let message):
            return "Drive API error (\(code)): \(message)"
        case .fileTooLarge(let size, let maxSize):
            return "File size \(size) bytes exceeds maximum \(maxSize) bytes."
        case .fileNotFound(let fileId):
            return "File not found: \(fileId)"
        case .exportNotSupported(let mimeType):
            return "Export not supported for MIME type: \(mimeType)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .decodingError(let message):
            return "Failed to decode response: \(message)"
        case .uploadFailed(let message):
            return "Upload failed: \(message)"
        }
    }
}
