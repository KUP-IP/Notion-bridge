// KeeprApp.swift — @main App Entry Point
// Notion Bridge v1: Unified menu bar app + MCP server in a single binary
// PKT-317: StatusBarController now owned by AppDelegate (server wires it on launch)
// No Dock icon — pure menu bar app via MenuBarExtra pattern

import SwiftUI
import KeeprLib

/// Load menu bar icon from SPM-processed resources (loose PNG, not asset catalog).
/// Uses the Golden Gate Bridge logo as a template image for the menu bar.
private func loadMenuBarIcon() -> NSImage? {
    guard let nsImage = Bundle.module.image(forResource: "notionbridge-menubar") else {
        return nil
    }
    let copy = nsImage.copy() as! NSImage
    copy.size = NSSize(width: 18, height: 18)
    copy.isTemplate = true
    return copy
}

@main
struct KeeprApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var permissionManager = PermissionManager()

    var body: some Scene {
        MenuBarExtra {
            DashboardView(statusBar: appDelegate.statusBar, permissionManager: permissionManager)
                .frame(width: 320, height: 460)
                .onAppear {
                    permissionManager.checkAll()
                }
        } label: {
            if let icon = loadMenuBarIcon() {
                Image(nsImage: icon)
            } else {
                Image(systemName: "sparkle")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
