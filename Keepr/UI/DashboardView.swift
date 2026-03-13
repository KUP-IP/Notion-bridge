// DashboardView.swift — Minimal Status Popover
// V1-02: Shows active connections, registered tool count, and server uptime
// Reflects real status from observable state, not hardcoded placeholders.

import SwiftUI

/// Minimal status popover for the menu bar app.
/// Displays live server status, permission states, and provides
/// quit/refresh actions. Data flows from StatusBarController and
/// PermissionManager observable objects.
public struct DashboardView: View {
    let statusBar: StatusBarController
    let permissionManager: PermissionManager

    public init(statusBar: StatusBarController, permissionManager: PermissionManager) {
        self.statusBar = statusBar
        self.permissionManager = permissionManager
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            serverStatusSection
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
            Text("Keepr · Mac Bridge")
                .font(.headline)
            Spacer()
            Text("v1.0.0")
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
            Button("Quit Keepr") {
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
