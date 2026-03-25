// SkillsManager.swift — Skills Configuration Manager
// NotionBridge · Modules
// PKT-366 F9: Manages named Notion page skills stored in UserDefaults.
// PKT-485: Added defaultSkills array + resetToDefaults() for factory reset.
// PKT-487: Added moveSkill(from:to:) and sortAlphabetically() for ordering.

import Foundation
import Observation

/// Manages the Skills configuration — named Notion pages that can be
/// fetched at runtime via the `fetch_skill` MCP tool.
///
/// Persistence: JSON-encoded array in UserDefaults under `com.notionbridge.skills`.
/// Each skill has a unique name, a Notion page ID (URL), and an enabled flag.
@MainActor
@Observable
public final class SkillsManager {

    /// A single skill definition: name + Notion page ID + enabled flag.
    public struct Skill: Codable, Identifiable, Sendable, Equatable {
        public var id: String { name }
        public var name: String
        public var notionPageId: String
        public var enabled: Bool

        public init(name: String, notionPageId: String, enabled: Bool = true) {
            self.name = name
            self.notionPageId = notionPageId
            self.enabled = enabled
        }
    }

    private static let defaultsKey = "com.notionbridge.skills"

    /// PKT-485: Default skills restored after factory reset.
    /// Structural defaults with empty page IDs — configured during onboarding.
    public static let defaultSkills: [Skill] = [
        Skill(name: "MAC AG", notionPageId: "", enabled: true),
        Skill(name: "sk mac dev", notionPageId: "", enabled: true),
        Skill(name: "sk executor", notionPageId: "", enabled: true),
    ]

    public private(set) var skills: [Skill] = []

    public init() {
        load()
    }

    // MARK: - CRUD

    /// Add a new skill. Returns false if name is empty or not unique.
    @discardableResult
    public func addSkill(name: String, notionPageId: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !skills.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) else {
            return false
        }
        skills.append(Skill(name: trimmed, notionPageId: notionPageId))
        save()
        return true
    }

    /// Remove a skill by name.
    public func removeSkill(named name: String) {
        skills.removeAll { $0.name == name }
        save()
    }

    /// Toggle a skill's enabled state.
    public func toggleSkill(named name: String) {
        if let idx = skills.firstIndex(where: { $0.name == name }) {
            skills[idx].enabled.toggle()
            save()
        }
    }

    /// Look up a skill by name (case-insensitive).
    public func skill(named name: String) -> Skill? {
        skills.first { $0.name.lowercased() == name.lowercased() }
    }

    /// All enabled skills.
    public var enabledSkills: [Skill] {
        skills.filter(\.enabled)
    }

    // MARK: - Extended CRUD (PKT-477 Feature 3)

    /// Rename a skill. Returns false if name is empty, not unique, or not found.
    @discardableResult
    public func renameSkill(named oldName: String, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !skills.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) else { return false }
        if let idx = skills.firstIndex(where: { $0.name.lowercased() == oldName.lowercased() }) {
            skills[idx].name = trimmed
            save()
            return true
        }
        return false
    }

    /// Update a skill's Notion page ID. Returns false if not found.
    @discardableResult
    public func updateSkillURL(named name: String, newPageId: String) -> Bool {
        if let idx = skills.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            skills[idx].notionPageId = newPageId
            save()
            return true
        }
        return false
    }

    /// Bulk add multiple skills at once. Skips duplicates.
    public func bulkAdd(skills newSkills: [(name: String, pageId: String)]) -> (added: Int, skipped: Int) {
        var added = 0, skipped = 0
        for s in newSkills {
            if addSkill(name: s.name, notionPageId: s.pageId) {
                added += 1
            } else {
                skipped += 1
            }
        }
        return (added, skipped)
    }

    /// Return all skills (for manage tool).
    public func listSkills() -> [Skill] {
        return skills
    }

    // MARK: - Ordering (PKT-487)

    /// Move a skill from one position to another. Persists immediately.
    /// Returns false if either index is out of bounds or indices are equal.
    @discardableResult
    public func moveSkill(from source: Int, to destination: Int) -> Bool {
        guard source >= 0, source < skills.count,
              destination >= 0, destination < skills.count,
              source != destination else { return false }
        let skill = skills.remove(at: source)
        skills.insert(skill, at: destination)
        save()
        return true
    }

    /// Sort all skills alphabetically by name (case-insensitive). Persists immediately.
    public func sortAlphabetically() {
        skills.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
    }

    // MARK: - Factory Reset (PKT-485)

    /// Replace all skills with the default set and persist to UserDefaults.
    /// Called by factory reset to restore a known-good starting state.
    public func resetToDefaults() {
        skills = Self.defaultSkills
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([Skill].self, from: data) else {
            skills = []
            return
        }
        skills = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(skills) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
