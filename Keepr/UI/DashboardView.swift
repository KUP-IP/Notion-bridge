// DashboardView.swift — Minimal Status Popover
// Notion Bridge v1: Shows active connections, tool calls, registered tool count, and server uptime
// PKT-317: Added tool calls row for live server status from unified binary
// PKT-329: Added connection setup section with tunnel provider selection
// PKT-320: Added Notion API token status indicator (connected/disconnected/missing)
// PKT-341: Version string now reads from Bundle (single source of truth)

import SwiftUI

/// Minimal status popover for the menu bar app.
/// Displays live server status, Notion token status, connection setup,
/// permission states, and provides quit/refresh actions.
/// Data flows from StatusBarController and PermissionManager observable objects.
public struct DashboardView: View {
    let statusBar: StatusBarController
    let permissionManager: PermissionManager

    public init(statusBar: StatusBarController, permissionManager: PermissionManager) {
        self.statusBar = statusBar
        self.permissionManager = permissionManager
    }

    /// PKT-341: Version from Bundle (single source of truth — Info.plist)
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            serverStatusSection
            Divider()
            notionTokenSection
            Divider()
            connectionSection
            Divider()
            permissionSection
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Server Status

    private var serverStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow(
                icon: "circle.fill",
                iconColor: statusBar.isServerRunning ? .green : .gray,
                label: "Connections",
                value: "\(statusBar.activeConnections)"
            )
            statusRow(
                icon: "wrench.and.screwdriver",
                iconColor: .blue,
                label: "Tools",
                value: "\(statusBar.registeredToolCount) registered"
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
        .padding(.vertical, 12)
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

    // MARK: - Notion Token Status

    private var notionTokenSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NOTION API")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            HStack(spacing: 8) {
                Image(systemName: notionTokenIcon)
                    .foregroundStyle(notionTokenColor)
                    .frame(width: 12)
                Text("Token")
                    .font(.callout)
                Spacer()
                Text(notionTokenLabel)
                    .font(.callout)
                    .foregroundStyle(notionTokenColor)
            }

            if !statusBar.notionTokenDetail.isEmpty {
                Text(statusBar.notionTokenDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var notionTokenIcon: String {
        switch statusBar.notionTokenStatus {
        case "connected": return "checkmark.circle.fill"
        case "disconnected": return "exclamationmark.circle.fill"
        default: return "minus.circle.fill"
        }
    }

    private var notionTokenColor: Color {
        switch statusBar.notionTokenStatus {
        case "connected": return .green
        case "disconnected": return .orange
        default: return .gray
        }
    }

    private var notionTokenLabel: String {
        switch statusBar.notionTokenStatus {
        case "connected": return "Connected"
        case "disconnected": return "Disconnected"
        default: return "Missing"
        }
    }

    // MARK: - Connection Setup

    private var connectionSection: some View {
        ConnectionSetupView()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }

    // MARK: - Permissions

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PERMISSIONS")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            PermissionView(permissionManager: permissionManager)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button("Quit Notion Bridge") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)

            Spacer()

            Button("Refresh") {
                permissionManager.checkAll()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
