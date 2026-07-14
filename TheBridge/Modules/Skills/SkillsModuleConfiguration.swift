// Extracted from SkillsModule.swift by PKT-1126. Pure decomposition; behavior unchanged.

import Foundation
import MCP

extension SkillsModule {
    // MARK: - UserDefaults Write Helpers (non-MainActor safe)

    /// Read all skills from UserDefaults (thread-safe).
    static func readAllSkills() -> [SkillConfig] {
        guard let data = UserDefaults.standard.data(forKey: BridgeDefaults.skills),
              let skills = try? JSONDecoder().decode([SkillConfig].self, from: data) else {
            return []
        }
        return skills
    }

    /// Write skills array back to UserDefaults.
    static func writeSkills(_ skills: [SkillConfig]) {
        guard let data = try? JSONEncoder().encode(skills) else { return }
        UserDefaults.standard.set(data, forKey: BridgeDefaults.skills)
        NotificationCenter.default.post(name: .notionBridgeSkillsStorageDidChange, object: nil)
    }

    /// Add a skill via UserDefaults. Returns true on success.
    static func writeAddSkill(name: String, pageId: String, visibility: SkillVisibility = .standard, url: String? = nil, platform: SkillPlatform = .notion) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var skills = readAllSkills()
        guard !skills.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) else { return false }
        skills.append(SkillConfig(
            name: trimmed,
            notionPageId: pageId,
            enabled: true,
            visibility: visibility,
            summary: "",
            triggerPhrases: [],
            antiTriggerPhrases: [],
            url: url,
            platform: platform
        ))
        writeSkills(skills)
        return true
    }

    static func parseVisibilityArg(_ args: [String: Value]) -> SkillVisibility? {
        guard case .string(let raw) = args["visibility"] else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch t {
        case "routing": return .routing
        case "standard": return .standard
        case "command": return .command   // cmd-ux W3: palette visibility
        case "adminOnly": return .standard
        default: return nil
        }
    }

    /// W4-3.4.2: legacy enum-input setter, preserved as a back-compat
    /// wrapper that delegates to the flag-direct path. The 3-state enum
    /// maps to a flag pair via SkillVisibility.asFlags. A caller that
    /// wants the combined state should use `writeSetFlags` instead.
    static func writeSetVisibility(named name: String, visibility: SkillVisibility) -> Bool {
        let pair = visibility.asFlags
        return writeSetFlags(
            named: name,
            routingDiscoverable: pair.routingDiscoverable,
            inCommandPalette: pair.inCommandPalette
        )
    }

    /// W4-3.4.2 (H1 fix): flag-direct setter — the new SSOT write path
    /// for the visibility axis. Preserves combined-state losslessly
    /// (both flags can be set independently). Returns false if not found.
    static func writeSetFlags(
        named name: String,
        routingDiscoverable: Bool,
        inCommandPalette: Bool
    ) -> Bool {
        var skills = readAllSkills()
        if let idx = skills.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            let s = skills[idx]
            skills[idx] = SkillConfig(
                name: s.name,
                source: s.source,
                enabled: s.enabled,
                routingDiscoverable: routingDiscoverable,
                inCommandPalette: inCommandPalette,
                summary: s.summary,
                triggerPhrases: s.triggerPhrases,
                antiTriggerPhrases: s.antiTriggerPhrases,
                url: s.url,
                platform: s.platform
            )
            writeSkills(skills)
            return true
        }
        return false
    }

    /// Delete a skill by name. Returns true if found and removed.
    static func writeDeleteSkill(named name: String) -> Bool {
        var skills = readAllSkills()
        let before = skills.count
        skills.removeAll { $0.name.lowercased() == name.lowercased() }
        guard skills.count < before else { return false }
        writeSkills(skills)
        return true
    }

    /// Toggle a skill's enabled state. Returns (found, newState).
    static func writeToggleSkill(named name: String) -> (found: Bool, newState: Bool) {
        var skills = readAllSkills()
        if let idx = skills.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            let s = skills[idx]
            // W4-3.4.2 H1 fix: flag-direct reconstruction (toggle).
            skills[idx] = SkillConfig(
                name: s.name,
                source: s.source,
                enabled: !s.enabled,
                routingDiscoverable: s.routingDiscoverable,
                inCommandPalette: s.inCommandPalette,
                summary: s.summary,
                triggerPhrases: s.triggerPhrases,
                antiTriggerPhrases: s.antiTriggerPhrases,
                url: s.url,
                platform: s.platform
            )
            let newState = skills[idx].enabled
            writeSkills(skills)
            return (true, newState)
        }
        return (false, false)
    }

    /// Rename a skill. Returns true on success.
    static func writeRenameSkill(named oldName: String, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var skills = readAllSkills()
        guard !skills.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) else { return false }
        if let idx = skills.firstIndex(where: { $0.name.lowercased() == oldName.lowercased() }) {
            let s = skills[idx]
            // W4-3.4.2 H1 fix: flag-direct reconstruction (rename).
            skills[idx] = SkillConfig(
                name: trimmed,
                source: s.source,
                enabled: s.enabled,
                routingDiscoverable: s.routingDiscoverable,
                inCommandPalette: s.inCommandPalette,
                summary: s.summary,
                triggerPhrases: s.triggerPhrases,
                antiTriggerPhrases: s.antiTriggerPhrases,
                url: s.url,
                platform: s.platform
            )
            writeSkills(skills)
            return true
        }
        return false
    }

    /// Update a skill's page ID. Returns true on success.
    static func writeUpdateSkillURL(named name: String, newPageId: String) -> Bool {
        var skills = readAllSkills()
        if let idx = skills.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            let s = skills[idx]
            // W4-3.4.2 H1 fix: flag-direct reconstruction (update_url).
            // The flag-direct ctor takes `source:` so wrap the new
            // pageId in `.notion(pageId:)` to preserve the W2 D2 shape.
            skills[idx] = SkillConfig(
                name: s.name,
                source: .notion(pageId: newPageId),
                enabled: s.enabled,
                routingDiscoverable: s.routingDiscoverable,
                inCommandPalette: s.inCommandPalette,
                summary: s.summary,
                triggerPhrases: s.triggerPhrases,
                antiTriggerPhrases: s.antiTriggerPhrases,
                url: s.url,
                platform: s.platform
            )
            writeSkills(skills)
            return true
        }
        return false
    }

    struct BulkAddWriteResult {
        let added: Int
        let skipped: Int
        let invalidPageRows: [(name: String, reason: String)]
    }

    /// Bulk add skills. Skips invalid page URLs (per-row reasons) and duplicate names.
    static func writeBulkAdd(skills newSkills: [(name: String, pageId: String)]) -> BulkAddWriteResult {
        var existing = readAllSkills()
        var added = 0
        var skipped = 0
        var invalidPageRows: [(name: String, reason: String)] = []
        for s in newSkills {
            let trimmed = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                skipped += 1
                continue
            }
            if existing.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) {
                skipped += 1
                continue
            }
            switch NotionPageRef.normalizedPageId(from: s.pageId) {
            case .failure(let err):
                skipped += 1
                invalidPageRows.append((trimmed, err.message))
            case .success(let normalized):
                existing.append(SkillConfig(
                    name: trimmed,
                    notionPageId: normalized,
                    enabled: true,
                    visibility: .standard,
                    summary: "",
                    triggerPhrases: [],
                    antiTriggerPhrases: []
                ))
                added += 1
            }
        }
        writeSkills(existing)
        return BulkAddWriteResult(added: added, skipped: skipped, invalidPageRows: invalidPageRows)
    }

    // MARK: - Config Helpers

    /// Lightweight Codable struct matching `SkillsManager.Skill` layout.
    /// Used to read directly from UserDefaults without requiring @MainActor.
    ///
    /// W2 D2: carries a `SkillSource`. Decodes the new `source` field OR
    /// the legacy `notionPageId` top-level field (union-of-both backward
    /// compat). Encodes BOTH on the way out — forward compat with the
    /// pre-W2 wire format that consumers expect.
    internal struct SkillConfig: Codable {
        let name: String
        let source: SkillSource
        let enabled: Bool
        /// W4 (3.4.1): primary flag-based visibility — mirrors `SkillsManager.Skill`.
        let routingDiscoverable: Bool
        let inCommandPalette: Bool
        let summary: String
        let triggerPhrases: [String]
        let antiTriggerPhrases: [String]
        /// V2-SKILLS: Original URL for click-to-open.
        let url: String?
        /// V2-SKILLS: Auto-detected platform. Defaults to .notion for backward compat.
        let platform: SkillPlatform

        /// Notion page id for `.notion` sources, empty for `.file` sources.
        var notionPageId: String { source.notionPageIdOrEmpty }

        /// Derived legacy view — every call site that branches on a
        /// single enum value continues to work unchanged.
        var visibility: SkillVisibility {
            SkillVisibility.fromFlags(routingDiscoverable: routingDiscoverable, inCommandPalette: inCommandPalette)
        }

        enum CodingKeys: String, CodingKey {
            case name, source, notionPageId, enabled, visibility,
                 routingDiscoverable, inCommandPalette,
                 summary, triggerPhrases, antiTriggerPhrases, url, platform
        }

        /// Legacy ctor — most call sites still pass `notionPageId` directly.
        init(
            name: String,
            notionPageId: String,
            enabled: Bool,
            visibility: SkillVisibility = .standard,
            summary: String = "",
            triggerPhrases: [String] = [],
            antiTriggerPhrases: [String] = [],
            url: String? = nil,
            platform: SkillPlatform = .notion
        ) {
            self.init(
                name: name,
                source: .notion(pageId: notionPageId),
                enabled: enabled,
                visibility: visibility,
                summary: summary,
                triggerPhrases: triggerPhrases,
                antiTriggerPhrases: antiTriggerPhrases,
                url: url,
                platform: platform
            )
        }

        /// W2 D2: source-aware ctor (W4: maps enum → flag pair).
        init(
            name: String,
            source: SkillSource,
            enabled: Bool,
            visibility: SkillVisibility = .standard,
            summary: String = "",
            triggerPhrases: [String] = [],
            antiTriggerPhrases: [String] = [],
            url: String? = nil,
            platform: SkillPlatform = .notion
        ) {
            let pair = visibility.asFlags
            self.init(
                name: name,
                source: source,
                enabled: enabled,
                routingDiscoverable: pair.routingDiscoverable,
                inCommandPalette: pair.inCommandPalette,
                summary: summary,
                triggerPhrases: triggerPhrases,
                antiTriggerPhrases: antiTriggerPhrases,
                url: url,
                platform: platform
            )
        }

        /// W4: flag-direct ctor.
        init(
            name: String,
            source: SkillSource,
            enabled: Bool,
            routingDiscoverable: Bool,
            inCommandPalette: Bool,
            summary: String = "",
            triggerPhrases: [String] = [],
            antiTriggerPhrases: [String] = [],
            url: String? = nil,
            platform: SkillPlatform = .notion
        ) {
            self.name = name
            self.source = source
            self.enabled = enabled
            self.routingDiscoverable = routingDiscoverable
            self.inCommandPalette = inCommandPalette
            self.summary = SkillMetadataLimits.clampedSummary(summary)
            self.triggerPhrases = SkillMetadataLimits.clampedPhraseList(triggerPhrases)
            self.antiTriggerPhrases = SkillMetadataLimits.clampedPhraseList(antiTriggerPhrases)
            self.url = url
            self.platform = platform
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            if let decoded = try c.decodeIfPresent(SkillSource.self, forKey: .source) {
                source = decoded
            } else if let legacy = try c.decodeIfPresent(String.self, forKey: .notionPageId) {
                source = .notion(pageId: legacy)
            } else {
                source = .notion(pageId: "")
            }
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            // W4 migration: prefer flag pair; fall back to legacy enum.
            if let rd = try c.decodeIfPresent(Bool.self, forKey: .routingDiscoverable),
               let ip = try c.decodeIfPresent(Bool.self, forKey: .inCommandPalette) {
                routingDiscoverable = rd
                inCommandPalette = ip
            } else {
                let legacy = try c.decodeIfPresent(SkillVisibility.self, forKey: .visibility) ?? .standard
                let pair = legacy.asFlags
                routingDiscoverable = pair.routingDiscoverable
                inCommandPalette = pair.inCommandPalette
            }
            let rawSummary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
            let rawTriggers = try c.decodeIfPresent([String].self, forKey: .triggerPhrases) ?? []
            let rawAnti = try c.decodeIfPresent([String].self, forKey: .antiTriggerPhrases) ?? []
            summary = SkillMetadataLimits.clampedSummary(rawSummary)
            triggerPhrases = SkillMetadataLimits.clampedPhraseList(rawTriggers)
            antiTriggerPhrases = SkillMetadataLimits.clampedPhraseList(rawAnti)
            // V2-SKILLS: Backward-compat — existing skills default to .notion, no URL
            url = try c.decodeIfPresent(String.self, forKey: .url)
            platform = try c.decodeIfPresent(SkillPlatform.self, forKey: .platform) ?? .notion
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(source, forKey: .source)
            if case .notion(let pid) = source {
                try c.encode(pid, forKey: .notionPageId)
            }
            try c.encode(enabled, forKey: .enabled)
            // W4: write BOTH the flag pair (primary) AND the derived
            // legacy enum value (one-cycle back-compat).
            try c.encode(routingDiscoverable, forKey: .routingDiscoverable)
            try c.encode(inCommandPalette, forKey: .inCommandPalette)
            try c.encode(visibility, forKey: .visibility)
            try c.encode(summary, forKey: .summary)
            try c.encode(triggerPhrases, forKey: .triggerPhrases)
            try c.encode(antiTriggerPhrases, forKey: .antiTriggerPhrases)
            try c.encodeIfPresent(url, forKey: .url)
            try c.encode(platform, forKey: .platform)
        }

        /// Stable token for `fetch_skill` cache invalidation when metadata changes.
        var metadataCacheToken: String {
            let raw = "\(summary)\u{1e}\(triggerPhrases.joined(separator: "\u{1f}"))\u{1e}\(antiTriggerPhrases.joined(separator: "\u{1f}"))"
            var h: UInt64 = 14695981039346656037
            for b in raw.utf8 {
                h ^= UInt64(b)
                h &*= 1099511628211
            }
            return String(h, radix: 16)
        }
    }

    static func mcpMetadataObject(_ s: SkillConfig) -> [String: Value] {
        [
            "summary": .string(s.summary),
            "triggerPhrases": .array(s.triggerPhrases.map { .string($0) }),
            "antiTriggerPhrases": .array(s.antiTriggerPhrases.map { .string($0) })
        ]
    }

    // MARK: - cu-sa: simplified `properties` map

    /// Flatten a Notion page `properties` JSON object (the verbatim
    /// `pageJSON["properties"]` from `getPage`) into a small,
    /// deterministic `{ propertyName: human-readable scalar/array }`
    /// map for the `fetch_skill` envelope.
    ///
    /// This is the *only* new surface added by cu-sa — it is additive:
    /// every pre-existing envelope key and its value type is unchanged;
    /// the result of this function is injected under a single new
    /// `"properties"` key. The page `properties` blob is ALREADY fetched
    /// by `getPage` (it is parsed today purely to extract the title and
    /// then discarded) — this surfaces what is already in hand, it does
    /// NOT add a network call.
    ///
    /// Mapping (Notion property `type` → flattened `Value`):
    ///  - `title` / `rich_text`        → plain text `String`
    ///  - `select` / `status`          → option `name` `String`
    ///  - `multi_select`               → `[String]` of option names
    ///  - `number`                     → `Int` if integral else `Double`
    ///  - `checkbox`                   → `Bool`
    ///  - `date`                       → `start` `String` (range end dropped)
    ///  - `url` / `email` / `phone_number` → `String`
    ///  - `people`                     → `[String]` of person name (else id)
    ///  - `relation`                   → `[String]` of related page ids
    ///  - `files`                      → `[String]` of file names/urls
    ///  - `created_time` / `last_edited_time` → `String`
    ///  - `created_by` / `last_edited_by`     → name `String` (else id)
    ///  - `unique_id`                  → `"prefix-123"` / `"123"` `String`
    ///  - `formula`                    → its resolved inner value (recursed)
    ///  - `rollup`                     → its resolved value (array/number/
    ///                                   date/recursed single)
    ///  - any other / malformed type   → SKIPPED (never throws, never a
    ///                                   partial/garbage value)
    ///
    /// Pure + network-free + deterministic. A page that is not a database
    /// row (no `properties`, or an empty object) flattens to an empty
    /// map — callers see `"properties": {}` , never an error.
    static func flattenProperties(_ properties: [String: Any]) -> [String: Value] {
        var out: [String: Value] = [:]
        for (key, raw) in properties {
            guard let prop = raw as? [String: Any],
                  let type = prop["type"] as? String else {
                continue
            }
            if let v = flattenProperty(type: type, prop: prop) {
                out[key] = v
            }
        }
        return out
    }

    /// Flatten one Notion property value to a `Value`, or `nil` to skip
    /// (unknown / unmodelled / structurally-absent). Never throws.
    static func flattenProperty(type: String, prop: [String: Any]) -> Value? {
        switch type {
        case "title", "rich_text":
            guard let arr = prop[type] as? [[String: Any]] else { return nil }
            return .string(NotionJSON.extractPlainText(from: arr))

        case "select", "status":
            guard let opt = prop[type] as? [String: Any] else { return nil }
            guard let name = opt["name"] as? String else { return nil }
            return .string(name)

        case "multi_select":
            guard let arr = prop["multi_select"] as? [[String: Any]] else { return nil }
            return .array(arr.compactMap { ($0["name"] as? String).map(Value.string) })

        case "number":
            return flattenNumber(prop["number"])

        case "checkbox":
            guard let b = prop["checkbox"] as? Bool else { return nil }
            return .bool(b)

        case "date":
            guard let d = prop["date"] as? [String: Any],
                  let start = d["start"] as? String else { return nil }
            return .string(start)

        case "url", "email", "phone_number":
            guard let s = prop[type] as? String else { return nil }
            return .string(s)

        case "created_time", "last_edited_time":
            guard let s = prop[type] as? String else { return nil }
            return .string(s)

        case "created_by", "last_edited_by":
            guard let person = prop[type] as? [String: Any] else { return nil }
            return .string(personLabel(person))

        case "people":
            guard let arr = prop["people"] as? [[String: Any]] else { return nil }
            return .array(arr.map { .string(personLabel($0)) })

        case "relation":
            guard let arr = prop["relation"] as? [[String: Any]] else { return nil }
            return .array(arr.compactMap { ($0["id"] as? String).map(Value.string) })

        case "files":
            guard let arr = prop["files"] as? [[String: Any]] else { return nil }
            return .array(arr.compactMap { f -> Value? in
                if let n = f["name"] as? String, !n.isEmpty { return .string(n) }
                if let ext = f["external"] as? [String: Any],
                   let u = ext["url"] as? String { return .string(u) }
                if let file = f["file"] as? [String: Any],
                   let u = file["url"] as? String { return .string(u) }
                return nil
            })

        case "unique_id":
            guard let uid = prop["unique_id"] as? [String: Any] else { return nil }
            guard let num = uid["number"] else { return nil }
            let numStr: String
            if let i = num as? Int { numStr = String(i) }
            else if let d = num as? Double { numStr = String(d) }
            else if let n = num as? NSNumber { numStr = n.stringValue }
            else { return nil }
            if let prefix = uid["prefix"] as? String, !prefix.isEmpty {
                return .string("\(prefix)-\(numStr)")
            }
            return .string(numStr)

        case "formula":
            guard let f = prop["formula"] as? [String: Any],
                  let inner = f["type"] as? String else { return nil }
            return flattenProperty(type: inner, prop: f)

        case "rollup":
            guard let r = prop["rollup"] as? [String: Any],
                  let inner = r["type"] as? String else { return nil }
            if inner == "array", let elems = r["array"] as? [[String: Any]] {
                return .array(elems.compactMap { e -> Value? in
                    guard let et = e["type"] as? String else { return nil }
                    return flattenProperty(type: et, prop: e)
                })
            }
            return flattenProperty(type: inner, prop: r)

        default:
            return nil
        }
    }

    /// Normalise a Notion JSON number to `.int` when integral else
    /// `.double`; `nil` (no value) is skipped.
    static func flattenNumber(_ raw: Any?) -> Value? {
        switch raw {
        case let i as Int:
            return .int(i)
        case let d as Double:
            return d.rounded() == d && abs(d) < 9.007199254740992e15
                ? .int(Int(d)) : .double(d)
        case let n as NSNumber:
            let d = n.doubleValue
            return d.rounded() == d && abs(d) < 9.007199254740992e15
                ? .int(Int(d)) : .double(d)
        default:
            return nil
        }
    }

    /// Best human label for a Notion person/user object: `name`, else a
    /// person email, else the opaque `id`, else empty string (never nil
    /// so a people/by array stays positional).
    static func personLabel(_ person: [String: Any]) -> String {
        if let name = person["name"] as? String, !name.isEmpty { return name }
        if let p = person["person"] as? [String: Any],
           let email = p["email"] as? String, !email.isEmpty { return email }
        if let id = person["id"] as? String { return id }
        return ""
    }

}
