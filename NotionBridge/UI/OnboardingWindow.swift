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
import UserNotifications

/// Manages the first-launch onboarding NSWindow.
/// Shows a multi-step wizard: Welcome → Permissions → Connection → Test Connection.
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

/// Multi-step onboarding wizard: Welcome → Permissions → Connection → Test Connection.
struct OnboardingView: View {
    let permissionManager: PermissionManager
    let onComplete: () -> Void

    @State private var currentStep: OnboardingStep = .welcome
    @State private var healthCheckStatus: HealthCheckStatus = .idle
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var showLegacySSE: Bool = false

    enum OnboardingStep: Int, CaseIterable {
        case welcome = 0
        case permissions = 1
        case connection = 2
        case testConnection = 3
    }

    enum HealthCheckStatus {
        case idle
        case checking
        case success
        case failed(String)
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
                case .permissions:
                    permissionsStep
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
        VStack(spacing: 16) {
            // PKT-357 F7: Larger brand icon for visual impact
            Image(systemName: "bridge.fill")
                .font(.system(size: 56))
                .foregroundStyle(.purple)

            // PKT-357 F6: Explicit opacity to prevent animation fade-in
            Text("Welcome to Notion Bridge")
                .font(.title)
                .fontWeight(.semibold)
                .opacity(1)

            // PKT-357 F8: Power language — direct, confident, concise
            Text("Your Mac, fully connected to Notion AI. Manage files, execute commands, control apps, and automate workflows through a secure local MCP server. Every action requires your explicit permission.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            // D6: Dynamic notification status (replaces hardcoded text)
            notificationStatusView
                .padding(.top, 8)
        }
        .task {
            await checkNotificationStatus()
        }
    }

    // MARK: - Notification Status (D6 + PKT-357 F11)

    @ViewBuilder
    private var notificationStatusView: some View {
        switch notificationStatus {
        case .authorized:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Notification permission granted — used for security approvals")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .notDetermined:
            HStack(spacing: 8) {
                Image(systemName: "bell.badge.fill")
                    .foregroundStyle(.orange)
                Text("Notification permission needed for security approvals")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Grant") {
                    Task { await requestNotificationPermission() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .denied:
            HStack(spacing: 8) {
                Image(systemName: "bell.slash.fill")
                    .foregroundStyle(.red)
                Text("Notifications disabled — security approvals will use dialog prompts instead")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        default:
            HStack(spacing: 8) {
                Image(systemName: "bell.slash.fill")
                    .foregroundStyle(.red)
                Text("Notifications disabled — security approvals will use dialog prompts instead")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func checkNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = settings.authorizationStatus
    }

    // PKT-357 F11: Request authorization + send test notification on grant
    private func requestNotificationPermission() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            notificationStatus = granted ? .authorized : .denied
            // PKT-357 F11: Send a test notification to confirm delivery
            if granted {
                await sendTestNotification()
            }
        } catch {
            notificationStatus = .denied
        }
    }

    // PKT-357 F11: Deliver a visible test notification after grant
    private func sendTestNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "Notion Bridge"
        content.body = "Notifications are working! Security approvals will appear here."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "notionbridge-test-notification",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Permissions Step (PKT-357 F10: All permissions always listed)

    private var permissionsStep: some View {
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

            // PKT-357 F10: Always show ALL grants, not just the first missing one
            VStack(spacing: 8) {
                ForEach(PermissionManager.Grant.allCases) { grant in
                    onboardingPermissionRow(grant: grant)
                }
            }
            .padding(.top, 8)

            Button("Refresh Status") {
                permissionManager.checkAll()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.blue)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
        }
    }

    private func onboardingPermissionRow(grant: PermissionManager.Grant) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(permissionManager.status(for: grant) == .granted ? .green : .orange)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(grant.displayName)
                    .font(.callout)
                Text(grantExplanation(grant))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if permissionManager.status(for: grant) == .granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Grant") {
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
        case .automation: return "Script other apps via AppleScript"
        case .contacts: return "Search and read your contacts"
        }
    }

    // D2: Modified to trigger permission probes before opening System Settings
    private func openSystemSettings(for grant: PermissionManager.Grant) {
        let urlString: String
        switch grant {
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .fullDiskAccess:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case .automation:
            // D2: Fire the NSAppleScript probe first to trigger the macOS Automation
            // permission prompt, then open Settings after a short delay so the app
            // appears in the Automation panel.
            permissionManager.checkAutomation()
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
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
            }
            return
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
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
                          "url": "http://localhost:9700/mcp"
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
                              "url": "http://localhost:9700/sse"
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
                case .success:
                    Text("Notion Bridge is running and responding! You\u{2019}re all set.")
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
        case .success: return "Connected \u{2713}"
        case .failed: return "Retry"
        }
    }

    private func runHealthCheck() {
        healthCheckStatus = .checking
        Task {
            do {
                let url = URL(string: "http://localhost:9700/health")!
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    healthCheckStatus = .failed("Server returned non-200 status")
                    return
                }
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = json["status"] as? String,
                   status == "running" {
                    healthCheckStatus = .success
                } else {
                    healthCheckStatus = .failed("Unexpected response format")
                }
            } catch {
                healthCheckStatus = .failed("Could not reach server \u{2014} is it running?")
            }
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
