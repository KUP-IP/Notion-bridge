// PermissionView.swift — TCC Grant Status Display
// V1-02: Shows green/red status per grant with "Open System Settings" deep links
// for all 5 required TCC grants.
// PKT-341: Added rebuild note explaining TCC grant invalidation
// PKT-349 B3: Added permission pre-triggers for Automation and Contacts grants
//   (mirrors D2 pattern from OnboardingWindow.swift)
// PKT-357 F14: Auto-refresh permission status every 2s while view is visible
// BUGFIX: Automation button always opens System Settings > Automation pane.
//   Previous approach (tccutil reset + silent re-probe) is unreliable on
//   macOS Sequoia — prompts are suppressed and the button appeared to do nothing.
//   Now consistently opens the Automation settings pane for manual grant.
// PKT-362 D1: Stripped DisclosureGroup verbosity — name + status icon only.
//   Remediation text conditional on non-granted state.
// PKT-362 D3: Animated per-row re-check feedback via grantCheckingState.
// PKT-362 D6: Batched restart banner when needsRestart flag is set.

import SwiftUI
import AppKit
import os.log

private let permLog = Logger(subsystem: "kup.solutions.notion-bridge", category: "PermissionView")

/// Displays the V1 TCC permission status grid.
/// PKT-362 D1: Clean rows — name + status icon only, no DisclosureGroup.
/// PKT-362 D3: Per-row animated "Checking…" state from grantCheckingState.
/// PKT-362 D6: Restart banner when needsRestart is true.
public struct PermissionView: View {
    let permissionManager: PermissionManager

    // PKT-357 F14: Timer publisher for auto-refresh
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    @State private var previousGrantStatus: [PermissionManager.Grant: PermissionManager.GrantStatus] = [:]
    @State private var recentlyGranted: Set<PermissionManager.Grant> = []

    public init(permissionManager: PermissionManager) {
        self.permissionManager = permissionManager
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(PermissionManager.Grant.v1Cases) { grant in
                permissionRow(
                    grant: grant,
                    status: permissionManager.status(for: grant)
                )
            }

            // PKT-362 D6: Batched restart banner
            if permissionManager.needsRestart {
                restartBanner
                    .padding(.top, 4)
            }

            // PKT-341: TCC rebuild note — grants are tied to code signature
            Text("Note: Xcode rebuilds may invalidate TCC grants (tied to code signature). Re-grant in System Settings if indicators turn orange after a rebuild.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        // PKT-357 F14: Check permissions on appear
        // V1-PATCH-003: checkAll() is now async (automation probes off main thread)
        .task {
            await permissionManager.checkAllAsync()
            await MainActor.run { captureGrantTransitions() }
        }
        // PKT-369 N3: Auto-refresh every 2s with async variant (includes notifications)
        .onReceive(refreshTimer) { _ in
            Task {
                await permissionManager.checkAllAsync()
                await MainActor.run { captureGrantTransitions() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // PKT-369 N3: Use async variant for complete permission check
            Task {
                await permissionManager.checkAllAsync()
                await MainActor.run { captureGrantTransitions() }
            }
        }
    }

    // MARK: - Row

    /// PKT-362 D1: Clean row — grant name + status icon only. No DisclosureGroup.
    /// Remediation text shown only for non-granted states.
    /// PKT-362 D3: Yellow "Checking…" indicator when grantCheckingState is active.
    private func permissionRow(
        grant: PermissionManager.Grant,
        status: PermissionManager.GrantStatus
    ) -> some View {
        let isChecking = permissionManager.grantCheckingState[grant] ?? false

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // D3: Yellow circle during check, normal status color otherwise
                Circle()
                    .fill(isChecking ? .yellow : statusColor(status))
                    .frame(width: 8, height: 8)

                Text(grant.displayName)
                    .font(.callout)

                Spacer()

                // D3: "Checking…" label during animated recheck
                if isChecking {
                    Text("Checking\u{2026}")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                } else if recentlyGranted.contains(grant) {
                    Text("\u{2713} Granted")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text(permissionManager.statusLabel(for: grant))
                        .font(.caption)
                        .foregroundStyle(status == .granted ? .green : .orange)
                }

                // D1: Action button only for non-granted, non-checking states
                if status != .granted && !isChecking {
                    Button(grant == .automation || grant == .fullDiskAccess
                           ? "Open Settings" : "Allow") {
                        permLog.notice("Button tapped for grant: \(grant.displayName)")
                        openSystemSettings(for: grant)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.blue)
                }
            }

            // D1: Remediation text — conditional, only for non-granted states
            if status != .granted && !isChecking {
                Text(permissionManager.remediation(for: grant))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // D1: DisclosureGroup REMOVED — probe/evidence data available via
            // Diagnostics export in Advanced settings or debugDetail(for:) API.
        }
        // D3: Animate row transitions (checking ↔ result) with 0.3s fade
        .animation(.easeInOut(duration: 0.3), value: isChecking)
    }

    // MARK: - D6 Restart Banner

    /// PKT-362 D6: Shows grant progress + single "Restart NotionBridge" prompt.
    /// Displays progress state when partial grants, confirmation when all granted.
    @ViewBuilder
    private var restartBanner: some View {
        let grantedCount = PermissionManager.Grant.v1Cases.filter {
            permissionManager.status(for: $0) == .granted
        }.count
        let totalCount = PermissionManager.Grant.v1Cases.count
        let allGranted = grantedCount == totalCount

        VStack(spacing: 6) {
            if allGranted {
                Label("All permissions granted \u{2014} restart to apply changes.",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Label("\(grantedCount) of \(totalCount) granted \u{2014} grant remaining permissions, then restart.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button("Restart Notion Bridge") {
                restartApp()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(allGranted ? Color.green.opacity(0.1) : Color.yellow.opacity(0.1))
        )
    }

    // MARK: - Helpers

    private func statusColor(_ status: PermissionManager.GrantStatus) -> Color {
        switch status {
        case .granted: return .green
        case .denied: return .orange
        case .unknown: return .orange
        case .partiallyGranted: return .orange
        case .restartRecommended: return .orange
        }
    }

    @MainActor
    private func captureGrantTransitions() {
        for grant in PermissionManager.Grant.v1Cases {
            let current = permissionManager.status(for: grant)
            if let previous = previousGrantStatus[grant],
               previous == .denied,
               current == .granted {
                recentlyGranted.insert(grant)
                Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    _ = await MainActor.run {
                        recentlyGranted.remove(grant)
                    }
                }
            }
            previousGrantStatus[grant] = current
        }
    }

    /// PKT-362 D6: Restart the app by launching a new instance and terminating current.
    private func restartApp() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1 && open '\(bundlePath)'"]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - Deep Links

    /// Opens the relevant System Settings pane for the given TCC grant.
    /// Strategy per grant:
    /// - Accessibility, Screen Recording: Trigger native macOS prompt (reliable on Sequoia).
    /// - Automation: Always open System Settings > Automation pane. The previous approach
    ///   (tccutil reset + NSAppleScript re-probe) is unreliable on macOS Sequoia — prompts
    ///   are silently suppressed and the button appeared to do nothing. Direct Settings
    ///   navigation is the only reliable path for users to grant Automation targets.
    /// - Contacts: Trigger native Contacts prompt.
    /// - Full Disk Access: Always open System Settings (no native prompt exists).
    private func openSystemSettings(for grant: PermissionManager.Grant) {
        switch grant {
        case .accessibility:
            // Trigger the native macOS prompt only — do NOT also open System Settings.
            _ = permissionManager.requestAccessibilityAccess()
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await permissionManager.recheckAllForTruth()
            }
        case .automation:
            // Always open System Settings > Automation pane directly.
            // tccutil reset + re-probe is unreliable on macOS Sequoia — prompts get
            // silently suppressed, making the button appear to do nothing.
            // The checkAutomation() probes running on the 2s timer will register the
            // app in TCC so it appears in the Automation list.
            let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
            permLog.notice("[AUTOMATION] Attempting to open: \(urlString)")
            if let url = URL(string: urlString) {
                permLog.notice("[AUTOMATION] URL created successfully: \(url.absoluteString)")
                let result = NSWorkspace.shared.open(url)
                permLog.notice("[AUTOMATION] NSWorkspace.shared.open returned: \(result)")
            } else {
                permLog.error("[AUTOMATION] Failed to create URL from string: \(urlString)")
            }
            Task {
                await permissionManager.recheckAllForTruth()
            }
        case .notifications:
            // PKT-369 N4: Open System Settings directly — no pre-flight
            // requestNotificationAccess(). The pre-flight was unreliable because
            // requestAuthorization returns false when auth was already determined
            // externally. The 2s timer + checkAllAsync() detects grant state.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                NSWorkspace.shared.open(url)
            }
            Task { await permissionManager.recheckAllForTruth() }
        case .contacts:
            // Trigger the native Contacts prompt only.
            Task {
                _ = await permissionManager.requestContactsAccess()
                await permissionManager.recheckAllForTruth()
            }
        case .screenRecording:
            // Trigger the native Screen Recording prompt only — do NOT also open System Settings.
            _ = permissionManager.requestScreenRecordingAccess()
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await permissionManager.recheckAllForTruth()
            }
        case .fullDiskAccess:
            // Full Disk Access: no native prompt exists — must open System Settings directly.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
            Task {
                await permissionManager.recheckAllForTruth()
            }
        }
    }
}
