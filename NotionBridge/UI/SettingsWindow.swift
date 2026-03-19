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
// PKT-362 D2: Removed Sensitive Paths section from Permissions tab.
// PKT-362 D3: Re-check All uses animatedRecheckAll() for per-row feedback.
// PKT-362 D4: Reset TCC dialog rewritten with user-facing language.
// PKT-362 D5: Post-reset guided instruction sheet with deep links + restart.

import SwiftUI
import ServiceManagement
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
        window.setContentSize(NSSize(width: 723, height: 873))
        window.minSize = NSSize(width: 620, height: 700)
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
    // PKT-362 D5: Post-reset guided instruction sheet
    @State private var showPostResetSheet = false

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general = "General"
        case permissions = "Permissions"
        case connections = "Connections"
        case tools = "Tools"
        case skills = "Skills"
        case advanced = "Advanced"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .permissions: return "lock.shield"
            case .connections: return "network"
            case .tools: return "hammer"
            case .skills: return "book.closed"
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
        case .skills: skillsSection
        case .advanced: advancedSection
        }
    }

    // MARK: - Shared Properties

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.0"
    }

    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("com.notionbridge.security.trustedMode") private var trustedMode: Bool = false

    private var ssePort: Int {
        Int(ProcessInfo.processInfo.environment["NOTION_BRIDGE_PORT"] ?? "") ?? 9700
    }

    private var maskedTokenLabel: String {
        let masked = NotionTokenResolver.maskedToken()
        if masked == "Not configured" {
            return "Not configured \u{26A0}\u{FE0F}"
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
                    .onChange(of: launchAtLogin) { _, enabled in
                        let service = SMAppService.mainApp
                        if enabled {
                            try? service.unregister() // remove stale entries first
                            try? service.register()
                        } else {
                            try? service.unregister()
                        }
                    }
            }

            Section("App Control") {
                Button("Restart Notion Bridge", systemImage: "arrow.clockwise") {
                    restartApp(reopenSettings: true)
                }
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

            // PKT-362 D2: Sensitive Paths section REMOVED.
            // Hardcoded path list (~/.ssh, ~/.aws, ~/.gnupg, ~/.config, ~/Library/Keychains)
            // served no interactive purpose. Documented in README instead.

            Section {
                // PKT-362 D3: Uses animatedRecheckAll() for per-row animated feedback
                Button(isRecheckingPermissions ? "Re-checking\u{2026}" : "Re-check All Permissions") {
                    isRecheckingPermissions = true
                    permissionActionMessage = nil
                    Task {
                        await permissionManager.animatedRecheckAll()
                        isRecheckingPermissions = false
                        permissionActionMessage = "Permission state refreshed at \(Date().formatted(date: .omitted, time: .standard))."
                    }
                }
                .disabled(isRecheckingPermissions)

                if let lastCheckedAt = permissionManager.lastCheckedAt {
                    Text("Last refreshed: \(lastCheckedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(BridgeColors.muted)
                }

                // PKT-362 D4: User-facing language, no tccutil/bundle ID references
                Button("Reset All Permissions") {
                    showTCCResetDialog = true
                }
                .foregroundStyle(BridgeColors.error)
                .confirmationDialog(
                    "Reset all permissions for NotionBridge?",
                    isPresented: $showTCCResetDialog,
                    titleVisibility: .visible
                ) {
                    Button("Reset", role: .destructive) {
                        Task {
                            let resetResult = await resetTCCPermissions()
                            permissionActionMessage = resetResult.message
                            // PKT-362 D5: Show post-reset guided instruction sheet
                            showPostResetSheet = true
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    // PKT-362 D4: Plain-language copy — no mention of tccutil,
                    // bundle IDs, or internal implementation details.
                    Text("This will reset all system permissions for NotionBridge. You\u{2019}ll need to re-grant each permission after resetting.")
                }

                if let permissionActionMessage {
                    Text(permissionActionMessage)
                        .font(.caption)
                        .foregroundStyle(BridgeColors.secondary)
                }
            }
        }
        .formStyle(.grouped)
        // PKT-362 D5: Post-reset guided instruction sheet
        .sheet(isPresented: $showPostResetSheet) {
            PostResetSheet(permissionManager: permissionManager)
        }
    }

    // MARK: - Connections

    private var connectionsSection: some View {
        Form {
            Section("Local Server") {
                LabeledContent("Streamable HTTP") {
                    Text(verbatim: "http://localhost:\(ssePort)/mcp")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Legacy SSE") {
                    Text(verbatim: "http://localhost:\(ssePort)/sse")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Health Check") {
                    Text(verbatim: "http://localhost:\(ssePort)/health")
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

    // PKT-366 F9: Skills manager for Skills tab
    @State private var skillsManager = SkillsManager()

    private var toolsSection: some View {
        ToolRegistryView(
            tools: statusBar.toolInfoList,
            onToggle: { _, _ in
                let disabled = Set(UserDefaults.standard.stringArray(forKey: "com.notionbridge.disabledTools") ?? [])
                statusBar.registeredToolCount = statusBar.toolInfoList.count - disabled.count
            },
            notificationDenied: permissionManager.notificationStatus != .granted
        )
    }

    // MARK: - Skills (PKT-366 F9)

    private var skillsSection: some View {
        let disabledTools = Set(UserDefaults.standard.stringArray(forKey: "com.notionbridge.disabledTools") ?? [])
        return SkillsView(
            skillsManager: skillsManager,
            fetchSkillDisabled: disabledTools.contains("fetch_skill")
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
                    Text("\u{2014} Local MCP server connecting AI assistants to your Mac.")
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

                Text("\u{00A9} 2026 KUP Solutions. All rights reserved.")
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
            "  Notifications: \(permissionManager.notificationStatus)",
        ].joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines, forType: .string)
    }

    // MARK: - Permissions Helpers

    private func resetTCCPermissions() async -> (message: String, didFail: Bool) {
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
            return (message: "Permissions reset. Follow the steps below to re-grant access.", didFail: false)
        }
        return (message: "Reset partially failed. Some permissions may need to be reset manually in System Settings.", didFail: true)
    }
}

// MARK: - PKT-362 D5: Post-Reset Guided Instruction Sheet

/// Presented after TCC reset completes. Shows an ordered list of each V1 grant
/// with a deep link button to the corresponding System Settings pane, plus a
/// "Restart NotionBridge" button at the bottom. Dismisses on restart.
private struct PostResetSheet: View {
    let permissionManager: PermissionManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            // Header
            Image(systemName: "lock.shield")
                .font(.largeTitle)
                .foregroundStyle(.orange)

            Text("Re-grant Permissions")
                .font(.headline)

            Text("Notion Bridge permissions have been reset. Open each setting below to re-grant access, then restart the app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider()

            // Ordered grant list with deep links
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(PermissionManager.Grant.v1Cases.enumerated()), id: \.element.id) { index, grant in
                    HStack(spacing: 12) {
                        // Step number
                        Text("\(index + 1)")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(.blue))

                        // Grant name + current status
                        VStack(alignment: .leading, spacing: 2) {
                            Text(grant.displayName)
                                .font(.callout)
                            Text(permissionManager.statusLabel(for: grant))
                                .font(.caption2)
                                .foregroundStyle(
                                    permissionManager.status(for: grant) == .granted
                                        ? .green : .orange
                                )
                        }

                        Spacer()

                        // Deep link button
                        if let url = grant.systemSettingsURL {
                            Button("Open Settings") {
                                NSWorkspace.shared.open(url)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            Divider()

            // Restart button
            Button {
                let bundlePath = Bundle.main.bundlePath
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/sh")
                task.arguments = ["-c", "sleep 1 && open '\(bundlePath)'"]
                try? task.run()
                NSApp.terminate(nil)
            } label: {
                Label("Restart Notion Bridge", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            // Dismiss option
            Button("Close") {
                dismiss()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 420)
    }
}
