// OnboardingWindow.swift — First-Launch Onboarding Window
// V1-QUALITY-C2 + V1-QUALITY-POLISH (PKT-346):
// NSWindow shown once on first launch with permission wizard,
// connection setup, and health check test. Sets hasCompletedOnboarding = true on completion.
// D1: Welcome text fix — removed "all"
// D2: Permission triggering — probe before opening Settings for Automation/Contacts
// D3: Connection page rewrite — transport-oriented cards
// D6: Dynamic notification status on welcome page
// PKT-357: F6 welcome header opacity, F7 brand icon, F8 power copy,
//   F9 test connection text, F10 all permissions listed, F11 notification test

import SwiftUI
import AppKit

/// Manages the first-launch onboarding NSWindow.
/// Shows a multi-step wizard:
/// Welcome → Auto Permissions → Manual Permissions → Connection → Test Connection.
/// Checks `UserDefaults.bool(forKey: "hasCompletedOnboarding")` — skips if true.
@MainActor
public final class OnboardingWindowController {
    private var window: NSWindow?
    private let permissionManager: PermissionManager

    public init(permissionManager: PermissionManager) {
        self.permissionManager = permissionManager
    }

    /// Show the onboarding window if the user hasn't completed it yet.
    /// Returns immediately if `hasCompletedOnboarding` is true.
    public func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") else {
            print("[Onboarding] Already completed — skipping")
            return
        }
        show()
    }

    /// Force-show the onboarding window (for testing or re-run).
    public func show() {
        let onboardingView = OnboardingView(
            permissionManager: permissionManager,
            onComplete: { [weak self] in
                self?.complete()
            }
        )

        let hostingController = NSHostingController(rootView: onboardingView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Welcome to Notion Bridge"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 520, height: 480))
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        print("[Onboarding] Window shown")
    }

    private func complete() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        window?.close()
        window = nil
        print("[Onboarding] Completed — hasCompletedOnboarding = true")
    }
}

// MARK: - Onboarding View

/// Multi-step onboarding wizard:
/// Welcome → Auto Permissions → Manual Permissions → Connection → Test Connection.
struct OnboardingView: View {
    let permissionManager: PermissionManager
    let onComplete: () -> Void

    private let permissionsRefreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    @State private var currentStep: OnboardingStep = .welcome
    @State private var healthCheckStatus: HealthCheckStatus = .idle
    @State private var showLegacySSE: Bool = false
    @State private var isRefreshingPermissions: Bool = false
    @State private var previousPermissionStatuses: [PermissionManager.Grant: PermissionManager.GrantStatus] = [:]
    @State private var recentlyGrantedPermissions: Set<PermissionManager.Grant> = []
    @State private var didAutoAdvanceFromAutoStep: Bool = false

    enum OnboardingStep: Int, CaseIterable {
        case welcome = 0
        case autoPermissions = 1
        case manualPermissions = 2
        case connection = 3
        case testConnection = 4
    }

    enum HealthCheckStatus {
        case idle
        case checking
        case success(milliseconds: Int)
        case failed(String)
    }

    private var ssePort: Int {
        ConfigManager.shared.ssePort
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            progressBar
                .padding(.top, 20)
                .padding(.horizontal, 32)

            Spacer()

            // Step content — PKT-357 F6: no implicit animation on step transitions
            Group {
                switch currentStep {
                case .welcome:
                    welcomeStep
                case .autoPermissions:
                    autoPermissionsStep
                case .manualPermissions:
                    manualPermissionsStep
                case .connection:
                    connectionStep
                case .testConnection:
                    testConnectionStep
                }
            }
            .padding(.horizontal, 32)

            Spacer()

            // Navigation buttons
            navigationButtons
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
        }
        .frame(width: 520, height: 480)
        .task {
            await permissionManager.checkAllAsync()
            await MainActor.run {
                capturePermissionTransitions()
            }
        }
        .onChange(of: currentStep) { _, newStep in
            if newStep == .manualPermissions {
                refreshPermissionStatus()
            }
        }
        .onReceive(permissionsRefreshTimer) { _ in
            guard currentStep == .manualPermissions else { return }
            refreshPermissionStatus()
        }
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                RoundedRectangle(cornerRadius: 2)
                    .fill(step.rawValue <= currentStep.rawValue ? Color.purple : Color.gray.opacity(0.3))
                    .frame(height: 4)
            }
        }
    }

    // MARK: - Welcome Step (PKT-357: F6, F7, F8)

    private var welcomeStep: some View {
        let isReturningUser = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        return VStack(spacing: 16) {
            // PKT-357 F7: Larger brand icon for visual impact
            Image(systemName: "bridge.fill")
                .font(.system(size: 56))
                .foregroundStyle(.purple)

            // PKT-357 F6: Explicit opacity to prevent animation fade-in
            Text(isReturningUser ? "Welcome back to Notion Bridge" : "Welcome to Notion Bridge")
                .font(.title)
                .fontWeight(.semibold)
                .opacity(1)

            Text(
                isReturningUser
                ? "Your local bridge to Notion Agents is ready. Recheck permissions, confirm your connection, and continue where you left off."
                : "Your Mac, fully connected to Notion Agents. Manage files, execute commands, control apps, and automate workflows through a secure local MCP server. Every action requires your explicit permission."
            )
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

        }
    }

    // MARK: - Permissions Steps (PKT-388 split)

    private var autoPermissionsStep: some View {
        AutoPermissionsStepView(permissionManager: permissionManager) {
            guard currentStep == .autoPermissions, !didAutoAdvanceFromAutoStep else { return }
            didAutoAdvanceFromAutoStep = true
            currentStep = .manualPermissions
        }
    }

    private var manualPermissionsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Grant Permissions")
                .font(.title2)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .center)

            Text("Notion Bridge needs these permissions to work. Grant them one at a time in System Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            if isRefreshingPermissions {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking permissions…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }

            // PKT-357 F10: Always show ALL grants, not just the first missing one
            VStack(spacing: 8) {
                ForEach(PermissionManager.Grant.onboardingCases) { grant in
                    onboardingPermissionRow(grant: grant)
                }
            }
            .padding(.top, 8)

            Button("Refresh Status") {
                refreshPermissionStatus()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.blue)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
        }
    }

    private func onboardingPermissionRow(grant: PermissionManager.Grant) -> some View {
        let status = permissionManager.status(for: grant)
        return HStack(spacing: 12) {
            Circle()
                .fill(status == .granted ? .green : .orange)
                .frame(width: 10, height: 10)
                .scaleEffect(isRefreshingPermissions && status != .granted ? 1.12 : 1.0)
                .animation(.easeInOut(duration: 0.45), value: isRefreshingPermissions)

            VStack(alignment: .leading, spacing: 2) {
                Text(grant.displayName)
                    .font(.callout)
                Text(grantExplanation(grant))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if status == .granted {
                if recentlyGrantedPermissions.contains(grant) {
                    Text("\u{2713} Granted")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } else {
                Button("Allow") {
                    openSystemSettings(for: grant)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func grantExplanation(_ grant: PermissionManager.Grant) -> String {
        switch grant {
        case .accessibility: return "Control UI elements and simulate input"
        case .screenRecording: return "Capture screen content for AI context"
        case .fullDiskAccess: return "Read files outside the sandbox"
        case .automation: return "Script other apps via AppleScript (System Events, Messages, Chrome)"
        case .notifications: return "Security approvals appear as notification banners"
        case .contacts: return "Search and read your contacts"
        }
    }

    // D2: Modified to trigger permission probes before opening System Settings
    private func openSystemSettings(for grant: PermissionManager.Grant) {
        let urlString: String
        switch grant {
        case .accessibility:
            _ = permissionManager.requestAccessibilityAccess()
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await permissionManager.recheckAllForTruth()
                await MainActor.run { capturePermissionTransitions() }
            }
            return
        case .screenRecording:
            _ = permissionManager.requestScreenRecordingAccess()
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await permissionManager.recheckAllForTruth()
                await MainActor.run { capturePermissionTransitions() }
            }
            return
        case .fullDiskAccess:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case .automation:
            // D2: Fire the NSAppleScript probe first to trigger the macOS Automation
            // permission prompt, then open Settings after a short delay so the app
            // appears in the Automation panel.
            Task {
                await permissionManager.requestAutomationAccess()
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
                await permissionManager.recheckAllForTruth()
                await MainActor.run { capturePermissionTransitions() }
            }
            return
        case .notifications:
            // PKT-364 D3: Probe-then-deep-link for notification permission.
            // requestAuthorization triggers system prompt if .notDetermined.
            // If denied, deep link to System Settings > Notifications.
            Task {
                let granted = await permissionManager.requestNotificationAccess()
                if !granted {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                }
                await permissionManager.recheckAllForTruth()
                await MainActor.run { capturePermissionTransitions() }
            }
            return
        case .contacts:
            // D2: Request contacts access first to trigger the macOS "NotionBridge
            // would like to access your contacts" prompt, then open Settings so the
            // app appears in the Contacts panel.
            Task {
                _ = await permissionManager.requestContactsAccess()
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
                    NSWorkspace.shared.open(url)
                }
                await permissionManager.recheckAllForTruth()
                await MainActor.run { capturePermissionTransitions() }
            }
            return
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
        Task {
            await permissionManager.recheckAllForTruth()
            await MainActor.run { capturePermissionTransitions() }
        }
    }

    // MARK: - Connection Step (D3)

    private var connectionStep: some View {
        VStack(spacing: 16) {
            Text("Connect to Notion Bridge")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Copy the connection config and paste it into your AI client\u{2019}s MCP settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                // Card 1 — Streamable HTTP (Recommended)
                transportConfigCard(
                    transport: "Streamable HTTP",
                    badge: "Recommended",
                    badgeColor: .green,
                    helperText: "Works with Cursor, Claude Code, and most modern MCP clients. Paste into your client\u{2019}s MCP server configuration.",
                    config: """
                    {
                      "mcpServers": {
                        "notion-bridge": {
                              "url": "http://localhost:\(ssePort)/mcp"
                        }
                      }
                    }
                    """
                )

                // Card 2 — Legacy SSE (collapsed by default)
                DisclosureGroup(isExpanded: $showLegacySSE) {
                    transportConfigCard(
                        transport: "Legacy SSE",
                        badge: nil,
                        badgeColor: .clear,
                        helperText: "For Claude Desktop and clients that use Server-Sent Events. Use this if Streamable HTTP doesn\u{2019}t work with your client.",
                        config: """
                        {
                          "mcpServers": {
                            "notion-bridge": {
                              "url": "http://localhost:\(ssePort)/sse"
                            }
                          }
                        }
                        """
                    )
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.secondary)
                        Text("Legacy SSE Transport")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // D3: Transport-oriented config card (replaces client-named clientConfigCard)
    private func transportConfigCard(transport: String, badge: String?, badgeColor: Color, helperText: String, config: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(transport)
                    .font(.callout)
                    .fontWeight(.medium)
                if let badge = badge {
                    Text(badge)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(badgeColor)
                        .cornerRadius(4)
                }
                Spacer()
                Button("Copy Config") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(config, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text(helperText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(config)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(6)
        }
        .padding(12)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
    }

    // MARK: - Test Connection Step (PKT-357 F9: Cleaned up idle text)

    private var testConnectionStep: some View {
        VStack(spacing: 20) {
            // Status icon
            Group {
                switch healthCheckStatus {
                case .idle:
                    Image(systemName: "network")
                        .font(.system(size: 48))
                        .foregroundStyle(.gray)
                case .checking:
                    ProgressView()
                        .scaleEffect(1.5)
                        .frame(height: 48)
                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                }
            }

            Text("Test Connection")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Make sure Notion Bridge is running and your client can reach it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            // Health check result — PKT-357 F9: Removed misleading "options" text
            Group {
                switch healthCheckStatus {
                case .idle:
                    Text("Verify that the MCP server is running and reachable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .checking:
                    Text("Checking health endpoint...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .success(let milliseconds):
                    Text("Connected \u{2014} \(milliseconds)ms")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .failed(let reason):
                    Text("Connection check failed: \(reason)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Button {
                runHealthCheck()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                    Text(healthCheckButtonLabel)
                }
                .frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .tint(healthCheckStatus.isSuccess ? .green : .purple)
            .disabled(healthCheckStatus.isChecking)

            if healthCheckStatus.isSuccess {
                VStack(alignment: .leading, spacing: 8) {
                    tipRow(icon: "menubar.arrow.up.rectangle", text: "Click the menu bar icon for quick status")
                    tipRow(icon: "gearshape", text: "Press \u{2318}, for Settings")
                    tipRow(icon: "shield.checkered", text: "Destructive actions require approval via notification")
                }
                .padding(.top, 4)
            }
        }
    }

    private var healthCheckButtonLabel: String {
        switch healthCheckStatus {
        case .idle: return "Test Connection"
        case .checking: return "Checking..."
        case .success(let milliseconds): return "Connected \u{2014} \(milliseconds)ms"
        case .failed: return "Retry"
        }
    }

    private func runHealthCheck() {
        healthCheckStatus = .checking
        Task {
            do {
                let start = Date()
                let url = URL(string: "http://localhost:\(ssePort)/health")!
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    healthCheckStatus = .failed("Server returned non-200 status")
                    return
                }
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = json["status"] as? String,
                   status == "running" {
                    let latencyMs = max(1, Int(Date().timeIntervalSince(start) * 1000))
                    healthCheckStatus = .success(milliseconds: latencyMs)
                } else {
                    healthCheckStatus = .failed("Unexpected response format")
                }
            } catch {
                healthCheckStatus = .failed("Could not reach server \u{2014} is it running?")
            }
        }
    }

    private func refreshPermissionStatus() {
        guard !isRefreshingPermissions else { return }
        isRefreshingPermissions = true
        Task {
            await permissionManager.checkAllAsync()
            await MainActor.run {
                capturePermissionTransitions()
                isRefreshingPermissions = false
            }
        }
    }

    @MainActor
    private func capturePermissionTransitions() {
        for grant in PermissionManager.Grant.onboardingCases {
            let current = permissionManager.status(for: grant)
            if let previous = previousPermissionStatuses[grant],
               previous == .denied,
               current == .granted {
                recentlyGrantedPermissions.insert(grant)
                Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    _ = await MainActor.run {
                        recentlyGrantedPermissions.remove(grant)
                    }
                }
            }
            previousPermissionStatuses[grant] = current
        }
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.purple)
                .frame(width: 20)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Navigation (PKT-357 F6: Removed withAnimation to prevent header fade)

    private var navigationButtons: some View {
        HStack {
            if currentStep != .welcome {
                Button("Back") {
                    // PKT-357 F6: No animation — prevents welcome header opacity fade
                    currentStep = OnboardingStep(rawValue: currentStep.rawValue - 1) ?? .welcome
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if currentStep == .testConnection {
                Button("Done") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
            } else {
                Button("Continue") {
                    // PKT-357 F6: No animation — prevents welcome header opacity fade
                    currentStep = OnboardingStep(rawValue: currentStep.rawValue + 1) ?? .testConnection
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
            }
        }
    }
}

// MARK: - HealthCheckStatus Helpers

extension OnboardingView.HealthCheckStatus {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
    var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }
}
