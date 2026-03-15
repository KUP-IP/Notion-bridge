// PermissionView.swift — TCC Grant Status Display
// V1-02: Shows green/red status per grant with "Open System Settings" deep links
// for all 5 required TCC grants.
// PKT-341: Added rebuild note explaining TCC grant invalidation

import SwiftUI

/// Displays the 5-grant TCC permission status grid.
/// Each row shows a colored indicator (green = granted, red = denied/unknown)
/// and a deep link button to the relevant System Settings pane for denied grants.
public struct PermissionView: View {
    let permissionManager: PermissionManager

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
    private func openSystemSettings(for grant: PermissionManager.Grant) {
        let urlString: String
        switch grant {
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .fullDiskAccess:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case .automation:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        case .contacts:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
        }

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
