// NotionModels.swift – V1-05 → V1-12 Notion API Type Definitions
// NotionGate · Notion
//
// Minimal models for Notion REST API integration.
// Covers Page and Block types needed by NotionModule.
// PKT-320: Updated error messages to reference NOTION_API_TOKEN

import Foundation

// MARK: - Notion API Error

/// Error type for Notion API operations.
public enum NotionClientError: Error, LocalizedError, Sendable {
    case missingAPIKey
    case invalidResponse
    case maxRetriesExceeded
    case httpError(Int, String)
    case decodingError(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Notion API token not found. Set NOTION_API_TOKEN environment variable or add token to ~/.config/notion-gate/config.json"
        case .invalidResponse:
            return "Invalid HTTP response"
        case .maxRetriesExceeded:
            return "Max retries exceeded"
        case .httpError(let code, let body):
            return "HTTP \(code): \(String(body.prefix(500)))"
        case .decodingError(let msg):
            return "Decoding error: \(msg)"
        }
    }
}

// MARK: - Notion Page (Minimal)

/// Lightweight Notion page representation.
public struct NotionPage: Sendable {
    public let id: String
    public let url: String
    public let title: String
    public let properties: String // raw JSON string

    public init(id: String, url: String, title: String, properties: String) {
        self.id = id
        self.url = url
        self.title = title
        self.properties = properties
    }
}

// MARK: - Notion Block (Minimal)

/// Lightweight Notion block representation.
public struct NotionBlock: Sendable {
    public let id: String
    public let type: String
    public let hasChildren: Bool
    public let content: String // raw JSON string

    public init(id: String, type: String, hasChildren: Bool, content: String) {
        self.id = id
        self.type = type
        self.hasChildren = hasChildren
        self.content = content
    }
}

// MARK: - Notion Search Result

/// A search result from the Notion API.
public struct NotionSearchResult: Sendable {
    public let id: String
    public let objectType: String // "page" or "database"
    public let title: String
    public let url: String

    public init(id: String, objectType: String, title: String, url: String) {
        self.id = id
        self.objectType = objectType
        self.title = title
        self.url = url
    }
}

// MARK: - JSON Helpers

/// Utility to convert JSONSerialization output to a dictionary string.
public enum NotionJSON {

    /// Extract a title from Notion page properties JSON.
    public static func extractTitle(from properties: [String: Any]) -> String {
        for (_, value) in properties {
            guard let prop = value as? [String: Any],
                  let propType = prop["type"] as? String,
                  propType == "title",
                  let titleArr = prop["title"] as? [[String: Any]] else {
                continue
            }
            let parts = titleArr.compactMap { item -> String? in
                return item["plain_text"] as? String
            }
            if !parts.isEmpty {
                return parts.joined()
            }
        }
        return "Untitled"
    }

    /// Pretty-print a JSON object to string.
    public static func prettyPrint(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
        ) else {
            return String(describing: obj)
        }
        return String(data: data, encoding: .utf8) ?? String(describing: obj)
    }
}
