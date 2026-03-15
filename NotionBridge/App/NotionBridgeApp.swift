// NotionBridgeApp.swift — @main App Entry Point
// Notion Bridge v1: Unified menu bar app + MCP server in a single binary
// PKT-317: StatusBarController now owned by AppDelegate (server wires it on launch)
// PKT-341: PermissionManager now owned by AppDelegate (TCC check on launch)
// PKT-342: Menu bar icon now loaded from Assets.xcassets (Asset Catalog)
// V1-QUALITY-C2: Slim popover (~200px), gear icon opens SettingsWindow,
//   first-launch onboarding window, Cmd+, shortcut for Settings.
// No Dock icon — pure menu bar app via MenuBarExtra pattern

import SwiftUI
import NotionBridgeLib

/// Load menu bar icon from Asset Catalog (xcassets).
/// Uses the Golden Gate Bridge logo as a template image for the menu bar.
/// @2x variant is resolved automatically by the Asset Catalog at runtime.
/// PKT-349 B1: Bundle.module can fail for SPM executable targets —
/// try main bundle first (works in .app packaging), then module bundle.
private func loadMenuBarIcon() -> NSImage? {
    let nsImage: NSImage? =
        Bundle.main.image(forResource: "MenuBarIcon")
        ?? Bundle.module.image(forResource: "MenuBarIcon")
    guard let nsImage else { return nil }
    nsImage.size = NSSize(width: 18, height: 18)
    nsImage.isTemplate = true
    return nsImage
}

@main
struct NotionBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// Pre-load the icon once to avoid repeated loading in body evaluations
    private let menuBarIcon: NSImage? = loadMenuBarIcon()

    var body: some Scene {
        MenuBarExtra {
            DashboardView(
                statusBar: appDelegate.statusBar,
                onOpenSettings: {
                    appDelegate.openSettings()
                }
            )
            .frame(width: 280, height: 220)
        } label: {
            if let icon = menuBarIcon {
                Image(nsImage: icon)
            } else {
                Image(systemName: "sparkle")
            }
        }
        .menuBarExtraStyle(.window)

        // V1-QUALITY-C2: Cmd+, keyboard shortcut opens Settings window
        Settings {
            SettingsView(
                statusBar: appDelegate.statusBar,
                permissionManager: appDelegate.permissionManager
            )
        }
    }
}
