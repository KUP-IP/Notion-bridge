// SkillsView.swift — Skills Tab in Settings
// NotionBridge · UI
// PKT-366 F9: Skills configuration UI with add/remove/toggle.
// PKT-366 F11: Cross-tab dependency guard (fetch_skill disabled warning).
// PKT-487: Clickable names, inline URL edit, reorder, sort alphabetically.

import SwiftUI
import Combine
#if canImport(AppKit)
import AppKit
#endif

/// Skills tab for the Settings window.
///
/// PKT-366 F9: Each row shows skill name + Notion page ID + on/off toggle.
/// "Add Skill" inline form with unique name enforcement.
/// PKT-366 F11: Warning banner if `fetch_skill` is disabled in Tools AND skills exist.
/// PKT-487: Interactive management — clickable names, inline URL edit, reorder, sort.
struct SkillsView: View {
    let skillsManager: SkillsManager

    /// F11: Whether `fetch_skill` is currently disabled in the Tools tab.
    var fetchSkillDisabled: Bool = false

    @State private var newSkillName: String = ""
    @State private var newSkillPageId: String = ""
    @State private var newSkillVisibility: SkillVisibility = .standard
    @State private var addError: String?

    // PKT-487: Inline URL editing state
    @State private var editingSkillName: String?
    @State private var editingURL: String = ""

    var body: some View {
        Form {
            // F11: Cross-tab dependency guard
            if fetchSkillDisabled && !skillsManager.skills.isEmpty {
                Section {
                    Label("The fetch_skill tool is disabled in Tools. Skills won\u{2019}t be available to AI clients until it\u{2019}s re-enabled.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            // Skill list
            if skillsManager.skills.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 36))
                            .foregroundStyle(.gray.opacity(0.5))
                        Text("No skills configured")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("Skills are Notion pages that AI clients can fetch at runtime via the fetch_skill MCP tool.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            } else {
                Section {
                    ForEach(Array(skillsManager.skills.enumerated()), id: \.element.id) { index, skill in
                        skillRow(skill, at: index)
                    }
                } header: {
                    HStack {
                        Text("Skills")
                            .font(.headline)
                        Spacer()
                        // PKT-487: Sort alphabetically action
                        Button {
                            commitPendingEdit()
                            skillsManager.sortAlphabetically()
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Sort alphabetically")
                        Text("\(skillsManager.enabledSkills.count)/\(skillsManager.skills.count) enabled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Add Skill form
            Section {
                TextField("Skill Name", text: $newSkillName)
                    .textFieldStyle(.roundedBorder)
                TextField("Notion Page ID or URL", text: $newSkillPageId)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Picker("Visibility", selection: $newSkillVisibility) {
                    Text("Standard (fetch only)").tag(SkillVisibility.standard)
                    Text("Routing (discovery list)").tag(SkillVisibility.routing)
                }

                if let error = addError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button("Add Skill") {
                    addSkill()
                }
                .disabled(newSkillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || newSkillPageId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Add Skill")
            } footer: {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Visibility", systemImage: "eye")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("Standard — Skill text is fetched with fetch_skill when the skill is enabled. It does not appear in the lightweight discovery list (list_routing_skills).")
                    Text("Routing — The skill is listed by list_routing_skills so agents can discover it by name without downloading the full page first.")
                    Divider()
                        .padding(.vertical, 4)
                    Text("Skills are Notion pages. Add the page URL or ID above; routing vs standard only affects how MCP clients discover the skill, not Notion sharing.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            skillsManager.reloadFromUserDefaults()
        }
        .onReceive(NotificationCenter.default.publisher(for: .notionBridgeSkillsStorageDidChange)) { _ in
            skillsManager.reloadFromUserDefaults()
        }
    }

    // MARK: - Skill Row

    @ViewBuilder
    private func skillRow(_ skill: SkillsManager.Skill, at index: Int) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { skill.enabled },
                set: { _ in skillsManager.toggleSkill(named: skill.name) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                // PKT-487 F1: Clickable skill name — opens Notion page URL in browser
                Button {
                    openSkillURL(skill.notionPageId)
                } label: {
                    Text(skill.name)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .underline(false)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }

                // PKT-487 F2: Inline URL edit — tap to edit, save on Enter/focus loss
                if editingSkillName == skill.name {
                    TextField("Notion Page URL", text: $editingURL)
                        .font(.caption)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            commitURLEdit(for: skill.name)
                        }
                        .onExitCommand {
                            editingSkillName = nil
                        }
                } else {
                    Text(skill.notionPageId.isEmpty ? "No URL set" : skill.notionPageId)
                        .font(.caption)
                        .foregroundStyle(skill.notionPageId.isEmpty ? .tertiary : .secondary)
                        .lineLimit(1)
                        .onTapGesture {
                            commitPendingEdit()
                            editingSkillName = skill.name
                            editingURL = skill.notionPageId
                        }
                }
                if !skill.summary.isEmpty {
                    Text(skill.summary)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }

            Picker("", selection: Binding(
                get: { skill.visibility },
                set: { skillsManager.setVisibility(named: skill.name, to: $0) }
            )) {
                Text("standard").tag(SkillVisibility.standard)
                Text("routing").tag(SkillVisibility.routing)
            }
            .labelsHidden()
            .frame(minWidth: 100)
            .help("MCP visibility: routing appears in list_routing_skills")

            Spacer()

            // PKT-487 F3: Reorder buttons — up/down chevrons
            VStack(spacing: 0) {
                Button {
                    commitPendingEdit()
                    skillsManager.moveSkill(from: index, to: index - 1)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption2)
                        .frame(width: 16, height: 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(index == 0)

                Button {
                    commitPendingEdit()
                    skillsManager.moveSkill(from: index, to: index + 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .frame(width: 16, height: 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(index == skillsManager.skills.count - 1)
            }

            Button(role: .destructive) {
                skillsManager.removeSkill(named: skill.name)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.7))
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions (PKT-487)

    /// Open a skill's Notion page URL in the default browser.
    private func openSkillURL(_ urlString: String) {
        let candidate: String
        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
            candidate = urlString
        } else if !urlString.isEmpty {
            // Treat bare page IDs as Notion URLs
            candidate = "https://www.notion.so/\(urlString)"
        } else {
            return
        }
        guard let url = URL(string: candidate) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Commit the current inline URL edit, if any.
    private func commitPendingEdit() {
        if let name = editingSkillName {
            commitURLEdit(for: name)
        }
    }

    /// Save the inline URL edit for a specific skill.
    private func commitURLEdit(for skillName: String) {
        let trimmed = editingURL.trimmingCharacters(in: .whitespacesAndNewlines)
        skillsManager.updateSkillURL(named: skillName, newPageId: trimmed)
        editingSkillName = nil
    }

    // MARK: - Add Skill

    private func addSkill() {
        addError = nil
        let name = newSkillName.trimmingCharacters(in: .whitespacesAndNewlines)
        let pageId = newSkillPageId.trimmingCharacters(in: .whitespacesAndNewlines)

        let cleanPageId = extractPageId(from: pageId)

        let success = skillsManager.addSkill(name: name, notionPageId: cleanPageId, visibility: newSkillVisibility)
        if success {
            newSkillName = ""
            newSkillPageId = ""
            newSkillVisibility = .standard
        } else {
            addError = "A skill with this name already exists."
        }
    }

    /// Extract a Notion page ID from a URL, or return the input unchanged.
    private func extractPageId(from input: String) -> String {
        // Handle common Notion URL patterns
        if input.contains("notion.so") || input.contains("notion.site"),
           let lastComponent = input.split(separator: "/").last {
            let str = String(lastComponent)
            // Page ID is the last 32 hex chars
            if let range = str.range(of: "[a-f0-9]{32}", options: .regularExpression) {
                return String(str[range])
            }
        }
        return input
    }
}
