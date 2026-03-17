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

    // PKT-350 F1: Token editing state
    @State private var isEditingToken = false
    @State private var newTokenValue = ""
    @State private var tokenError: String?
    @State private var tokenSaveSuccess = false
    @State private var showResetConfirmation = false
    @State private var isRecheckingPermissions = false
    @State private var permissionActionMessage: String?
    @State private var showTCCResetDialog = false

    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case permissions = "Permissions"
        case connections = "Connections"
        case tools = "Tools"
        case jobs = "Jobs"
        case advanced = "Advanced"

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .permissions: return "lock.shield"
            case .connections: return "network"
            case .tools: return "hammer"
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

            toolsTab
                .tabItem {
                    Label(SettingsTab.tools.rawValue, systemImage: SettingsTab.tools.icon)
                }
                .tag(SettingsTab.tools)

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
    @AppStorage("com.notionbridge.security.trustedMode") private var trustedMode: Bool = false

    private var generalTab: some View {
        Form {
            Section("Server") {
                LabeledContent("Status", value: statusBar.isServerRunning ? "Running" : "Stopped")
                LabeledContent("Port", value: String(ssePort))
                LabeledContent("Tools", value: "\(statusBar.registeredToolCount) registered")
                LabeledContent("Uptime", value: statusBar.uptimeString)
            }


            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)

                Button("Reset Onboarding") {
                    showResetConfirmation = true
                }
                .font(.caption)
                .confirmationDialog(
                    "Reset Onboarding?",
                    isPresented: $showResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Reset", role: .destructive) {
                        UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                        NotificationCenter.default.post(name: .resetOnboarding, object: nil)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will restart the setup wizard. Your settings and data will not be affected.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var ssePort: Int {
        Int(ProcessInfo.processInfo.environment["NOTION_BRIDGE_PORT"] ?? "") ?? 9700
    }

    private var maskedTokenLabel: String {
        let masked = NotionTokenResolver.maskedToken()
        if masked == "Not configured" {
            return "Not configured ⚠️"
        }
        return masked
    }

    /// Save token with validation and error handling (PKT-350: F1).
    private func saveToken() {
        let validation = NotionTokenResolver.validateTokenFormat(newTokenValue)
        guard validation.valid else {
            tokenError = validation.error
            return
        }
        do {
            try NotionTokenResolver.writeToken(newTokenValue)
            tokenError = nil
            tokenSaveSuccess = true
            isEditingToken = false
            newTokenValue = ""
            NotificationCenter.default.post(name: .notionTokenDidChange, object: nil)
        } catch {
            tokenError = "Save failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Tools Tab (PKT-350: F2)

    private var toolsTab: some View {
        ToolRegistryView(
            tools: statusBar.toolInfoList,
            onToggle: { _, _ in
                let disabled = Set(UserDefaults.standard.stringArray(forKey: "com.notionbridge.disabledTools") ?? [])
                statusBar.registeredToolCount = statusBar.toolInfoList.count - disabled.count
            }
        )
    }

    // MARK: - Permissions Tab

    private var permissionsTab: some View {
        Form {
            Section("TCC Permissions") {
                PermissionView(permissionManager: permissionManager)
            }

            Section("App Identity") {
                LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "unknown")
                LabeledContent("App Path") {
                    Text(Bundle.main.bundleURL.path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                LabeledContent("Executable") {
                    Text(Bundle.main.executableURL?.path ?? "unknown")
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
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
                Button(isRecheckingPermissions ? "Re-checking…" : "Re-check All Permissions") {
                    isRecheckingPermissions = true
                    permissionActionMessage = nil
                    Task {
                        await permissionManager.recheckAllForTruth()
                        await MainActor.run {
                            isRecheckingPermissions = false
                            permissionActionMessage = "Permission state refreshed at \(Date().formatted(date: .omitted, time: .standard))."
                        }
                    }
                }
                .disabled(isRecheckingPermissions)

                if let lastCheckedAt = permissionManager.lastCheckedAt {
                    Text("Last truth refresh: \(lastCheckedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Button("Reset TCC for Notion Bridge (Developer)") {
                    showTCCResetDialog = true
                }
                .foregroundStyle(.red)
                .confirmationDialog(
                    "Reset all Notion Bridge TCC permissions?",
                    isPresented: $showTCCResetDialog,
                    titleVisibility: .visible
                ) {
                    Button("Reset", role: .destructive) {
                        Task {
                            let resetResult = await resetTCCPermissions()
                            await MainActor.run {
                                permissionActionMessage = resetResult
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This runs tccutil reset All for both current and legacy bundle IDs. macOS will prompt for permissions again.")
                }

                if let permissionActionMessage {
                    Text(permissionActionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

            Section("Notion API") {
                if isEditingToken {
                    SecureField("Paste new token", text: $newTokenValue)
                        .textFieldStyle(.roundedBorder)

                    if let error = tokenError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if tokenSaveSuccess {
                        Text("Token saved successfully!")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    HStack {
                        Button("Save") {
                            saveToken()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Cancel") {
                            isEditingToken = false
                            newTokenValue = ""
                            tokenError = nil
                            tokenSaveSuccess = false
                        }
                    }
                } else {
                    HStack {
                        LabeledContent("Token", value: maskedTokenLabel)
                        Button {
                            isEditingToken = true
                            tokenSaveSuccess = false
                            tokenError = nil
                        } label: {
                            Image(systemName: "pencil")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                    }
                    if !statusBar.notionTokenDetail.isEmpty {
                        Text(statusBar.notionTokenDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Setup Instructions") {
                Link(destination: URL(string: "https://www.notion.so/profile/integrations")!) {
                    HStack {
                        Image(systemName: "globe")
                        Text("Create an internal integration at notion.so/profile/integrations")
                            .font(.caption)
                    }
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
                    Button {
                        let logPath = NSString("~/Library/Logs/NotionBridge").expandingTildeInPath
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: logPath)
                    } label: {
                        Text("~/Library/Logs/NotionBridge/")
                            .font(.system(.caption, design: .monospaced))
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Security") {
                Toggle("Trusted Mode", isOn: $trustedMode)
                Text("When enabled, Notify-tier commands execute without approval prompts. Use with caution.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Nuclear Handoff") {
                Text("System-critical commands (such as disk formatting or SIP configuration) are never executed directly. The exact terminal command is returned for you to run manually.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                Button("Export Diagnostics to Clipboard") {
                    exportDiagnostics()
                }
                .font(.caption)
                Text("Copies system info, tool list, and permission status for bug reports.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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

                Link(destination: URL(string: "https://kup.solutions")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.caption)
                        Text("kup.solutions")
                            .font(.caption)
                    }
                }

                Text("© 2026 KUP Solutions. All rights reserved.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Diagnostics (F16)

    private func exportDiagnostics() {
        let lines = [
            "Notion Bridge Diagnostics",
            "========================",
            "App Version: v\(appVersion)",
            "MCP Protocol: 2024-11-05",
            "Port: \(ssePort)",
            "Server Running: \(statusBar.isServerRunning)",
            "Tools Registered: \(statusBar.registeredToolCount)",
            "Uptime: \(statusBar.uptimeString)",
            "Trusted Mode: \(trustedMode)",
            "",
            "Permissions:",
            "  Accessibility: \(permissionManager.accessibilityStatus)",
            "  Screen Recording: \(permissionManager.screenRecordingStatus)",
            "  Full Disk Access: \(permissionManager.fullDiskAccessStatus)",
            "  Automation: \(permissionManager.automationStatus)",
            "  Contacts: \(permissionManager.contactsStatus)",
        ].joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines, forType: .string)
    }

    // MARK: - Permissions Helpers

    private func resetTCCPermissions() async -> String {
        let ids = ["kup.solutions.notion-bridge", "solutions.kup.keepr"]
        var failures: [String] = []

        for id in ids {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", "All", id]
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    failures.append(id)
                }
            } catch {
                failures.append(id)
            }
        }

        await permissionManager.recheckAllForTruth()
        if failures.isEmpty {
            return "TCC reset complete. Relaunch Notion Bridge and grant permissions again."
        }
        return "TCC reset partially failed for: \(failures.joined(separator: ", ")). You may need to run tccutil manually."
    }
}
