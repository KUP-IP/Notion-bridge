// PermissionView.swift — TCC Grant Status Display
// V1-02: Shows green/red status per grant with "Open System Settings" deep links
// for all 5 required TCC grants.
// PKT-341: Added rebuild note explaining TCC grant invalidation
// PKT-349 B3: Added permission pre-triggers for Automation and Contacts grants
//   (mirrors D2 pattern from OnboardingWindow.swift)
// PKT-357 F14: Auto-refresh permission status every 2s while view is visible

import SwiftUI
import Combine
import AppKit

/// Displays the 5-grant TCC permission status grid.
/// Each row shows a colored indicator (green = granted, red = denied/unknown)
/// and a deep link button to the relevant System Settings pane for denied grants.
/// PKT-357 F14: Polls PermissionManager.checkAll() every 2 seconds while visible.
public struct PermissionView: View {
    let permissionManager: PermissionManager

    // PKT-357 F14: Timer publisher for auto-refresh
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

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

            // PKT-341: TCC rebuild note — grants are tied to code signature
            Text("Note: Xcode rebuilds may invalidate TCC grants (tied to code signature). Re-grant in System Settings if indicators turn red after a rebuild.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        // PKT-357 F14: Check permissions on appear
        .onAppear {
            permissionManager.checkAll()
        }
        // PKT-357 F14: Auto-refresh every 2s so status updates after user
        // grants permission in System Settings and switches back
        .onReceive(refreshTimer) { _ in
            permissionManager.checkAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionManager.checkAll()
        }
    }

    // MARK: - Row

    private func permissionRow(
        grant: PermissionManager.Grant,
        status: PermissionManager.GrantStatus
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 8, height: 8)

                Text(grant.displayName)
                    .font(.callout)

                Spacer()

                Text(permissionManager.statusLabel(for: grant))
                    .font(.caption)
                    .foregroundStyle(status == .granted ? .green : .orange)

                if status != .granted {
                    Button(status == .partiallyGranted ? "Open Settings" : "Allow") {
                        openSystemSettings(for: grant)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.blue)
                }
            }

            Text(permissionManager.remediation(for: grant))
                .font(.caption2)
                .foregroundStyle(.secondary)

            DisclosureGroup("Details") {
                if let detail = permissionManager.debugDetail(for: grant) {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let evidence = permissionManager.evidence(for: grant) {
                    Text("Probe: \(evidence.source)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Observed: \(evidence.observed)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func statusColor(_ status: PermissionManager.GrantStatus) -> Color {
        switch status {
        case .granted: return .green
        case .denied: return .red
        case .unknown: return .orange
        case .partiallyGranted: return .orange
        case .restartRecommended: return .orange
        }
    }

    // MARK: - Deep Links

    /// Opens the relevant System Settings pane for the given TCC grant.
    /// BUG-FIX: Removed NSWorkspace.open() for grants that already trigger a native
    /// macOS system prompt (Accessibility, Screen Recording, Automation, Contacts).
    /// Opening System Settings simultaneously with the system prompt is redundant and
    /// disorienting. The prompt itself guides the user. Only Full Disk Access opens
    /// Settings directly since macOS provides no prompt for it.
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
            // Trigger the native Automation prompt only.
            Task {
                await permissionManager.requestAutomationAccess()
                await permissionManager.recheckAllForTruth()
            }
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
        default:
            // Full Disk Access: no native prompt exists — must open System Settings directly.
            switch grant {
            case .fullDiskAccess:
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            default:
                return
            }
            Task {
                await permissionManager.recheckAllForTruth()
            }
        }
    }
}
