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
// PKT-362 D2: Removed static Sensitive Paths section from Permissions tab.
// PKT-363 D3: Added configurable Sensitive Paths list editor.
// PKT-363 D4: Restore Defaults merge + zero-path confirmation guard.
// PKT-362 D3: Re-check All uses animatedRecheckAll() for per-row feedback.
// PKT-362 D4: Reset TCC dialog rewritten with user-facing language.

import SwiftUI
import ServiceManagement
import AppKit

// Notification names moved to NotionBridge/Core/BridgeNotifications.swift

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

    @State var selectedSection: SettingsSection = .connections

    // Token editing state (PKT-350 F1)
    @State var isEditingToken = false
    @State var newTokenValue = ""
    @State var tokenError: String?
    @State var tokenSaveSuccess = false
    @State var showResetConfirmation = false
    @State var showFactoryResetConfirmation = false
    @State var isRecheckingPermissions = false
    @State var permissionActionMessage: String?
    @State var launchAtLoginError: String?
    @State var isApplyingLaunchAtLoginChange = false
    @State var ssePortInput = String(ConfigManager.shared.ssePort)
    @State var ssePortError: String?
    @State var ssePortSaveSuccess = false
    @State var showSSEPortRestartPrompt = false
    @State var ssePortRevertOnCancel: Int?
    @State var factoryResetMessage: String?
    @State var showResetBackgroundItemsConfirmation = false
    @State var resetBackgroundItemsMessage: String?
    @State var showTCCResetDialog = false

    enum SettingsSection: String, CaseIterable, Identifiable {
        case connections = "Connections"
        case credentials = "Credentials"
        case permissions = "Permissions"
        case tools = "Tools"
        case skills = "Skills"
        case jobs = "Jobs"
        case advanced = "Advanced"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .connections: return "network"
            case .permissions: return "lock.shield"
            case .tools: return "hammer"
            case .skills: return "book.closed"
            case .credentials: return "key.fill"
            case .jobs: return "clock.badge.checkmark"
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
        case .connections: connectionsSection
        case .permissions: permissionsSection
        case .tools: toolsSection
        case .skills: skillsSection
        case .credentials: credentialsSection
        case .jobs: jobsSection
        case .advanced: advancedSection
        }
    }

    // MARK: - Shared Properties

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AppVersion.marketing
    }

    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false

    var ssePort: Int {
        ConfigManager.shared.ssePort
    }

    var maskedTokenLabel: String {
        let masked = NotionTokenResolver.maskedToken()
        if masked == "Not configured" {
            return "Not configured \u{26A0}\u{FE0F}"
        }
        return masked
    }

    /// Minimum OS matching SwiftPM deployment (not the machine's runtime version).
    var buildTargetString: String {
        "macOS \(BridgeConstants.minimumMacOSMarketing)"
    }

    /// Compact relative timestamp — mirrors DashboardView.relativeTime pattern.
    /// Fixes "Since now" edge case: returns "just now" for durations < 60s.
    func relativeTimestamp(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        else if interval < 3600 { return "\(Int(interval / 60))m ago" }
        else if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        else { return "\(Int(interval / 86400))d ago" }
    }

    // MARK: - Skills state (must be in struct body)
    @State var skillsManager = SkillsManager()
    // PKT-375: Screen output directory state
    @State var screenOutputDir: String = ConfigManager.shared.screenOutputDir
}
