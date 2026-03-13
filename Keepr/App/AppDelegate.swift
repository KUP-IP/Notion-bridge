// AppDelegate.swift — App Lifecycle + SMAppService Auto-Launch
// V1-02: Lifecycle wiring for menu bar app

import AppKit
import ServiceManagement

/// Manages app lifecycle and auto-launch registration via SMAppService.
/// SMAppService.mainApp.register() may fail if:
/// - User hasn't granted permission in System Settings > General > Login Items
/// - App is running from a non-standard location (e.g., ~/Downloads)
/// - App bundle is not properly signed
/// Error handling is explicit — failures are logged with actionable guidance.
public final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        registerAutoLaunch()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // Future: graceful MCP server shutdown, audit log flush
    }

    // MARK: - Auto-Launch

    private func registerAutoLaunch() {
        let service = SMAppService.mainApp
        do {
            try service.register()
            print("[Keepr] Auto-launch registered via SMAppService (\(service.status.rawValue))")
        } catch {
            print("[Keepr] SMAppService registration failed: \(error.localizedDescription)")
            print("[Keepr] To enable: System Settings > General > Login Items > toggle Keepr on")
        }
    }
}
