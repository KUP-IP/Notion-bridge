// ToolRegistryView.swift — Tool Registry Tab
// NotionBridge · UI
// Displays all registered MCP tools grouped by module with enable/disable toggles.
// V1.3.0: PKT-366 F1/F4/F5 — Tappable tier toggle, Reset to Defaults, search removed.
//
// History:
// PKT-350 F2: Original tool registry with grouped modules and toggles.
// V1.2.0: Search bar, moduleDisplayNames dictionary, filteredGroups.
// V1.3.0: PKT-366 F1 tappable Open/Notify tier toggle per tool,
//          F4 "Reset to Defaults" button, F5 search bar removed.

import SwiftUI

/// Tool Registry tab for Settings window.
/// Shows all MCP tools grouped by module with toggle controls and tier overrides.
///
/// PKT-366 additions:
/// - F1: Tappable Open/Notify toggle per tool. Persisted to `com.notionbridge.tierOverrides`.
/// - F4: "Reset to Defaults" clears all tier overrides.
/// - F5: Search bar removed.
struct ToolRegistryView: View {
    let tools: [ToolInfo]
    let onToggle: (String, Bool) -> Void

    /// F7: Whether notification permission is denied/not determined.
    /// When true AND any tool has Notify tier, a warning banner is shown.
    var notificationDenied: Bool = false

    @State private var disabledTools: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "com.notionbridge.disabledTools") ?? []
    )

    /// F1: User tier overrides. Keys are tool names, values are tier raw values ("open"/"notify").
    /// Tools not in this map inherit their registered default tier.
    @State private var tierOverrides: [String: String] = (
        UserDefaults.standard.dictionary(forKey: "com.notionbridge.tierOverrides") as? [String: String]
    ) ?? [:]

    private static let coreTools: Set<String> = ["echo", "session_info", "tools_list"]

    /// Brand-correct display names for modules whose `.capitalized` form is wrong.
    /// Modules not in this dictionary fall through to `.capitalized`.
    private static let moduleDisplayNames: [String: String] = [
        "applescript": "AppleScript",
        "builtin": "Built-in",
    ]

    /// Returns the display-safe name for a module key.
    private func displayName(for module: String) -> String {
        Self.moduleDisplayNames[module] ?? module.capitalized
    }

    private var groupedTools: [(module: String, tools: [ToolInfo])] {
        let dict = Dictionary(grouping: tools, by: { $0.module })
        return dict.keys.sorted().map { ($0, dict[$0]!.sorted(by: { $0.name < $1.name })) }
    }

    /// Effective tier for a tool, considering user overrides.
    private func effectiveTier(for tool: ToolInfo) -> String {
        tierOverrides[tool.name] ?? tool.tier
    }

    /// F7: Whether any tool is set to Notify tier (via override or default).
    private var hasNotifyTierTools: Bool {
        tools.contains { effectiveTier(for: $0) == "notify" }
    }

    var body: some View {
        if tools.isEmpty {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "hammer")
                    .font(.system(size: 48))
                    .foregroundStyle(.gray.opacity(0.5))
                Text("Tool Registry")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text("Tools will appear here once the server is running.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        } else {
            Form {
                // F7: Cross-dependency warning — notifications denied + Notify-tier tools exist
                if notificationDenied && hasNotifyTierTools {
                    Section {
                        Label("Notification permission is not granted. Tools set to Notify tier won’t produce alerts.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }

                // F4: Reset to Defaults — only visible when user overrides exist
                if !tierOverrides.isEmpty {
                    Section {
                        Button {
                            tierOverrides.removeAll()
                            persistTierOverrides()
                        } label: {
                            HStack {
                                Image(systemName: "arrow.counterclockwise")
                                Text("Reset to Defaults")
                            }
                        }
                        .foregroundStyle(.orange)
                    }
                }

                ForEach(groupedTools, id: \.module) { group in
                    Section {
                        ForEach(group.tools) { tool in
                            toolRow(tool)
                        }
                    } header: {
                        HStack {
                            Text(displayName(for: group.module))
                                .font(.headline)
                            Spacer()
                            Text("\(enabledCount(in: group.tools))/\(group.tools.count)")
                                .font(.caption)
                                .foregroundStyle(BridgeColors.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func enabledCount(in tools: [ToolInfo]) -> Int {
        tools.filter { !disabledTools.contains($0.name) }.count
    }

    @ViewBuilder
    private func toolRow(_ tool: ToolInfo) -> some View {
        let isCoreProtected = Self.coreTools.contains(tool.name)
        let isEnabled = !disabledTools.contains(tool.name)
        let currentTier = effectiveTier(for: tool)

        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { newValue in
                    if newValue {
                        disabledTools.remove(tool.name)
                    } else {
                        disabledTools.insert(tool.name)
                    }
                    persistDisabledTools()
                    onToggle(tool.name, newValue)
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(isCoreProtected)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.name)
                        .fontWeight(.medium)

                    // F1: Tappable Open/Notify tier toggle (capsule style)
                    // Green = Open, Orange = Notify. Click to toggle.
                    Button {
                        let newTier = currentTier == "open" ? "notify" : "open"
                        if newTier == tool.tier {
                            // Reverted to registered default — remove override
                            tierOverrides.removeValue(forKey: tool.name)
                        } else {
                            tierOverrides[tool.name] = newTier
                        }
                        persistTierOverrides()
                    } label: {
                        Text(currentTier)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(currentTier == "open"
                                ? Color.green.opacity(0.15)
                                : Color.orange.opacity(0.15))
                            .foregroundStyle(currentTier == "open" ? .green : .orange)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    // Dimmed when tool is disabled (per Interaction spec)
                    .opacity(isEnabled ? 1.0 : 0.4)

                    if isCoreProtected {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(BridgeColors.secondary)
                    }
                }

                Text(tool.description)
                    .font(.caption)
                    .foregroundStyle(BridgeColors.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private func persistDisabledTools() {
        UserDefaults.standard.set(Array(disabledTools), forKey: "com.notionbridge.disabledTools")
    }

    /// Persist tier overrides to UserDefaults.
    private func persistTierOverrides() {
        UserDefaults.standard.set(tierOverrides, forKey: "com.notionbridge.tierOverrides")
    }
}
