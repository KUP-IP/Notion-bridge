// SkillNotionMetadata.swift — Notion property names + rich_text bridge fields for skills
// NotionBridge · Modules
//
// Canonical `rich_text` properties on each skill page (create in Notion if missing).
// MCP metadata in UserDefaults is authoritative; sync tools copy to/from these fields.

import Foundation

/// Fixed Notion database/page property names for Bridge ↔ MCP metadata sync.
public enum SkillBridgeNotionPropertyNames: Sendable {
    public static let summary = "Bridge Summary"
    public static let triggers = "Bridge Triggers"
    public static let antiTriggers = "Bridge Anti-triggers"
}

/// Encode/decode for PATCH page properties and GET page parse.
public enum SkillNotionMetadata: Sendable {

    /// Plain text from a top-level `rich_text` page property.
    public static func richTextPlain(propertyName: String, properties: [String: Any]) -> String {
        guard let prop = properties[propertyName] as? [String: Any],
              (prop["type"] as? String) == "rich_text",
              let rt = prop["rich_text"] as? [[String: Any]] else {
            return ""
        }
        return NotionJSON.extractPlainText(from: rt)
    }

    /// One phrase per line when stored in Notion.
    public static func phrasesFromStoredText(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// JSON body for `PATCH /v1/pages/{id}` — `{ "properties": { ... } }`.
    public static func buildPagePropertiesPatchData(
        summary: String,
        triggerPhrases: [String],
        antiTriggerPhrases: [String]
    ) throws -> Data {
        let trigText = triggerPhrases.joined(separator: "\n")
        let antiText = antiTriggerPhrases.joined(separator: "\n")
        let props: [String: Any] = [
            SkillBridgeNotionPropertyNames.summary: richTextPropertyJSON(summary),
            SkillBridgeNotionPropertyNames.triggers: richTextPropertyJSON(trigText),
            SkillBridgeNotionPropertyNames.antiTriggers: richTextPropertyJSON(antiText)
        ]
        let body: [String: Any] = ["properties": props]
        return try JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - Private

    private static func richTextPropertyJSON(_ text: String) -> [String: Any] {
        if text.isEmpty {
            let empty: [[String: Any]] = []
            return ["rich_text": empty]
        }
        let chunks = chunkForNotionRichText(text)
        let arr: [[String: Any]] = chunks.map { chunk in
            ["type": "text", "text": ["content": chunk]]
        }
        return ["rich_text": arr]
    }

    /// Notion text content objects are limited to 2000 characters each.
    private static func chunkForNotionRichText(_ text: String, maxLen: Int = 2000) -> [String] {
        var out: [String] = []
        var rest = String(text)
        while !rest.isEmpty {
            let prefix = String(rest.prefix(maxLen))
            out.append(prefix)
            rest = String(rest.dropFirst(maxLen))
        }
        return out
    }
}
