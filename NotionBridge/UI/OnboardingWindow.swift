// OnboardingWindow.swift — First-Launch Onboarding Window
// V1-QUALITY-C2: NSWindow shown once on first launch with permission wizard,
// connection setup, and health check test. Sets hasCompletedOnboarding = true on completion.
// Notification permission already requested in AppDelegate (V1-QUALITY-C1) —
// onboarding shows status, does not re-request.

import SwiftUI
import AppKit

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

            // Step content
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

    // MARK: - Welcome Step

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "bridge.fill")
                .font(.system(size: 48))
                .foregroundStyle(.purple)

            Text("Welcome to Notion Bridge")
                .font(.title)
                .fontWeight(.semibold)

            Text("Notion Bridge connects your Notion agents to your Mac through a secure, local MCP server. Your agents can manage files, run command-line interface commands, steer your Mac, control your browser, and automate workflows — all with your permission.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            // Notification permission status (already granted via AppDelegate — C1)
            HStack(spacing: 8) {
                Image(systemName: "bell.badge.fill")
                    .foregroundStyle(.blue)
                Text("Notification permission granted — used for security approvals")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Permissions Step

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
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        case .contacts:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Connection Step

    private var connectionStep: some View {
        VStack(spacing: 16) {
            Text("Connect Your AI Client")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Add this configuration to your AI client to connect to Notion Bridge.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                clientConfigCard(
                    name: "Claude Desktop",
                    icon: "sparkle",
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

                clientConfigCard(
                    name: "Cursor / Other",
                    icon: "cursorarrow.rays",
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
            }
        }
    }

    private func clientConfigCard(name: String, icon: String, config: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(.purple)
                Text(name)
                    .font(.callout)
                    .fontWeight(.medium)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(config, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

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

    // MARK: - Test Connection Step

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

            // Health check result
            Group {
                switch healthCheckStatus {
                case .idle:
                    Text("Press the button below to test the connection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .checking:
                    Text("Checking health endpoint...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .success:
                    Text("Notion Bridge is running and responding! You're all set.")
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
                    tipRow(icon: "gearshape", text: "Press ⌘, for Settings")
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
        case .success: return "Connected ✓"
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
                healthCheckStatus = .failed("Could not reach server — is it running?")
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

    // MARK: - Navigation

    private var navigationButtons: some View {
        HStack {
            if currentStep != .welcome {
                Button("Back") {
                    withAnimation {
                        currentStep = OnboardingStep(rawValue: currentStep.rawValue - 1) ?? .welcome
                    }
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
                    withAnimation {
                        currentStep = OnboardingStep(rawValue: currentStep.rawValue + 1) ?? .testConnection
                    }
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
