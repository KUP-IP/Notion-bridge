// SkillsModule.swift — fetch_skill MCP Tool
// NotionBridge · Modules
// PKT-366 F10: Registers `fetch_skill` at .open tier.
// Looks up skill name in config → NotionClient.getPage() + getBlocks() → returns text.
// Session-level cache with 10-minute TTL.
// 403 handling: structured error + "Access Lost" badge.

import Foundation
import MCP

// MARK: - Skill Cache

/// Cache entry for a fetched skill page.
private struct CachedSkill: Sendable {
    let content: Value
    let fetchedAt: Date

    var isExpired: Bool {
        Date().timeIntervalSince(fetchedAt) > 600 // 10-minute TTL
    }
}

/// Thread-safe actor cache for fetched skill content.
private actor SkillCache {
    private var cache: [String: CachedSkill] = [:]

    func get(_ key: String) -> Value? {
        guard let entry = cache[key], !entry.isExpired else {
            cache.removeValue(forKey: key)
            return nil
        }
        return entry.content
    }

    func set(_ key: String, content: Value) {
        cache[key] = CachedSkill(content: content, fetchedAt: Date())
    }
}

// MARK: - SkillsModule

/// Provides the `fetch_skill` MCP tool for runtime Notion page injection.
/// Skills are configured via SkillsManager (Settings → Skills tab) and
/// persisted in UserDefaults under `com.notionbridge.skills`.
public enum SkillsModule {

    public static let moduleName = "skills"

    /// Register the `fetch_skill` tool on the given router.
    public static func register(on router: ToolRouter) async {

        let cache = SkillCache()

        // fetch_skill — open tier
        await router.register(ToolRegistration(
            name: "fetch_skill",
            module: moduleName,
            tier: .open,
            description: "Fetch a named skill (Notion page) by name. Returns the page title, properties, and block content as text. Skills are configured in Settings \u{2192} Skills. Results are cached for 10 minutes.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Name of the skill to fetch (case-insensitive). Must match a configured skill name.")
                    ])
                ]),
                "required": .array([.string("name")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let name) = args["name"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "fetch_skill",
                        reason: "missing required 'name' parameter"
                    )
                }

                let cacheKey = name.lowercased()

                // Check cache first
                if let cached = await cache.get(cacheKey) {
                    return cached
                }

                // Look up skill in UserDefaults config
                guard let skillConfig = lookupSkill(named: name) else {
                    return .object([
                        "error": .string("Skill not found: '\(name)'"),
                        "hint": .string("Configure skills in Settings \u{2192} Skills tab."),
                        "availableSkills": .array(
                            listAvailableSkillNames().map { .string($0) }
                        )
                    ])
                }

                guard skillConfig.enabled else {
                    return .object([
                        "error": .string("Skill '\(name)' is disabled."),
                        "hint": .string("Enable it in Settings \u{2192} Skills tab.")
                    ])
                }

                // Fetch from Notion API
                do {
                    let client = try NotionClient()
                    let pageId = skillConfig.notionPageId

                    // Fetch page properties
                    let pageData = try await client.getPage(pageId: pageId)
                    guard let pageJSON = try? JSONSerialization.jsonObject(with: pageData) as? [String: Any] else {
                        return .object(["error": .string("Failed to parse Notion page response")])
                    }

                    let url = pageJSON["url"] as? String ?? ""
                    var title = "Untitled"
                    if let properties = pageJSON["properties"] as? [String: Any] {
                        title = NotionJSON.extractTitle(from: properties)
                    }

                    // Fetch child blocks
                    let blocksData = try await client.getBlocks(blockId: pageId)
                    guard let blocksJSON = try? JSONSerialization.jsonObject(with: blocksData) as? [String: Any],
                          let blockResults = blocksJSON["results"] as? [[String: Any]] else {
                        let result: Value = .object([
                            "name": .string(skillConfig.name),
                            "title": .string(title),
                            "url": .string(url),
                            "content": .string("(no blocks)")
                        ])
                        await cache.set(cacheKey, content: result)
                        return result
                    }

                    // Extract text content from blocks
                    var textParts: [String] = []
                    for block in blockResults {
                        let blockType = block["type"] as? String ?? ""
                        if let typeData = block[blockType] as? [String: Any],
                           let richText = typeData["rich_text"] as? [[String: Any]] {
                            let text = richText.compactMap { $0["plain_text"] as? String }.joined()
                            if !text.isEmpty {
                                textParts.append(text)
                            }
                        }
                    }

                    let result: Value = .object([
                        "name": .string(skillConfig.name),
                        "title": .string(title),
                        "url": .string(url),
                        "blockCount": .int(blockResults.count),
                        "content": .string(textParts.joined(separator: "\n"))
                    ])

                    await cache.set(cacheKey, content: result)
                    return result

                } catch let error as NotionClientError {
                    // F10: 403 handling — structured error + "Access Lost" badge
                    if case .httpError(let code, let msg) = error, code == 403 {
                        return .object([
                            "error": .string("Access Lost"),
                            "status": .int(403),
                            "skill": .string(name),
                            "detail": .string("The Notion integration no longer has access to this page. Re-share the page with your integration."),
                            "raw": .string(msg)
                        ])
                    }
                    return .object([
                        "error": .string("Notion API error"),
                        "detail": .string(error.localizedDescription)
                    ])
                } catch {
                    return .object([
                        "error": .string("Failed to fetch skill"),
                        "detail": .string(error.localizedDescription)
                    ])
                }
            }
        ))
    }

    // MARK: - Config Helpers

    /// Lightweight Codable struct matching SkillsManager.Skill layout.
    /// Used to read directly from UserDefaults without requiring @MainActor.
    private struct SkillConfig: Codable {
        let name: String
        let notionPageId: String
        let enabled: Bool
    }

    /// Look up a skill from UserDefaults by name (case-insensitive).
    private static func lookupSkill(named name: String) -> SkillConfig? {
        guard let data = UserDefaults.standard.data(forKey: "com.notionbridge.skills"),
              let skills = try? JSONDecoder().decode([SkillConfig].self, from: data) else {
            return nil
        }
        return skills.first { $0.name.lowercased() == name.lowercased() }
    }

    /// List all configured skill names.
    private static func listAvailableSkillNames() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: "com.notionbridge.skills"),
              let skills = try? JSONDecoder().decode([SkillConfig].self, from: data) else {
            return []
        }
        return skills.map(\.name)
    }
}
