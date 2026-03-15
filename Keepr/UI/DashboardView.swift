// DashboardView.swift — Slim Status Popover
// Notion Bridge v1: Shows server status, connected clients, and gear icon
// V1-QUALITY-C2: Reduced popover to essentials — status + connected clients + gear icon
// Removed: permissions section, connection setup, Notion token details, footer actions
// Previous history: PKT-317, PKT-329, PKT-320, PKT-341, PKT-342

import SwiftUI

/// Slim status popover for the menu bar app.
/// Shows server status, connected client names, and a gear icon to open Settings.
/// All detailed configuration moved to SettingsWindow (V1-QUALITY-C2).
public struct DashboardView: View {
    let statusBar: StatusBarController
    let onOpenSettings: () -> Void

    public init(statusBar: StatusBarController, onOpenSettings: @escaping () -> Void) {
        self.statusBar = statusBar
        self.onOpenSettings = onOpenSettings
    }

    /// PKT-341: Version from Bundle (single source of truth — Info.plist)
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            statusSection
            Divider()
            clientsSection
            Divider()
            footerSection
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Image(systemName: "bridge.fill")
                .foregroundStyle(.purple)
            Text("Notion Bridge")
                .font(.headline)
            Spacer()
            Text("v\(appVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open Settings (⌘,)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow(
                icon: "circle.fill",
                iconColor: statusBar.isServerRunning ? .green : .gray,
                label: "Server",
                value: statusBar.isServerRunning ? "Running" : "Stopped"
            )
            statusRow(
                icon: "wrench.and.screwdriver",
                iconColor: .blue,
                label: "Tools",
                value: "\(statusBar.registeredToolCount)"
            )
            statusRow(
                icon: "hammer",
                iconColor: .purple,
                label: "Tool Calls",
                value: "\(statusBar.totalToolCalls)"
            )
            statusRow(
                icon: "clock",
                iconColor: .orange,
                label: "Uptime",
                value: statusBar.uptimeString
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func statusRow(icon: String, iconColor: Color, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 12)
            Text(label)
                .font(.callout)
            Spacer()
            Text(value)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Connected Clients

    private var clientsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CONNECTED CLIENTS")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if statusBar.connectedClients.isEmpty {
                Text("No clients connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } else {
                ForEach(statusBar.connectedClients, id: \.name) { client in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                        Text("\(client.name) \(client.version)")
                            .font(.caption)
                        Spacer()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.red)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
