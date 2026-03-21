// SettingsWindow+Sections.swift — Settings Section Views
// V3-QUALITY D1-D5: Extracted from SettingsWindow.swift monolith.
// Each section is an extension on SettingsView for clean separation.

import SwiftUI
import ServiceManagement

extension SettingsView {
    // MARK: - General

    var generalSection: some View {
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

            // PKT-375: Configurable screen output directory
            Section("Screen Output") {
                LabeledContent("Save Location") {
                    HStack(spacing: BridgeSpacing.xs) {
                        Text(screenOutputDir)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Button("Choose\u{2026}") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.allowsMultipleSelection = false
                            panel.prompt = "Select"
                            panel.message = "Choose where screen captures and recordings are saved."
                            panel.directoryURL = URL(fileURLWithPath: screenOutputDir)
                            if panel.runModal() == .OK, let url = panel.url {
                                screenOutputDir = url.path
                                ConfigManager.shared.screenOutputDir = url.path
                            }
                        }
                    }
                }
                Text("Screen captures and recordings will be saved here instead of /tmp. Default: ~/Desktop")
                    .font(.caption)
                    .foregroundStyle(BridgeColors.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshLearnedAllowPrefixes()
        }
    }

    // MARK: - Permissions

    var permissionsSection: some View {
        Form {
            Section("TCC Permissions") {
                PermissionView(permissionManager: permissionManager)
            }

            // PKT-363 D3 + D4: Configurable sensitive paths editor
            SensitivePathsEditor()

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

    var connectionsSection: some View {
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

            Section("Workspace Connections") {
                ConnectionsManagementView()
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

    var toolsSection: some View {
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

    var skillsSection: some View {
        let disabledTools = Set(UserDefaults.standard.stringArray(forKey: "com.notionbridge.disabledTools") ?? [])
        return SkillsView(
            skillsManager: skillsManager,
            fetchSkillDisabled: disabledTools.contains("fetch_skill")
        )
    }


    // MARK: - Credentials (PKT-372)

    var credentialsSection: some View {
        CredentialsView()
    }

    // MARK: - Advanced

    var advancedSection: some View {
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
                LabeledContent("Model", value: "3-Tier (Open / Notify / Request)")
                Text("Open executes immediately, Notify executes and alerts, Request asks approval before running. Notification actions support Allow, Deny, and Always Allow.")
                    .font(.caption)
                    .foregroundStyle(BridgeColors.secondary)
            }

            Section("Learned Command Allows") {
                if learnedAllowPrefixes.isEmpty {
                    Text("No learned command prefixes yet. Use \"Always Allow\" from a Request-tier approval to add one.")
                        .font(.caption)
                        .foregroundStyle(BridgeColors.secondary)
                } else {
                    ForEach(learnedAllowPrefixes, id: \.self) { prefix in
                        HStack(spacing: BridgeSpacing.xs) {
                            Text(prefix)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button(role: .destructive) {
                                removeLearnedAllowPrefix(prefix)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    Button(role: .destructive) {
                        ConfigManager.shared.clearLearnedAllowPrefixes()
                        refreshLearnedAllowPrefixes()
                    } label: {
                        Text("Clear All")
                    }
                    .disabled(learnedAllowPrefixes.isEmpty)
                }
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

            Section("Nuclear Handoff") {
                Text("Fork-bomb command patterns are never executed directly. The exact terminal command is returned for manual execution.")
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
    func saveToken() {
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

    func exportDiagnostics() {
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
            "Learned Allow Prefixes: \(learnedAllowPrefixes.count)",
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

    func refreshLearnedAllowPrefixes() {
        learnedAllowPrefixes = ConfigManager.shared.learnedAllowPrefixes.sorted()
    }

    func removeLearnedAllowPrefix(_ prefix: String) {
        ConfigManager.shared.removeLearnedAllowPrefix(prefix)
        refreshLearnedAllowPrefixes()
    }

    // MARK: - Permissions Helpers

    func resetTCCPermissions() async -> (message: String, didFail: Bool) {
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
