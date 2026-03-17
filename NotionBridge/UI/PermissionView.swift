// PermissionView.swift — TCC Grant Status Display
// V1-02: Shows green/red status per grant with "Open System Settings" deep links
// for all 5 required TCC grants.
// PKT-341: Added rebuild note explaining TCC grant invalidation
// PKT-349 B3: Added permission pre-triggers for Automation and Contacts grants
//   (mirrors D2 pattern from OnboardingWindow.swift)
// PKT-357 F14: Auto-refresh permission status every 2s while view is visible

import SwiftUI
import Combine

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
            ForEach(PermissionManager.Grant.allCases) { grant in
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
    }

    // MARK: - Row

    private func permissionRow(
        grant: PermissionManager.Grant,
        status: PermissionManager.GrantStatus
    ) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 8, height: 8)

            Text(grant.displayName)
                .font(.callout)

            Spacer()

            if status == .granted {
                Text("Granted")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button("Open Settings") {
                    openSystemSettings(for: grant)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.blue)
            }
        }
    }

    private func statusColor(_ status: PermissionManager.GrantStatus) -> Color {
        switch status {
        case .granted: return .green
        case .denied: return .red
        case .unknown: return .orange
        }
    }

    // MARK: - Deep Links

    /// Opens the relevant System Settings pane for the given TCC grant.
    /// Uses x-apple.systempreferences URL scheme for macOS 13+.
    /// PKT-349 B3: Automation and Contacts grants now pre-trigger the system
    /// permission prompt before opening Settings (mirrors D2 pattern from
    /// OnboardingWindow.swift) so the app appears in the System Settings list.
    private func openSystemSettings(for grant: PermissionManager.Grant) {
        switch grant {
        case .automation:
            // Pre-trigger Automation system prompt via NSAppleScript probe,
            // then open Settings after a short delay for TCC registration
            permissionManager.checkAutomation()
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .contacts:
            // Pre-trigger Contacts system prompt via CNContactStore request,
            // then open Settings once the prompt has registered with TCC
            Task {
                _ = await permissionManager.requestContactsAccess()
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
                    NSWorkspace.shared.open(url)
                }
            }
        default:
            // Accessibility, Screen Recording, Full Disk Access — open directly
            let urlString: String
            switch grant {
            case .accessibility:
                urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            case .screenRecording:
                urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            case .fullDiskAccess:
                urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
            default:
                return
            }
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
