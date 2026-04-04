// SettingsWindow+Sections.swift — Settings Section Views
// V3-QUALITY D1-D5: Extracted from SettingsWindow.swift monolith.
// Each section is an extension on SettingsView for clean separation.

import SwiftUI
import ServiceManagement

extension SettingsView {
    /// Factory Reset confirmation — skills defaults, env-based Notion token, restart guidance.
    var factoryResetConfirmationMessage: String {
        """
        This will clear: SSE port, learned command allows, stored credentials (Notion workspace tokens and Stripe), onboarding state, and macOS permissions for Notion Bridge.

        Skills are restored to the built-in default set (three placeholder entries), not wiped empty.

        If the app is launched with NOTION_API_TOKEN or NOTION_API_KEY in the environment, Notion may still resolve a token after reset (developer convenience). Unset those variables for a fully clean test.

        Restart the app after reset so permission and connection status stay accurate.
        """
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
                        guard !isApplyingLaunchAtLoginChange else { return }
                        launchAtLoginError = nil
                        let service = SMAppService.mainApp
                        do {
                            if enabled {
                                try service.unregister()
                                try service.register()
                            } else {
                                try service.unregister()
                            }
                        } catch {
                            launchAtLoginError = "Could not update launch-at-login: \(error.localizedDescription)"
                            isApplyingLaunchAtLoginChange = true
                            launchAtLogin.toggle()
                            isApplyingLaunchAtLoginChange = false
                        }
                    }

                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("App Control") {
                Button("Check for Updates", systemImage: "arrow.down.circle") {
                    (NSApp.delegate as? AppDelegate)?.checkForUpdates()
                }
                Button("Restart Notion Bridge", systemImage: "arrow.clockwise") {
                    restartApp(reopenSettings: true)
                }
            }

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

            Section {
                ConnectionsManagementView()
            } header: {
                Text("Workspace connections")
            } footer: {
                Text("Connect Notion workspaces here. Health checks run in the background so the page stays responsive while validation completes.")
                    .font(.caption2)
                    .foregroundStyle(BridgeColors.muted)
            }

            Section {
                APIConnectionsManagementView()
            } header: {
                Text("API connections")
            } footer: {
                Text("Third-party API keys used by bridge tools (for example Stripe). These are separate from workspace tokens and remote-access URLs.")
                    .font(.caption2)
                    .foregroundStyle(BridgeColors.muted)
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

            Section("Remote Access") {
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
                LabeledContent("MCP Protocol", value: "v\(BridgeConstants.mcpProtocolVersion)")
                LabeledContent("Build Target", value: buildTargetString)
            }

            Section("Network") {
                HStack(spacing: BridgeSpacing.xs) {
                    Text("SSE Port")
                    Spacer()
                    TextField("9700", text: $ssePortInput)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                        .onChange(of: ssePortInput) { _, _ in
                            ssePortSaveSuccess = false
                        }
                    Button("Save") {
                        saveSSEPort()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                Text("Applied on next app restart. Port resolution order: config.json → NOTION_BRIDGE_PORT → \(String(BridgeConstants.defaultSSEPort)).")
                    .font(.caption2)
                    .foregroundStyle(BridgeColors.muted)
                if let ssePortError {
                    Text(ssePortError)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if ssePortSaveSuccess {
                    Text("Port saved. Restart Notion Bridge to apply.")
                        .font(.caption2)
                        .foregroundStyle(BridgeColors.success)
                }
                Text("This value sets the TCP port for the local MCP HTTP/SSE server (127.0.0.1). Notion in the cloud does not connect to it directly. Remote agents use the URL under Connections → Remote Access; your tunnel forwards that HTTPS URL to this localhost port. If you change the port, update cloudflared or Tailscale to forward to the same port.")
                    .font(.caption2)
                    .foregroundStyle(BridgeColors.muted)
                if let port = Int(ssePortInput.trimmingCharacters(in: .whitespacesAndNewlines)), port >= 1, port < 1024 {
                    Label("Well-known port — may require elevated privileges on macOS.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
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

            Section("Paths") {
                LabeledContent("Config File") {
                    Text(ConfigManager.shared.configFileURL.path)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }

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
                LabeledContent("Screen Output") {
                    Text(screenOutputDir)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
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

                Button("Factory Reset", role: .destructive) {
                    showFactoryResetConfirmation = true
                }
                .confirmationDialog(
                    "Factory Reset Notion Bridge?",
                    isPresented: $showFactoryResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Factory Reset", role: .destructive) {
                        Task {
                            let result = await performFactoryReset()
                            factoryResetMessage = result.message
                            showPostResetSheet = true
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(factoryResetConfirmationMessage)
                }

                if let factoryResetMessage {
                    Text(factoryResetMessage)
                        .font(.caption)
                        .foregroundStyle(BridgeColors.secondary)
                }
            }

            Section("Support") {
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
        .onAppear {
            ssePortInput = String(ssePort)
            ssePortError = nil
        }
        .sheet(isPresented: $showPostResetSheet) {
            PostResetSheet(permissionManager: permissionManager)
        }
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

    /// Persist SSE port to config.json (config -> env -> default fallback model).
    func saveSSEPort() {
        let trimmed = ssePortInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed), (1...65535).contains(port) else {
            ssePortError = "Port must be a number between 1 and 65535."
            return
        }
        ConfigManager.shared.ssePort = port
        ssePortInput = String(ConfigManager.shared.ssePort)
        ssePortError = nil
        ssePortSaveSuccess = true
    }

    /// Full local reset for pre-ship recovery/testing.
    func performFactoryReset() async -> (message: String, didFail: Bool) {
        var failures: [String] = []

        // 1) Clear app-scoped UserDefaults.
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        } else {
            failures.append("user defaults")
        }

        // PKT-485: Restore default skills after clearing UserDefaults.
        skillsManager.resetToDefaults()

        // 2) Remove config file.
        let configURL = ConfigManager.shared.configFileURL
        if FileManager.default.fileExists(atPath: configURL.path) {
            do {
                try FileManager.default.removeItem(at: configURL)
            } catch {
                failures.append("config.json")
            }
        }

        // 3) Remove all saved keychain items for Notion Bridge.
        if !KeychainManager.shared.deleteAll() {
            failures.append("keychain")
        }

        // 3b) Drop in-memory Notion workspace clients so Settings/MCP match cleared storage without restart.
        await NotionClientRegistry.shared.resetAfterFactoryReset()
        await ConnectionHealthChecker.shared.invalidateAll()

        // 4) Reset TCC grants for current + legacy bundle IDs.
        let tccReset = await resetTCCPermissions()
        if tccReset.didFail {
            failures.append("TCC")
        }

        await permissionManager.recheckAllForTruth()
        NotificationCenter.default.post(name: .notionTokenDidChange, object: nil)
        UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")

        // PKT-485: Trigger onboarding window after factory reset.
        NotificationCenter.default.post(name: .resetOnboarding, object: nil)

        if failures.isEmpty {
            return ("Factory reset complete. Restart Notion Bridge, then re-grant permissions.", false)
        }
        return ("Factory reset finished with issues: \(failures.joined(separator: ", ")).", true)
    }

    // MARK: - Diagnostics

    func exportDiagnostics() {
        let lines = [
            "Notion Bridge Diagnostics",
            "========================",
            "App Version: v\(appVersion)",
            "MCP Protocol: v\(BridgeConstants.mcpProtocolVersion)",
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
