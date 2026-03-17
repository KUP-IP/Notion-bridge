// DashboardView.swift — Liquid Glass Status Popover
// Notion Bridge v2: macOS Tahoe 26 — Liquid Glass design language
// PKT-353: Full rewrite — content-first, monochrome, no pills, no dividers,
//   BridgeTheme design system, content-adaptive sizing, quit relocated to context menu.
// PKT-354: Added Screen Recording permission indicator (green/red).
// Previous history: PKT-317, PKT-329, PKT-320, PKT-341, PKT-342, PKT-346

import SwiftUI
import CoreGraphics

/// Status popover for the menu bar app.
/// Shows server status (primary), connected clients (secondary), permissions, and stats.
/// Styled with BridgeTheme. Liquid Glass chrome provided automatically by macOS 26 SDK.
public struct DashboardView: View {
    let statusBar: StatusBarController
    let onOpenSettings: () -> Void

    public init(statusBar: StatusBarController, onOpenSettings: @escaping () -> Void) {
        self.statusBar = statusBar
        self.onOpenSettings = onOpenSettings
    }

    /// Version from Bundle (single source of truth — Info.plist)
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0"
    }

    /// Screen Recording TCC grant status — checked on each popover appearance.
    @State private var screenRecordingGranted: Bool = false

    public var body: some View {
        VStack(alignment: .leading, spacing: BridgeSpacing.xs) {
            headerSection
            statusSection
            clientsSection
            permissionsSection
            statsSection
        }
        .frame(minWidth: 260, maxWidth: 320)
        .padding(.vertical, BridgeSpacing.xs)
        .onAppear {
            screenRecordingGranted = CGPreflightScreenCaptureAccess()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: BridgeSpacing.xs) {
            Text("Notion Bridge")
                .font(.headline)
                .foregroundStyle(BridgeColors.primary)
            Spacer()
            Text("v\(appVersion)")
                .bridgeSecondary()
            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
                    .symbolRenderingMode(.monochrome)
                    .font(.callout)
                    .foregroundStyle(BridgeColors.secondary)
            }
            .buttonStyle(.plain)
            .help("Open Settings (\u{2318},)")
        }
        .bridgeRow()
    }

    // MARK: - Server Status (Primary)

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: BridgeSpacing.xs) {
            Text("Server")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(BridgeColors.primary)

            HStack(spacing: BridgeSpacing.xs) {
                Circle()
                    .fill(statusBar.isServerRunning ? BridgeColors.success : BridgeColors.error)
                    .frame(width: 8, height: 8)
                Text(statusBar.isServerRunning ? "Running" : "Stopped")
                    .bridgeLabel()
                if statusBar.isServerRunning {
                    Text("· \(statusBar.uptimeString)")
                        .bridgeSecondary()
                }
                Spacer()
            }
        }
        .bridgeRow()
    }

    // MARK: - Connected Clients (Secondary)

    private var clientsSection: some View {
        VStack(alignment: .leading, spacing: BridgeSpacing.xs) {
            Text("Connected Clients")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(BridgeColors.primary)

            if statusBar.connectedClients.isEmpty {
                Text("No clients connected")
                    .bridgeSecondary()
            } else {
                ForEach(statusBar.connectedClients, id: \.name) { client in
                    HStack(spacing: BridgeSpacing.xs) {
                        Circle()
                            .fill(BridgeColors.success)
                            .frame(width: 6, height: 6)
                        Text("\(client.name) \(client.version)")
                            .font(.caption)
                            .foregroundStyle(BridgeColors.primary)
                        Spacer()
                        Text(relativeTime(from: client.connectedAt))
                            .font(.caption2)
                            .foregroundStyle(BridgeColors.muted)
                    }
                }
            }
        }
        .bridgeRow()
    }

    // MARK: - Permissions (PKT-354)

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: BridgeSpacing.xs) {
            Text("Permissions")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(BridgeColors.primary)

            HStack(spacing: BridgeSpacing.xs) {
                Circle()
                    .fill(screenRecordingGranted ? BridgeColors.success : BridgeColors.error)
                    .frame(width: 8, height: 8)
                Text("Screen Recording")
                    .font(.caption)
                    .foregroundStyle(BridgeColors.primary)
                Spacer()
                Text(screenRecordingGranted ? "Granted" : "Not Granted")
                    .font(.caption)
                    .foregroundStyle(screenRecordingGranted ? BridgeColors.success : BridgeColors.error)
            }
        }
        .bridgeRow()
    }

    // MARK: - Stats (Tertiary)

    private var statsSection: some View {
        HStack(spacing: BridgeSpacing.md) {
            statItem(label: "Tools", value: "\(statusBar.registeredToolCount)")
            statItem(label: "Calls", value: "\(statusBar.totalToolCalls)")
        }
        .bridgeRow()
    }

    private func statItem(label: String, value: String) -> some View {
        HStack(spacing: BridgeSpacing.xxs) {
            Text(label)
                .font(.caption)
                .foregroundStyle(BridgeColors.muted)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(BridgeColors.secondary)
        }
    }

    // MARK: - Helpers

    /// Compact relative timestamp formatter
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
}
