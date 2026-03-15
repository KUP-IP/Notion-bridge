// KeeprApp.swift — @main App Entry Point
// Notion Bridge v1: Unified menu bar app + MCP server in a single binary
// PKT-317: StatusBarController now owned by AppDelegate (server wires it on launch)
// PKT-341: PermissionManager now owned by AppDelegate (TCC check on launch)
// No Dock icon — pure menu bar app via MenuBarExtra pattern

import SwiftUI
import KeeprLib

/// Load menu bar icon from SPM-processed resources.
/// Uses the Golden Gate Bridge logo as a template image for the menu bar.
/// @2x variant (notionbridge-menubar@2x.png) is resolved automatically by NSImage.
private func loadMenuBarIcon() -> NSImage? {
    guard let pngPath = Bundle.module.path(forResource: "notionbridge-menubar", ofType: "png"),
          let nsImage = NSImage(contentsOfFile: pngPath) else {
        return nil
    }
    nsImage.size = NSSize(width: 18, height: 18)
    nsImage.isTemplate = true
    return nsImage
}

@main
struct KeeprApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// Pre-load the icon once to avoid repeated loading in body evaluations
    private let menuBarIcon: NSImage? = loadMenuBarIcon()

    var body: some Scene {
        MenuBarExtra {
            DashboardView(statusBar: appDelegate.statusBar, permissionManager: appDelegate.permissionManager)
                .frame(width: 320, height: 460)
                .onAppear {
                    // Secondary refresh on popover open (primary check is on launch)
                    appDelegate.permissionManager.checkAll()
                }
        } label: {
            if let icon = menuBarIcon {
                Image(nsImage: icon)
            } else {
                Image(systemName: "sparkle")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
