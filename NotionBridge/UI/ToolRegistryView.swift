// ToolRegistryView.swift — Tool Registry Tab
// NotionBridge · UI
// Displays all registered MCP tools grouped by module with enable/disable toggles.
// V1.2.0: Added search filter, fixed module display names (AppleScript capitalization).
//
// History:
// PKT-350 F2: Original tool registry with grouped modules and toggles.
// V1.2.0: Search bar, moduleDisplayNames dictionary, filteredGroups.

import SwiftUI

/// Tool Registry tab for Settings window.
/// Shows all MCP tools grouped by module with toggle controls and search filter.
struct ToolRegistryView: View {
    let tools: [ToolInfo]
    let onToggle: (String, Bool) -> Void

    @State private var disabledTools: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "com.notionbridge.disabledTools") ?? []
    )
    @State private var searchText = ""

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

    /// Grouped tools filtered by search query. Matches tool name, description, or module.
    private var filteredGroups: [(module: String, tools: [ToolInfo])] {
        guard !searchText.isEmpty else { return groupedTools }
        let query = searchText.lowercased()
        return groupedTools.compactMap { group in
            let matching = group.tools.filter {
                $0.name.lowercased().contains(query) ||
                $0.description.lowercased().contains(query) ||
                displayName(for: group.module).lowercased().contains(query)
            }
            return matching.isEmpty ? nil : (group.module, matching)
        }
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
                Section {
                    HStack(spacing: BridgeSpacing.xs) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(BridgeColors.muted)
                        TextField("Search tools…", text: $searchText)
                            .textFieldStyle(.plain)
                    }
                }

                if filteredGroups.isEmpty {
                    Section {
                        Text("No tools matching \"\(searchText)\"")
                            .foregroundStyle(BridgeColors.secondary)
                    }
                } else {
                    ForEach(filteredGroups, id: \.module) { group in
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

                    Text(tool.tier)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(tool.tier == "open"
                            ? Color.green.opacity(0.15)
                            : Color.orange.opacity(0.15))
                        .foregroundStyle(tool.tier == "open" ? .green : .orange)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

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
}
