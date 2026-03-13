// KeeprApp.swift — @main App Entry Point
// V1-02: Menu bar app shell with MenuBarExtra
// No Dock icon — pure menu bar app via MenuBarExtra pattern

import SwiftUI
import KeeprLib

@main
struct KeeprApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var statusBar = StatusBarController()
    @State private var permissionManager = PermissionManager()

    var body: some Scene {
        MenuBarExtra {
            DashboardView(statusBar: statusBar, permissionManager: permissionManager)
                .frame(width: 320, height: 460)
                .onAppear {
                    permissionManager.checkAll()
                }
        } label: {
            // SF Symbol placeholder for v1 app icon
            Image(systemName: "bridge.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
