// DashboardView.swift — Slim Status Popover
// Notion Gate v1: Shows server status, connected clients, and gear icon
// V1-QUALITY-C2: Reduced popover to essentials — status + connected clients + gear icon
// V1-QUALITY-POLISH (PKT-346 D5): Design pass — app icon, pill badges, timestamps, refined footer
// Previous history: PKT-317, PKT-329, PKT-320, PKT-341, PKT-342, PKT-346

import SwiftUI

/// Slim status popover for the menu bar app.
/// Shows server status, connected client names with timestamps, and a gear icon to open Settings.
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
        HStack(spacing: 10) {
            // D5: App icon from bundle instead of SF Symbol
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 24, height: 24)
                .cornerRadius(6)
            Text("Notion Gate")
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
            .help("Open Settings (\u{2318},)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // D5: Pill badges for Server, Tools, Tool Calls
            statusRow(
                icon: "circle.fill",
                iconColor: statusBar.isServerRunning ? .green : .gray,
                label: "Server",
                pill: statusBar.isServerRunning ? "Running" : "Stopped",
                pillColor: statusBar.isServerRunning ? .green : .gray
            )
            statusRow(
                icon: "wrench.and.screwdriver",
                iconColor: .blue,
                label: "Tools",
                pill: "\(statusBar.registeredToolCount)",
                pillColor: .blue
            )
            statusRow(
                icon: "hammer",
                iconColor: .purple,
                label: "Tool Calls",
                pill: "\(statusBar.totalToolCalls)",
                pillColor: .purple
            )
            // D5: Uptime stays as plain secondary text (changes constantly)
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .foregroundStyle(.orange)
                    .frame(width: 12)
                Text("Uptime")
                    .font(.callout)
                Spacer()
                Text(statusBar.uptimeString)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // D5: Status row with styled pill badge
    private func statusRow(icon: String, iconColor: Color, label: String, pill: String, pillColor: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 12)
            Text(label)
                .font(.callout)
            Spacer()
            Text(pill)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(pillColor.opacity(0.85))
                .cornerRadius(10)
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
                        // D5: Relative timestamp from connectedAt
                        Text(relativeTime(from: client.connectedAt))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // D5: Compact relative timestamp formatter
    private func relativeTime(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }

    // MARK: - Footer

    // D5: Refined footer — secondary text instead of red
    private var footerSection: some View {
        HStack {
            Button("Quit Notion Gate") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
