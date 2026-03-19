// DashboardView.swift — Liquid Glass Status Popover
// Notion Bridge v2: macOS Tahoe 26 — Liquid Glass design language
// PKT-353: Full rewrite — content-first, monochrome, no pills, no dividers,
//   BridgeTheme design system, content-adaptive sizing, quit relocated to context menu.
// PKT-354: Added Screen Recording permission indicator (green/red).
// PKT-366 F12: Full TCC permissions display (Accessibility, Screen Recording,
//   Notifications, Contacts, Full Disk Access).
// Previous history: PKT-317, PKT-329, PKT-320, PKT-341, PKT-342, PKT-346

import SwiftUI
import AppKit
import UserNotifications
import Contacts

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

    // MARK: - TCC Permission States (F12)

    @State private var accessibilityGranted: Bool = false
    @State private var screenRecordingGranted: Bool = false
    @State private var notificationsGranted: Bool = false
    @State private var contactsGranted: Bool = false
    @State private var fullDiskAccessGranted: Bool = false

    public var body: some View {
        VStack(alignment: .leading, spacing: BridgeSpacing.xs) {
            headerSection
            statusSection
            clientsSection
            permissionsSection
            statsSection
            quitSection
        }
        .frame(minWidth: 260, maxWidth: 320)
        .padding(.vertical, BridgeSpacing.xs)
        .onAppear {
            refreshPermissions()
        }
    }

    /// Query all TCC permission states (F12).
    private func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        fullDiskAccessGranted = checkFullDiskAccess()
        contactsGranted = CNContactStore.authorizationStatus(for: .contacts) == .authorized
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            await MainActor.run {
                notificationsGranted = settings.authorizationStatus == .authorized
            }
        }
    }

    /// Full Disk Access probe: attempt to read a TCC-protected path.
    /// If readable, FDA is granted. If permission denied, it's not.
    private func checkFullDiskAccess() -> Bool {
        let protectedPath = "/Library/Application Support/com.apple.TCC/TCC.db"
        return FileManager.default.isReadableFile(atPath: protectedPath)
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
                    Text("\u{00B7} \(statusBar.uptimeString)")
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

    // MARK: - Permissions (F12: Full TCC Display)

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: BridgeSpacing.xs) {
            Text("Permissions")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(BridgeColors.primary)

            permissionRow("Accessibility", granted: accessibilityGranted)
            permissionRow("Screen Recording", granted: screenRecordingGranted)
            permissionRow("Notifications", granted: notificationsGranted)
            permissionRow("Contacts", granted: contactsGranted)
            permissionRow("Full Disk Access", granted: fullDiskAccessGranted)
        }
        .bridgeRow()
    }

    /// Single permission status row with dot indicator and granted/denied label (F12).
    private func permissionRow(_ name: String, granted: Bool) -> some View {
        HStack(spacing: BridgeSpacing.xs) {
            Circle()
                .fill(granted ? BridgeColors.success : BridgeColors.error)
                .frame(width: 8, height: 8)
            Text(name)
                .font(.caption)
                .foregroundStyle(BridgeColors.primary)
            Spacer()
            Text(granted ? "Granted" : "Not Granted")
                .font(.caption)
                .foregroundStyle(granted ? BridgeColors.success : BridgeColors.error)
        }
    }

    // MARK: - Stats (Tertiary)

    private var statsSection: some View {
        HStack(spacing: BridgeSpacing.md) {
            statItem(label: "Tools", value: "\(statusBar.registeredToolCount)")
            statItem(label: "Calls", value: "\(statusBar.totalToolCalls)")
        }
        .bridgeRow()
    }

    private var quitSection: some View {
        HStack {
            Spacer()
            Button("Quit Notion Bridge") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(BridgeColors.muted)
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
