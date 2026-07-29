// Extracted from SkillsModule.swift by PKT-1126. Pure decomposition; behavior unchanged.

import Foundation
import MCP

extension SkillsModule {
    // MARK: - W2 D5/D6: File-source fetch_skill + merged list_routing_skills

    /// W2 D7: per-path enable state for file-source skills lives in
    /// `BridgeDefaults.fileSkillEnabled` (Dictionary<String, Bool>).
    /// Missing entry → enabled (the default). The SKILL.md itself stays
    /// read-only; we never write into it.
    public static func isFileSkillEnabled(path: URL) -> Bool {
        guard let dict = UserDefaults.standard.dictionary(forKey: BridgeDefaults.fileSkillEnabled) as? [String: Bool] else {
            return true
        }
        return dict[path.path] ?? true
    }

    /// W2 D7: write the per-path enabled flag.
    public static func setFileSkillEnabled(path: URL, enabled: Bool) {
        var dict = (UserDefaults.standard.dictionary(forKey: BridgeDefaults.fileSkillEnabled) as? [String: Bool]) ?? [:]
        dict[path.path] = enabled
        UserDefaults.standard.set(dict, forKey: BridgeDefaults.fileSkillEnabled)
    }

    /// W4 (3.4.1): per-path routing-discoverable flag for file-source
    /// skills. Missing entry returns nil so callers can fall back to
    /// the frontmatter-derived default.
    public static func explicitFileSkillRoutingDiscoverable(path: URL) -> Bool? {
        let dict = UserDefaults.standard.dictionary(forKey: BridgeDefaults.fileSkillRoutingDiscoverable) as? [String: Bool]
        return dict?[path.path]
    }

    public static func setFileSkillRoutingDiscoverable(path: URL, value: Bool) {
        var dict = (UserDefaults.standard.dictionary(forKey: BridgeDefaults.fileSkillRoutingDiscoverable) as? [String: Bool]) ?? [:]
        dict[path.path] = value
        UserDefaults.standard.set(dict, forKey: BridgeDefaults.fileSkillRoutingDiscoverable)
    }

    /// W4 (3.4.1): per-path palette-membership flag for file-source
    /// skills. Missing entry returns nil → defaults to false (no
    /// auto-promotion into the hot-key palette).
    public static func explicitFileSkillInCommandPalette(path: URL) -> Bool? {
        let dict = UserDefaults.standard.dictionary(forKey: BridgeDefaults.fileSkillInCommandPalette) as? [String: Bool]
        return dict?[path.path]
    }

    public static func setFileSkillInCommandPalette(path: URL, value: Bool) {
        var dict = (UserDefaults.standard.dictionary(forKey: BridgeDefaults.fileSkillInCommandPalette) as? [String: Bool]) ?? [:]
        dict[path.path] = value
        UserDefaults.standard.set(dict, forKey: BridgeDefaults.fileSkillInCommandPalette)
    }

    /// W4 (3.4.1): effective routing-discoverable for a file-source
    /// skill — explicit toggle wins, else derives from frontmatter
    /// (`visibility: routing` ⇒ true, anything else ⇒ false).
    public static func isFileSkillRoutingDiscoverable(path: URL, frontmatter: [String: Any]) -> Bool {
        if let explicit = explicitFileSkillRoutingDiscoverable(path: path) {
            return explicit
        }
        if let v = frontmatter["visibility"] as? String, v == "routing" {
            return true
        }
        return false
    }

    /// Same effective routing predicate for already-parsed SKILL.md
    /// frontmatter. Keeps the routing list on the same flag semantics as
    /// Settings → Skills without lossy type-erasure at the call site.
    public static func isFileSkillRoutingDiscoverable(path: URL, frontmatter: [String: FrontmatterValue]) -> Bool {
        if let explicit = explicitFileSkillRoutingDiscoverable(path: path) {
            return explicit
        }
        if case .string(let v) = frontmatter["visibility"], v == "routing" {
            return true
        }
        return false
    }

    /// W4 (3.4.1): effective palette-membership for a file-source
    /// skill — explicit toggle only (no frontmatter default).
    public static func isFileSkillInCommandPalette(path: URL) -> Bool {
        explicitFileSkillInCommandPalette(path: path) ?? false
    }

    /// W2 D5: Build the `fetch_skill` envelope for a file-source skill.
    /// Shape mirrors `buildSkillResult` byte-for-byte (same envelope keys
    /// + value types) so the caller can not distinguish source by
    /// envelope shape — the only differences are: `url` is a `file://`
    /// URL, `properties` carries the flattened YAML frontmatter, and the
    /// `content` markdown body skips the network MentionResolver title
    /// lookup (mentions are passed through unchanged — bundled SKILL.md
    /// files don't typically mention Notion pages).
    public static func buildFileSkillResult(_ s: ParsedSkill) async -> Value {
        let body = s.body
        let nonEmptyLineCount = body
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .reduce(into: 0) { acc, line in
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { acc += 1 }
            }
        let title: String = {
            if case .string(let t) = s.frontmatter["title"], !t.isEmpty { return t }
            if case .string(let t) = s.frontmatter["name"],  !t.isEmpty { return t }
            return s.name
        }()
        let summary: String = {
            if case .string(let d) = s.frontmatter["description"] { return d }
            return String(body.prefix(200))
        }()
        let triggers: [String] = {
            if case .array(let arr) = s.frontmatter["triggers"] { return arr }
            return []
        }()
        let antiTriggers: [String] = {
            if case .array(let arr) = s.frontmatter["anti_triggers"] { return arr }
            return []
        }()
        // Frontmatter → public `properties` map (rich, never `nil`).
        var props: [String: Value] = [:]
        for (k, v) in s.frontmatter {
            switch v {
            case .string(let str):  props[k] = .string(str)
            case .bool(let b):      props[k] = .bool(b)
            case .array(let arr):   props[k] = .array(arr.map { .string($0) })
            }
        }
        let contentValue = body.isEmpty ? "(no content)" : body
        return .object([
            "name": .string(s.name),
            "title": .string(title),
            "url": .string(s.path.absoluteString),
            "blockCount": .int(nonEmptyLineCount),
            "truncated": .bool(false),
            "content": .string(contentValue),
            "summary": .string(summary),
            "triggerPhrases": .array(triggers.map { .string($0) }),
            "antiTriggerPhrases": .array(antiTriggers.map { .string($0) }),
            "properties": .object(props),
            "source": .string("file")
        ])
    }

    /// W2 D6: build the merged routing-skills list returned by
    /// `skills_routing_list`. Notion-source routing entries first (with
    /// a `shadows` annotation when a file-source skill of the same name
    /// is being overridden), then file-source skills whose effective
    /// routing flag is true. That flag is controlled by the operator's
    /// per-path toggle when present, otherwise by frontmatter
    /// `visibility: routing`.
    public static func mergedRoutingSkills() async -> [Value] {
        // Runtime Exposure v1: once a verified generation exists, it is the
        // final gate for Notion-backed routing. No generation means migration
        // has not cut over yet, so legacy installs remain byte-compatible.
        let exposureGate = await SkillRuntimeGenerationStore.shared.gate()
        let notionSkills = readAllSkills().filter { s in
            let validLegacyRow = s.enabled && s.routingDiscoverable
                && NotionPageRef.isValidStoredPageId(s.notionPageId.trimmingCharacters(in: .whitespacesAndNewlines))
            guard validLegacyRow else { return false }
            return exposureGate?.allows(pageID: s.notionPageId, surface: .routing) ?? true
        }
        let fileSkills = await FilesystemSkillIndex.shared.allSkills().filter { fs in
            // Honour per-path disable.
            guard isFileSkillEnabled(path: fs.path) else { return false }
            return isFileSkillRoutingDiscoverable(
                path: fs.path,
                frontmatter: fs.frontmatter
            )
        }
        let notionNames = Set(notionSkills.map { $0.name.lowercased() })
        var rows: [Value] = []
        for s in notionSkills {
            var row = skillRowFields(s)
            // Annotate shadowed file-source skill, if any.
            if let shadowed = fileSkills.first(where: { $0.name.lowercased() == s.name.lowercased() }) {
                row["shadows"] = .string("file:\(shadowed.displayPath)")
            }
            row["source"] = .string("notion")
            rows.append(.object(row))
        }
        for fs in fileSkills where !notionNames.contains(fs.name.lowercased()) {
            var row: [String: Value] = [
                "name": .string(fs.name),
                "source": .string("file"),
                "path": .string(fs.displayPath)
            ]
            if case .string(let d) = fs.frontmatter["description"] {
                row["summary"] = .string(d)
            }
            if case .array(let arr) = fs.frontmatter["triggers"] {
                row["triggerPhrases"] = .array(arr.map { .string($0) })
            }
            if case .array(let arr) = fs.frontmatter["anti_triggers"] {
                row["antiTriggerPhrases"] = .array(arr.map { .string($0) })
            }
            rows.append(.object(row))
        }
        // Stable alphabetical ordering by name.
        rows.sort { lhs, rhs in
            guard case .object(let l) = lhs, case .string(let ln) = l["name"],
                  case .object(let r) = rhs, case .string(let rn) = r["name"] else {
                return false
            }
            return ln.localizedCaseInsensitiveCompare(rn) == .orderedAscending
        }
        // PKT-907 W3: surface `specialists: [{path,title,summary}]` per
        // row that has file-source children. Notion-source children are
        // discovered lazily on demand (a sync scan of every parent's
        // child pages would blow the connect-time budget); the path
        // resolver still resolves them at fetch_skill call time, and
        // the W3 routing-index `specialists:` array is best-effort for
        // file-source parents now and reserved for Notion via a future
        // background scan.
        return await Self.surfaceSpecialistsInRows(rows)
    }

}
