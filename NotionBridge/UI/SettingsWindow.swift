// SettingsWindow.swift — macOS Settings/Preferences Window
// V1.2.0: Sidebar NavigationSplitView layout (replaces TabView).
// Jobs tab removed. Content restructured per UI/UX audit.
// BridgeTheme design system adopted. Bug fixes applied.
//
// History:
// V1-QUALITY-C2: Original tabbed Settings window (General, Permissions,
//   Connections, Tools, Jobs, Advanced). Opens via gear icon or Cmd+,.
// V1.2.0: NavigationSplitView sidebar, Jobs removed, App Identity +
//   Security Model moved to Advanced, Reset Onboarding moved to Advanced,
//   status indicator added to General, BridgeTheme tokens adopted,
//   Build Target uses runtime version, "Since now" timestamp fixed.

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
        window.setContentSize(NSSize(width: 660, height: 540))
        window.minSize = NSSize(width: 580, height: 440)
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

    @State private var selectedSection: SettingsSection = .general

    // Token editing state (PKT-350 F1)
    @State private var isEditingToken = false
    @State private var newTokenValue = ""
    @State private var tokenError: String?
    @State private var tokenSaveSuccess = false
    @State private var showResetConfirmation = false
    @State private var isRecheckingPermissions = false
    @State private var permissionActionMessage: String?
    @State private var showTCCResetDialog = false

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general = "General"
        case permissions = "Permissions"
        case connections = "Connections"
        case tools = "Tools"
        case advanced = "Advanced"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .permissions: return "lock.shield"
            case .connections: return "network"
            case .tools: return "hammer"
            case .advanced: return "wrench.and.screwdriver"
            }
        }
    }

    public init(statusBar: StatusBarController, permissionManager: PermissionManager) {
        self.statusBar = statusBar
        self.permissionManager = permissionManager
    }

    public var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 200)
        } detail: {
            detailContent
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedSection {
        case .general: generalSection
        case .permissions: permissionsSection
        case .connections: connectionsSection
        case .tools: toolsSection
        case .advanced: advancedSection
        }
    }

    // MARK: - Shared Properties

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.0"
    }

    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = true
    @AppStorage("com.notionbridge.security.trustedMode") private var trustedMode: Bool = false

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

    /// Runtime build target string — replaces hardcoded "macOS 14+".
    private var buildTargetString: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion)"
    }

    /// Compact relative timestamp — mirrors DashboardView.relativeTime pattern.
    /// Fixes "Since now" edge case: returns "just now" for durations < 60s.
    private func relativeTimestamp(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        else if interval < 3600 { return "\(Int(interval / 60))m ago" }
        else if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        else { return "\(Int(interval / 86400))d ago" }
    }

    // MARK: - General

    private var generalSection: some View {
        Form {
            Section("Server") {
                LabeledContent("Status") {
                    HStack(spacing: BridgeSpacing.xs) {
                        Circle()
                            .fill(statusBar.isServerRunning ? BridgeColors.success : BridgeColors.error)
                            .frame(width: 8, height: 8)
                        Text(statusBar.isServerRunning ? "Running" : "Stopped")
                            .foregroundStyle(statusBar.isServerRunning ? BridgeColors.success : BridgeColors.error)
                    }
                }
                LabeledContent("Port", value: String(ssePort))
                LabeledContent("Tools", value: "\(statusBar.registeredToolCount) registered")
                LabeledContent("Uptime", value: statusBar.uptimeString)
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        Form {
            Section("TCC Permissions") {
                PermissionView(permissionManager: permissionManager)
            }

            Section("Sensitive Paths") {
                Text("First access to these paths triggers approval:")
                    .font(.caption)
                    .foregroundStyle(BridgeColors.secondary)
                VStack(alignment: .leading, spacing: BridgeSpacing.xxs) {
                    ForEach(["~/.ssh", "~/.aws", "~/.gnupg", "~/.config", "~/Library/Keychains"], id: \.self) { path in
                        HStack(spacing: BridgeSpacing.xs) {
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
                    Text("Last refreshed: \(lastCheckedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(BridgeColors.muted)
                }

                Button("Reset TCC for Notion Bridge (Developer)") {
                    showTCCResetDialog = true
                }
                .foregroundStyle(BridgeColors.error)
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
                        .foregroundStyle(BridgeColors.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Connections

    private var connectionsSection: some View {
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
                            .foregroundStyle(BridgeColors.error)
                    }

                    if tokenSaveSuccess {
                        Text("Token saved successfully!")
                            .font(.caption)
                            .foregroundStyle(BridgeColors.success)
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
                            .foregroundStyle(BridgeColors.secondary)
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
                        .foregroundStyle(BridgeColors.secondary)
                } else {
                    ForEach(statusBar.connectedClients, id: \.name) { client in
                        LabeledContent(client.name) {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("v\(client.version)")
                                    .font(.caption)
                                Text("Since \(relativeTimestamp(from: client.connectedAt))")
                                    .font(.caption2)
                                    .foregroundStyle(BridgeColors.muted)
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

    // MARK: - Tools

    private var toolsSection: some View {
        ToolRegistryView(
            tools: statusBar.toolInfoList,
            onToggle: { _, _ in
                let disabled = Set(UserDefaults.standard.stringArray(forKey: "com.notionbridge.disabledTools") ?? [])
                statusBar.registeredToolCount = statusBar.toolInfoList.count - disabled.count
            }
        )
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        Form {
            Section("Version") {
                LabeledContent("App Version", value: "v\(appVersion)")
                LabeledContent("MCP Protocol", value: "v2024-11-05")
                LabeledContent("Build Target", value: buildTargetString)
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
                    .foregroundStyle(BridgeColors.secondary)
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
                    .foregroundStyle(BridgeColors.secondary)
            }

            Section("Nuclear Handoff") {
                Text("System-critical commands (such as disk formatting or SIP configuration) are never executed directly. The exact terminal command is returned for you to run manually.")
                    .font(.caption)
                    .foregroundStyle(BridgeColors.secondary)
            }

            Section("Maintenance") {
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

            Section("Diagnostics") {
                Button("Export Diagnostics to Clipboard") {
                    exportDiagnostics()
                }
                .font(.caption)
                Text("Copies system info, tool list, and permission status for bug reports.")
                    .font(.caption2)
                    .foregroundStyle(BridgeColors.muted)
            }

            Section("About") {
                HStack(spacing: BridgeSpacing.xs) {
                    Image(systemName: "bridge.fill")
                        .foregroundStyle(.purple)
                    Text("Notion Bridge")
                        .fontWeight(.medium)
                    Text("— Local MCP server connecting AI assistants to your Mac.")
                        .foregroundStyle(BridgeColors.secondary)
                }
                .font(.callout)

                Link(destination: URL(string: "https://kup.solutions")!) {
                    HStack(spacing: BridgeSpacing.xxs) {
                        Image(systemName: "globe")
                            .font(.caption)
                        Text("kup.solutions")
                            .font(.caption)
                    }
                }

                Text("© 2026 KUP Solutions. All rights reserved.")
                    .font(.caption2)
                    .foregroundStyle(BridgeColors.muted)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Token Management

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

    // MARK: - Diagnostics

    private func exportDiagnostics() {
        let lines = [
            "Notion Bridge Diagnostics",
            "========================",
            "App Version: v\(appVersion)",
            "MCP Protocol: v2024-11-05",
            "Build Target: \(buildTargetString)",
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
