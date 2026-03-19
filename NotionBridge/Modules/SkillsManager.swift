// SkillsManager.swift — Skills Configuration Manager
// NotionBridge · Modules
// PKT-366 F9: Manages named Notion page skills stored in UserDefaults.

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
