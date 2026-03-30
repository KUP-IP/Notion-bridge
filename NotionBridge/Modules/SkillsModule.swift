// SkillsModule.swift — fetch_skill MCP Tool
// NotionBridge · Modules
// PKT-366 F10: Registers `fetch_skill` at .open tier.
// Looks up skill name in config → NotionClient page + collectBlocksDepthFirst → returns text.
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
            description: "Fetch a named skill by name (case-insensitive). Returns page title, URL, flattened block text (paginated + optional nested blocks), blockCount, truncated. Results cached 10 minutes. Configure skills in Settings",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Name of the skill to fetch (case-insensitive). Must match a configured skill name.")
                    ]),
                    "includeNested": .object([
                        "type": .string("boolean"),
                        "description": .string("Include nested blocks (toggles, lists). Default true for full skill content.")
                    ]),
                    "maxBlocks": .object([
                        "type": .string("number"),
                        "description": .string("Safety cap on total blocks collected (default 5000).")
                    ]),
                    "maxDepth": .object([
                        "type": .string("number"),
                        "description": .string("Max nesting depth from page (default 10).")
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

                let includeNested: Bool = {
                    if case .bool(let b) = args["includeNested"] { return b }
                    return true
                }()
                let maxBlocks: Int = {
                    if case .int(let n) = args["maxBlocks"], n > 0 { return n }
                    if case .double(let d) = args["maxBlocks"], d > 0 { return Int(d) }
                    return 5000
                }()
                let maxDepth: Int = {
                    if case .int(let n) = args["maxDepth"], n > 0 { return n }
                    if case .double(let d) = args["maxDepth"], d > 0 { return Int(d) }
                    return 10
                }()

                let cacheKey = "\(name.lowercased())|n=\(includeNested)|mb=\(maxBlocks)|md=\(maxDepth)"

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

                    let collected = try await client.collectBlocksDepthFirst(
                        rootBlockId: pageId,
                        includeNested: includeNested,
                        maxBlocks: maxBlocks,
                        maxDepth: maxDepth
                    )
                    let blockResults = collected.blocks
                    let truncated = collected.truncated
                    let truncationReason = collected.truncationReason

                    if blockResults.isEmpty {
                        let result: Value = .object([
                            "name": .string(skillConfig.name),
                            "title": .string(title),
                            "url": .string(url),
                            "blockCount": .int(0),
                            "truncated": .bool(false),
                            "content": .string("(no blocks)")
                        ])
                        await cache.set(cacheKey, content: result)
                        return result
                    }

                    var textParts: [String] = []
                    for block in blockResults {
                        let line = NotionJSON.extractPlainTextFromBlock(block)
                        if !line.isEmpty {
                            textParts.append(line)
                        }
                    }

                    var resultObj: [String: Value] = [
                        "name": .string(skillConfig.name),
                        "title": .string(title),
                        "url": .string(url),
                        "blockCount": .int(blockResults.count),
                        "truncated": .bool(truncated),
                        "content": .string(textParts.joined(separator: "\n"))
                    ]
                    if let r = truncationReason {
                        resultObj["truncationReason"] = .string(r)
                    }

                    let result: Value = .object(resultObj)
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

        await registerListRoutingSkills(on: router)

        // Register manage_skill tool (PKT-477 Feature 3)
        await registerManageSkill(on: router)
    }

    // MARK: - list_routing_skills

    private static func registerListRoutingSkills(on router: ToolRouter) async {
        await router.register(ToolRegistration(
            name: "list_routing_skills",
            module: moduleName,
            tier: .open,
            description: "List skills enabled for routing discovery: visibility routing, non-empty Notion page id. Does not fetch page bodies — use fetch_skill.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            handler: { _ in
                let skills = readAllSkills().filter {
                    $0.enabled && $0.visibility == .routing
                        && !$0.notionPageId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                let items: [Value] = skills.map { s in
                    .object([
                        "name": .string(s.name),
                        "notionPageId": .string(s.notionPageId)
                    ])
                }
                return .object([
                    "skills": .array(items),
                    "count": .int(skills.count)
                ])
            }
        ))
    }

    // MARK: - manage_skill Tool (PKT-477 Feature 3)

    /// Register the `manage_skill` tool on the given router.
    public static func registerManageSkill(on router: ToolRouter) async {

        await router.register(ToolRegistration(
            name: "manage_skill",
            module: moduleName,
            tier: .request, // was .orange — no such SecurityTier member
            description: "Manage the skills registry. Actions: list, add, delete, toggle, rename, update_url, set_visibility, bulk_add. Skills persist in Settings",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "action": .object([
                        "type": .string("string"),
                        "description": .string("Action: list, add, delete, toggle, rename, update_url, set_visibility, bulk_add"),
                        "enum": .array([
                            .string("list"), .string("add"), .string("delete"), .string("toggle"), .string("rename"),
                            .string("update_url"), .string("set_visibility"), .string("bulk_add")
                        ])
                    ]),
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Skill name (required for add, delete, toggle, rename, update_url)")
                    ]),
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("Notion page ID or URL (required for add, update_url)")
                    ]),
                    "newName": .object([
                        "type": .string("string"),
                        "description": .string("New name for rename action")
                    ]),
                    "visibility": .object([
                        "type": .string("string"),
                        "description": .string("SkillVisibility for add/set_visibility: routing | standard | adminOnly")
                    ]),
                    "skills": .object([
                        "type": .string("array"),
                        "description": .string("Array of {name, url} objects for bulk_add action"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "name": .object(["type": .string("string")]),
                                "url": .object(["type": .string("string")])
                            ])
                        ])
                    ])
                ]),
                "required": .array([.string("action")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let action) = args["action"] else {
                    throw ToolRouterError.invalidArguments(
                        toolName: "manage_skill",
                        reason: "missing required 'action' parameter"
                    )
                }

                switch action {
                case "list":
                    let skills = readAllSkills()
                    let items: [Value] = skills.map { skill in
                        .object([
                            "name": .string(skill.name),
                            "url": .string(skill.notionPageId),
                            "enabled": .bool(skill.enabled),
                            "visibility": .string(skill.visibility.rawValue)
                        ])
                    }
                    return .object([
                        "skills": .array(items),
                        "count": .int(skills.count)
                    ])

                case "add":
                    guard case .string(let name) = args["name"],
                          case .string(let url) = args["url"] else {
                        throw ToolRouterError.invalidArguments(
                            toolName: "manage_skill",
                            reason: "'add' requires 'name' and 'url' parameters"
                        )
                    }
                    let vis = parseVisibilityArg(args) ?? .standard
                    let success = writeAddSkill(name: name, pageId: url, visibility: vis)
                    return .object([
                        "success": .bool(success),
                        "action": .string("add"),
                        "name": .string(name),
                        "message": .string(success ? "Skill '\(name)' added." : "Failed — name may be empty or duplicate.")
                    ])

                case "delete":
                    guard case .string(let name) = args["name"] else {
                        throw ToolRouterError.invalidArguments(
                            toolName: "manage_skill",
                            reason: "'delete' requires 'name' parameter"
                        )
                    }
                    let success = writeDeleteSkill(named: name)
                    return .object([
                        "success": .bool(success),
                        "action": .string("delete"),
                        "name": .string(name),
                        "message": .string(success ? "Skill '\(name)' deleted." : "Skill '\(name)' not found.")
                    ])

                case "toggle":
                    guard case .string(let name) = args["name"] else {
                        throw ToolRouterError.invalidArguments(
                            toolName: "manage_skill",
                            reason: "'toggle' requires 'name' parameter"
                        )
                    }
                    let result = writeToggleSkill(named: name)
                    return .object([
                        "success": .bool(result.found),
                        "action": .string("toggle"),
                        "name": .string(name),
                        "enabled": .bool(result.newState),
                        "message": .string(result.found ? "Skill '\(name)' is now \(result.newState ? "enabled" : "disabled")." : "Skill '\(name)' not found.")
                    ])

                case "rename":
                    guard case .string(let name) = args["name"],
                          case .string(let newName) = args["newName"] else {
                        throw ToolRouterError.invalidArguments(
                            toolName: "manage_skill",
                            reason: "'rename' requires 'name' and 'newName' parameters"
                        )
                    }
                    let success = writeRenameSkill(named: name, to: newName)
                    return .object([
                        "success": .bool(success),
                        "action": .string("rename"),
                        "oldName": .string(name),
                        "newName": .string(newName),
                        "message": .string(success ? "Skill renamed '\(name)' → '\(newName)'." : "Failed — skill not found or name conflict.")
                    ])

                case "update_url":
                    guard case .string(let name) = args["name"],
                          case .string(let url) = args["url"] else {
                        throw ToolRouterError.invalidArguments(
                            toolName: "manage_skill",
                            reason: "'update_url' requires 'name' and 'url' parameters"
                        )
                    }
                    let success = writeUpdateSkillURL(named: name, newPageId: url)
                    return .object([
                        "success": .bool(success),
                        "action": .string("update_url"),
                        "name": .string(name),
                        "message": .string(success ? "Skill '\(name)' URL updated." : "Skill '\(name)' not found.")
                    ])

                case "set_visibility":
                    guard case .string(let name) = args["name"] else {
                        throw ToolRouterError.invalidArguments(
                            toolName: "manage_skill",
                            reason: "'set_visibility' requires 'name' and 'visibility' parameters"
                        )
                    }
                    guard let vis = parseVisibilityArg(args) else {
                        throw ToolRouterError.invalidArguments(
                            toolName: "manage_skill",
                            reason: "'set_visibility' requires valid visibility: routing, standard, or adminOnly"
                        )
                    }
                    let success = writeSetVisibility(named: name, visibility: vis)
                    return .object([
                        "success": .bool(success),
                        "action": .string("set_visibility"),
                        "name": .string(name),
                        "visibility": .string(vis.rawValue),
                        "message": .string(success ? "Skill '\(name)' visibility set to \(vis.rawValue)." : "Skill '\(name)' not found.")
                    ])

                case "bulk_add":
                    guard case .array(let skillsArray) = args["skills"] else {
                        throw ToolRouterError.invalidArguments(
                            toolName: "manage_skill",
                            reason: "'bulk_add' requires 'skills' array parameter"
                        )
                    }
                    var pairs: [(name: String, pageId: String)] = []
                    for item in skillsArray {
                        if case .object(let obj) = item,
                           case .string(let name) = obj["name"],
                           case .string(let url) = obj["url"] {
                            pairs.append((name: name, pageId: url))
                        }
                    }
                    let result = writeBulkAdd(skills: pairs)
                    return .object([
                        "action": .string("bulk_add"),
                        "added": .int(result.added),
                        "skipped": .int(result.skipped),
                        "total": .int(pairs.count),
                        "message": .string("Bulk add complete: \(result.added) added, \(result.skipped) skipped.")
                    ])

                default:
                    return .object([
                        "error": .string("Unknown action: '\(action)'"),
                        "hint": .string("Valid actions: list, add, delete, toggle, rename, update_url, set_visibility, bulk_add")
                    ])
                }
            }
        ))
    }

    // MARK: - UserDefaults Write Helpers (non-MainActor safe)

    /// Read all skills from UserDefaults (thread-safe).
    private static func readAllSkills() -> [SkillConfig] {
        guard let data = UserDefaults.standard.data(forKey: "com.notionbridge.skills"),
              let skills = try? JSONDecoder().decode([SkillConfig].self, from: data) else {
            return []
        }
        return skills
    }

    /// Write skills array back to UserDefaults.
    private static func writeSkills(_ skills: [SkillConfig]) {
        guard let data = try? JSONEncoder().encode(skills) else { return }
        UserDefaults.standard.set(data, forKey: "com.notionbridge.skills")
        NotificationCenter.default.post(name: .notionBridgeSkillsStorageDidChange, object: nil)
    }

    /// Add a skill via UserDefaults. Returns true on success.
    private static func writeAddSkill(name: String, pageId: String, visibility: SkillVisibility = .standard) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var skills = readAllSkills()
        guard !skills.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) else { return false }
        skills.append(SkillConfig(name: trimmed, notionPageId: pageId, enabled: true, visibility: visibility))
        writeSkills(skills)
        return true
    }

    private static func parseVisibilityArg(_ args: [String: Value]) -> SkillVisibility? {
        guard case .string(let raw) = args["visibility"] else { return nil }
        return SkillVisibility(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func writeSetVisibility(named name: String, visibility: SkillVisibility) -> Bool {
        var skills = readAllSkills()
        if let idx = skills.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            let s = skills[idx]
            skills[idx] = SkillConfig(name: s.name, notionPageId: s.notionPageId, enabled: s.enabled, visibility: visibility)
            writeSkills(skills)
            return true
        }
        return false
    }

    /// Delete a skill by name. Returns true if found and removed.
    private static func writeDeleteSkill(named name: String) -> Bool {
        var skills = readAllSkills()
        let before = skills.count
        skills.removeAll { $0.name.lowercased() == name.lowercased() }
        guard skills.count < before else { return false }
        writeSkills(skills)
        return true
    }

    /// Toggle a skill's enabled state. Returns (found, newState).
    private static func writeToggleSkill(named name: String) -> (found: Bool, newState: Bool) {
        var skills = readAllSkills()
        if let idx = skills.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            let s = skills[idx]
            skills[idx] = SkillConfig(name: s.name, notionPageId: s.notionPageId, enabled: !s.enabled, visibility: s.visibility)
            let newState = skills[idx].enabled
            writeSkills(skills)
            return (true, newState)
        }
        return (false, false)
    }

    /// Rename a skill. Returns true on success.
    private static func writeRenameSkill(named oldName: String, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var skills = readAllSkills()
        guard !skills.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) else { return false }
        if let idx = skills.firstIndex(where: { $0.name.lowercased() == oldName.lowercased() }) {
            let s = skills[idx]
            skills[idx] = SkillConfig(name: trimmed, notionPageId: s.notionPageId, enabled: s.enabled, visibility: s.visibility)
            writeSkills(skills)
            return true
        }
        return false
    }

    /// Update a skill's page ID. Returns true on success.
    private static func writeUpdateSkillURL(named name: String, newPageId: String) -> Bool {
        var skills = readAllSkills()
        if let idx = skills.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            let s = skills[idx]
            skills[idx] = SkillConfig(name: s.name, notionPageId: newPageId, enabled: s.enabled, visibility: s.visibility)
            writeSkills(skills)
            return true
        }
        return false
    }

    /// Bulk add skills. Returns (added, skipped) counts.
    private static func writeBulkAdd(skills newSkills: [(name: String, pageId: String)]) -> (added: Int, skipped: Int) {
        var existing = readAllSkills()
        var added = 0, skipped = 0
        for s in newSkills {
            let trimmed = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { skipped += 1; continue }
            if existing.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) {
                skipped += 1
            } else {
                existing.append(SkillConfig(name: trimmed, notionPageId: s.pageId, enabled: true, visibility: .standard))
                added += 1
            }
        }
        writeSkills(existing)
        return (added, skipped)
    }

    // MARK: - Config Helpers

    /// Lightweight Codable struct matching SkillsManager.Skill layout.
    /// Used to read directly from UserDefaults without requiring @MainActor.
    private struct SkillConfig: Codable {
        let name: String
        let notionPageId: String
        let enabled: Bool
        let visibility: SkillVisibility

        enum CodingKeys: String, CodingKey {
            case name, notionPageId, enabled, visibility
        }

        init(name: String, notionPageId: String, enabled: Bool, visibility: SkillVisibility = .standard) {
            self.name = name
            self.notionPageId = notionPageId
            self.enabled = enabled
            self.visibility = visibility
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            notionPageId = try c.decode(String.self, forKey: .notionPageId)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            visibility = try c.decodeIfPresent(SkillVisibility.self, forKey: .visibility) ?? .standard
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(notionPageId, forKey: .notionPageId)
            try c.encode(enabled, forKey: .enabled)
            try c.encode(visibility, forKey: .visibility)
        }
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
        return skills.filter(\.enabled).map(\.name) // Only enabled skills
    }
}
