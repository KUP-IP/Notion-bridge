// SettingsWindow.swift — macOS Settings/Preferences Window
// V1-QUALITY-C2: Standard tabbed Settings window with General, Permissions,
// Connections, Jobs, and Advanced tabs. Opens via gear icon or Cmd+,.

import SwiftUI
import AppKit

// PKT-349 B2: Notification name for reset onboarding action
extension Notification.Name {
    static let resetOnboarding = Notification.Name("com.notionbridge.resetOnboarding")
}

/// Manages the Settings NSWindow. Opens via gear icon in popover or Cmd+,.
@MainActor
public final class SettingsWindowController {
    private var window: NSWindow?
    private let statusBar: StatusBarController
    private let permissionManager: PermissionManager

    public init(statusBar: StatusBarController, permissionManager: PermissionManager) {
        self.statusBar = statusBar
        self.permissionManager = permissionManager
    }

    /// Show the Settings window, or bring it to front if already open.
    public func show() {
        if let existingWindow = window, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(
            statusBar: statusBar,
            permissionManager: permissionManager
        )

        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Notion Bridge Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 560, height: 420))
        window.minSize = NSSize(width: 480, height: 360)
        window.center()
        window.isReleasedWhenClosed = false

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        print("[Settings] Window opened")
    }
}

// MARK: - Settings View

public struct SettingsView: View {
    let statusBar: StatusBarController
    let permissionManager: PermissionManager

    @State private var selectedTab: SettingsTab = .general

    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case permissions = "Permissions"
        case connections = "Connections"
        case jobs = "Jobs"
        case advanced = "Advanced"

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .permissions: return "lock.shield"
            case .connections: return "network"
            case .jobs: return "clock.arrow.2.circlepath"
            case .advanced: return "wrench.and.screwdriver"
            }
        }
    }

    public init(statusBar: StatusBarController, permissionManager: PermissionManager) {
        self.statusBar = statusBar
        self.permissionManager = permissionManager
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem {
                    Label(SettingsTab.general.rawValue, systemImage: SettingsTab.general.icon)
                }
                .tag(SettingsTab.general)

            permissionsTab
                .tabItem {
                    Label(SettingsTab.permissions.rawValue, systemImage: SettingsTab.permissions.icon)
                }
                .tag(SettingsTab.permissions)

            connectionsTab
                .tabItem {
                    Label(SettingsTab.connections.rawValue, systemImage: SettingsTab.connections.icon)
                }
                .tag(SettingsTab.connections)

            jobsTab
                .tabItem {
                    Label(SettingsTab.jobs.rawValue, systemImage: SettingsTab.jobs.icon)
                }
                .tag(SettingsTab.jobs)

            advancedTab
                .tabItem {
                    Label(SettingsTab.advanced.rawValue, systemImage: SettingsTab.advanced.icon)
                }
                .tag(SettingsTab.advanced)
        }
        .padding(20)
    }

    // MARK: - General Tab

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0"
    }

    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = true

    private var generalTab: some View {
        Form {
            Section("Server") {
                LabeledContent("Status", value: statusBar.isServerRunning ? "Running" : "Stopped")
                LabeledContent("Port", value: "\(ssePort)")
                LabeledContent("Tools", value: "\(statusBar.registeredToolCount) registered")
                LabeledContent("Uptime", value: statusBar.uptimeString)
            }

            Section("Notion API") {
                LabeledContent("Token", value: notionTokenLabel)
                if !statusBar.notionTokenDetail.isEmpty {
                    Text(statusBar.notionTokenDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)

                Button("Reset Onboarding") {
                    UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                    // PKT-349 B2: Notify AppDelegate to re-present onboarding window
                    NotificationCenter.default.post(name: .resetOnboarding, object: nil)
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    private var ssePort: Int {
        Int(ProcessInfo.processInfo.environment["NOTION_BRIDGE_PORT"] ?? "") ?? 9700
    }

    private var notionTokenLabel: String {
        switch statusBar.notionTokenStatus {
        case "connected": return "Connected ✅"
        case "disconnected": return "Disconnected ⚠️"
        default: return "Missing"
        }
    }

    // MARK: - Permissions Tab

    private var permissionsTab: some View {
        Form {
            Section("TCC Permissions") {
                PermissionView(permissionManager: permissionManager)
            }

            Section("Security Model") {
                LabeledContent("Model", value: "2-Tier (Open / Notify)")
                Text("Open tier: read operations execute immediately. Notify tier: destructive operations require approval via notification.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sensitive Paths") {
                Text("First access to these paths triggers approval:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(["~/.ssh", "~/.aws", "~/.gnupg", "~/.config", "~/Library/Keychains"], id: \.self) { path in
                        HStack(spacing: 6) {
                            Image(systemName: "folder.badge.questionmark")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Text(path)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
            }

            Section {
                Button("Re-check All Permissions") {
                    permissionManager.checkAll()
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Connections Tab

    private var connectionsTab: some View {
        Form {
            Section("Local Server") {
                LabeledContent("Streamable HTTP") {
                    Text("http://localhost:\(ssePort)/mcp")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Legacy SSE") {
                    Text("http://localhost:\(ssePort)/sse")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Health Check") {
                    Text("http://localhost:\(ssePort)/health")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Section("Connected Clients") {
                if statusBar.connectedClients.isEmpty {
                    Text("No clients connected")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(statusBar.connectedClients, id: \.name) { client in
                        LabeledContent(client.name) {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("v\(client.version)")
                                    .font(.caption)
                                Text("Since \(client.connectedAt.formatted(.relative(presentation: .named)))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Tunnel") {
                ConnectionSetupView()
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Jobs Tab (Placeholder for V2-SCHEDULER)

    private var jobsTab: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "clock.arrow.2.circlepath")
                .font(.system(size: 48))
                .foregroundStyle(.gray.opacity(0.5))

            Text("Scheduled Jobs")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            Text("Coming soon — scheduled automation jobs will appear here.\nRun recurring tasks, health checks, and maintenance on a schedule.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()
        }
    }

    // MARK: - Advanced Tab

    private var advancedTab: some View {
        Form {
            Section("Version") {
                LabeledContent("App Version", value: "v\(appVersion)")
                LabeledContent("MCP Protocol", value: "2024-11-05")
                LabeledContent("Build Target", value: "macOS 14+")
            }

            Section("Logging") {
                LabeledContent("Log Directory") {
                    Text("~/Library/Logs/NotionBridge/")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                Button("Open in Finder") {
                    let logPath = NSString("~/Library/Logs/NotionBridge").expandingTildeInPath
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: logPath)
                }
                .font(.caption)
            }

            Section("Nuclear Handoff") {
                Text("System-critical commands (e.g., diskutil eraseDisk, csrutil disable) are never executed. Instead, the exact terminal command is returned for you to run manually.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                HStack(spacing: 8) {
                    Image(systemName: "bridge.fill")
                        .foregroundStyle(.purple)
                    Text("Notion Bridge")
                        .fontWeight(.medium)
                    Text("— Local MCP server connecting AI assistants to your Mac.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)

                Text("© 2026 KUP Solutions. All rights reserved.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }
}
