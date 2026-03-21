// PermissionManager.swift — TCC Grant Detection Logic
// V1-02: Detects grant status for all 5 required TCC permissions
// V1-QUALITY-POLISH (PKT-346 D2): Added requestContactsAccess()
// V1-03 (BUG-FIX): Dynamic Automation target probing — Chrome, Contacts,
//   and future targets are probed alongside System Events and Messages.
//   Fixes: NotionBridge invisible in Automation prefs when Chrome was the
//   first Apple Event target (TCC prompt silently suppressed on Sequoia).
// PKT-362 D3: Added grantCheckingState and animatedRecheckAll() for animated re-check.
// V1-PATCH-003: Offloaded NSAppleScript automation probes to background thread via
//   Task.detached to eliminate main-thread blocking that caused macOS to sever the
//   Dock/WindowServer connection. checkAll() and checkAutomation() are now async.
// PKT-362 D5: Added systemSettingsURL to Grant for deep links in post-reset sheet.
// PKT-362 D6: Added needsRestart flag and restart transition tracking.
//
// Detection methods per grant:
//   - Accessibility: AXIsProcessTrusted() — direct API
//   - Screen Recording: CGPreflightScreenCaptureAccess() — direct API
//   - Full Disk Access: Probe Messages chat.db readability — no direct API
//   - Automation: Probe via NSAppleScript to each target app — no direct API
//   - Contacts: CNContactStore.authorizationStatus(for:) — direct API
//
// Warning: macOS 15+ (Sequoia): Screen Recording permission expires weekly.
// Apple enforces a 7-day re-authorization window for Screen Recording.
// There is NO API to detect when the permission will expire — only
// whether it is currently granted. The app should call checkAll()
// periodically (e.g., on popover open) to detect expiration promptly.
// Users will see a system prompt to re-authorize. This is an Apple
// platform constraint, not a bug.

import Foundation
import Observation
import AppKit
import Contacts
import UserNotifications

/// Detects TCC (Transparency, Consent, and Control) grant status
/// for all 5 required macOS permissions.
@MainActor
@Observable
public final class PermissionManager {

    public init() {}

    // MARK: - Types

    /// The 5 TCC grants required by NotionBridge.
    public enum Grant: String, CaseIterable, Identifiable, Sendable {
        case accessibility
        case screenRecording
        case fullDiskAccess
        case automation
        case notifications
        case contacts

        public var id: String { rawValue }

        /// V1 grants — Contacts is deferred to expansion (no V1 tool uses it)
        public static var v1Cases: [Grant] {
            allCases.filter { $0 != .contacts }
        }

        /// Grants surfaced during onboarding.
        /// Only include permissions users can actively grant from this flow.
        public static var onboardingCases: [Grant] {
            v1Cases.filter(\.isActionableInOnboarding)
        }

        public var isActionableInOnboarding: Bool {
            switch self {
            case .contacts:
                return false
            default:
                return true
            }
        }

        public var displayName: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .screenRecording: return "Screen Recording"
            case .fullDiskAccess: return "Full Disk Access"
            case .automation: return "Automation"
            case .notifications: return "Notifications"
            case .contacts: return "Contacts"
            }
        }

        /// PKT-362 D5: System Settings deep link URL per grant.
        /// Used by PostResetSheet to offer one-tap navigation to the correct pane.
        public var systemSettingsURL: URL? {
            switch self {
            case .accessibility:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            case .screenRecording:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            case .fullDiskAccess:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
            case .automation:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
            case .notifications:
                return URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
            case .contacts:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")
            }
        }
    }

    /// Status of a single TCC grant.
    public enum GrantStatus: Equatable, Sendable {
        case granted
        case denied
        case unknown
        case partiallyGranted
        case restartRecommended
    }

    /// Probe-backed evidence for a grant status decision.
    public struct GrantEvidence: Equatable, Sendable {
        public let source: String
        public let observed: String
        public let detail: String
        public let checkedAt: Date
    }

    // MARK: - Automation Target Registry

    /// Defines an application that NotionBridge may send Apple Events to.
    /// Each target is probed during `checkAutomation()`. On first probe,
    /// macOS will show the TCC consent prompt for that target, registering
    /// NotionBridge in the Automation preferences pane.
    public struct AutomationTarget: Sendable, Identifiable {
        public let bundleID: String
        public let name: String
        public let probe: String
        public var id: String { bundleID }
    }

    /// All known Automation targets. Add new entries here when NotionBridge
    /// needs to control additional applications via Apple Events.
    /// Order: most critical first (System Events, Messages, Chrome, Contacts).
    public static let automationTargets: [AutomationTarget] = [
        AutomationTarget(
            bundleID: "com.apple.systemevents",
            name: "System Events",
            probe: """
                tell application "System Events"
                    return name of first process whose frontmost is true
                end tell
            """
        ),
        AutomationTarget(
            bundleID: "com.apple.MobileSMS",
            name: "Messages",
            probe: """
                tell application "Messages"
                    return name
                end tell
            """
        ),
        AutomationTarget(
            bundleID: "com.google.Chrome",
            name: "Google Chrome",
            probe: """
                tell application "Google Chrome"
                    return name
                end tell
            """
        ),
        AutomationTarget(
            bundleID: "com.apple.AddressBook",
            name: "Contacts",
            probe: """
                tell application "Contacts"
                    return name
                end tell
            """
        ),
    ]

    // MARK: - State

    public private(set) var accessibilityStatus: GrantStatus = .unknown
    public private(set) var screenRecordingStatus: GrantStatus = .unknown
    public private(set) var fullDiskAccessStatus: GrantStatus = .unknown
    public private(set) var automationStatus: GrantStatus = .unknown
    public private(set) var contactsStatus: GrantStatus = .unknown
    public private(set) var notificationStatus: GrantStatus = .unknown

    /// Per-target Automation grant results. Key = bundleID.
    public private(set) var automationTargetGrants: [String: Bool] = [:]

    /// Backward-compatible accessors for existing code.
    public var automationSystemEventsGranted: Bool {
        automationTargetGrants["com.apple.systemevents"] ?? false
    }
    public var automationMessagesGranted: Bool {
        automationTargetGrants["com.apple.MobileSMS"] ?? false
    }
    public var automationChromeGranted: Bool {
        automationTargetGrants["com.google.Chrome"] ?? false
    }
    public var automationContactsGranted: Bool {
        automationTargetGrants["com.apple.AddressBook"] ?? false
    }

    public private(set) var lastCheckedAt: Date?
    public private(set) var accessibilityEvidence: GrantEvidence?
    public private(set) var screenRecordingEvidence: GrantEvidence?
    public private(set) var fullDiskAccessEvidence: GrantEvidence?
    public private(set) var automationEvidence: GrantEvidence?
    public private(set) var contactsEvidence: GrantEvidence?
    public private(set) var notificationEvidence: GrantEvidence?

    /// PKT-362 D3: Per-grant checking state for animated re-check feedback.
    /// Key = grant, value = true while that row is in "Checking…" state.
    public private(set) var grantCheckingState: [Grant: Bool] = [:]

    /// PKT-362 D6: Batched restart flag. Set when a restart-required grant
    /// (Screen Recording, Full Disk Access) transitions to .granted.
    /// Reset on app launch (init default = false).
    public private(set) var needsRestart: Bool = false

    /// PKT-362 D6: Grants that require an app restart to take full effect.
    public static let restartRequiredGrants: Set<Grant> = [.screenRecording, .fullDiskAccess]

    // MARK: - Public API

    /// Returns the current status for the given grant.
    public func status(for grant: Grant) -> GrantStatus {
        switch grant {
        case .accessibility: return accessibilityStatus
        case .screenRecording: return screenRecordingStatus
        case .fullDiskAccess: return fullDiskAccessStatus
        case .automation: return automationStatus
        case .notifications: return notificationStatus
        case .contacts: return contactsStatus
        }
    }

    /// Check all TCC grants including async automation probes.
    /// V1-PATCH-003: Now async — automation probes run on background thread
    /// to prevent main-thread blocking that caused Dock connection severing.
    /// Call on popover open and periodically to detect re-grant needs.
    /// Note: Notifications check is NOT included here.
    /// Use recheckAllForTruth() or checkNotifications() for notification status.
    public func checkAll() async {
        checkAccessibility()
        checkScreenRecording()
        checkFullDiskAccess()
        await checkAutomation()
        checkContacts()
        lastCheckedAt = Date()
    }

    /// PKT-369 N3: Async variant of checkAll() that includes notification status.
    /// Ensures notification authorization is checked alongside synchronous TCC grants.
    /// Use at all call sites where async context is available.
    public func checkAllAsync() async {
        await checkAll()
        await checkNotifications()
    }

    /// Active reconciliation pass intended for "truth sync" from UI.
    /// Re-runs all probes and briefly waits for TCC state propagation.
    public func recheckAllForTruth() async {
        await checkAll()
        await checkNotifications()
        try? await Task.sleep(nanoseconds: 300_000_000)
        checkAccessibility()
        checkScreenRecording()
        checkFullDiskAccess()
        await checkAutomation()
        checkContacts()
        await checkNotifications()
        lastCheckedAt = Date()
    }

    /// PKT-362 D3: Animated recheck — sets per-row "Checking…" state,
    /// performs recheck, then clears state with staggered timing (0.1s per row).
    /// PermissionView observes grantCheckingState and animates transitions.
    public func animatedRecheckAll() async {
        // Set all v1 grants to "checking"
        for grant in Grant.v1Cases {
            grantCheckingState[grant] = true
        }

        // Perform actual recheck
        await recheckAllForTruth()

        // Stagger clear per-row for visual effect
        for grant in Grant.v1Cases {
            try? await Task.sleep(nanoseconds: 100_000_000)
            grantCheckingState[grant] = false
        }
    }

    /// PKT-362 D6: Reset the needsRestart flag (e.g., after user restarts).
    public func resetNeedsRestart() {
        needsRestart = false
    }

    // MARK: - Detection Methods

    /// Accessibility: AXIsProcessTrusted() — direct API, synchronous Bool.
    /// Returns .granted if the app has Accessibility permission.
    public func checkAccessibility() {
        let trusted = AXIsProcessTrusted()
        accessibilityStatus = trusted ? .granted : .denied
        accessibilityEvidence = .init(
            source: "AXIsProcessTrusted()",
            observed: trusted ? "trusted=true" : "trusted=false",
            detail: "Accessibility trust is read directly from AX API.",
            checkedAt: Date()
        )
    }

    /// Trigger Accessibility permission prompt. Returns current trust state.
    @discardableResult
    public func requestAccessibilityAccess() -> Bool {
        // Avoid direct reference to global CFString var to satisfy Swift 6 concurrency checks.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        accessibilityStatus = trusted ? .granted : .denied
        accessibilityEvidence = .init(
            source: "AXIsProcessTrustedWithOptions(prompt=true)",
            observed: trusted ? "trusted=true" : "trusted=false",
            detail: "Prompt was requested; if still false, grant in Accessibility settings.",
            checkedAt: Date()
        )
        return trusted
    }

    /// Screen Recording: CGPreflightScreenCaptureAccess() — direct API.
    ///
    /// Warning: macOS 15+ (Sequoia) limitation:
    /// Screen Recording permission expires every 7 days. Apple enforces
    /// a weekly re-authorization prompt. There is no API to detect the
    /// remaining time on the grant — only whether it is currently active.
    /// When expired, this will return .denied until the user re-authorizes.
    ///
    /// PKT-362 D6: Tracks transitions to .granted for restart batching.
    public func checkScreenRecording() {
        let previousStatus = screenRecordingStatus
        let granted = CGPreflightScreenCaptureAccess()
        screenRecordingStatus = granted ? .granted : .denied
        // PKT-362 D6: Detect transition to .granted for restart-required grant
        if previousStatus != .granted && screenRecordingStatus == .granted {
            needsRestart = true
        }
        screenRecordingEvidence = .init(
            source: "CGPreflightScreenCaptureAccess()",
            observed: granted ? "granted=true" : "granted=false",
            detail: granted
                ? "Screen Recording is currently active."
                : "Grant may require prompt + relaunch depending on macOS behavior.",
            checkedAt: Date()
        )
    }

    /// Trigger Screen Recording prompt where available. Returns current grant state.
    @discardableResult
    public func requestScreenRecordingAccess() -> Bool {
        if #available(macOS 11.0, *) {
            _ = CGRequestScreenCaptureAccess()
        }
        let previousStatus = screenRecordingStatus
        let granted = CGPreflightScreenCaptureAccess()
        screenRecordingStatus = granted ? .granted : .restartRecommended
        // PKT-362 D6: Detect transition to .granted for restart-required grant
        if previousStatus != .granted && screenRecordingStatus == .granted {
            needsRestart = true
        }
        screenRecordingEvidence = .init(
            source: "CGRequestScreenCaptureAccess() + CGPreflightScreenCaptureAccess()",
            observed: granted ? "granted=true" : "granted=false",
            detail: granted
                ? "Screen Recording appears granted."
                : "Prompted but not yet active; relaunch may be required.",
            checkedAt: Date()
        )
        return granted
    }

    /// Full Disk Access: No direct API available.
    /// Probes the Messages database readability as a TCC-protected sentinel file.
    /// This file requires Full Disk Access. If readable, FDA is granted.
    /// Uses FileManager.urls(for:in:) to locate the user domain path.
    ///
    /// PKT-362 D6: Tracks transitions to .granted for restart batching.
    public func checkFullDiskAccess() {
        let previousStatus = fullDiskAccessStatus
        guard let libURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            fullDiskAccessStatus = .unknown
            return
        }
        let sentinels = [
            libURL.appendingPathComponent("Messages/chat.db").path,
            libURL.appendingPathComponent("Safari/History.db").path,
            libURL.appendingPathComponent("Mail/V10/MailData/Envelope Index").path
        ]
        let fm = FileManager.default
        let existing = sentinels.filter { fm.fileExists(atPath: $0) }
        let readable = existing.filter { fm.isReadableFile(atPath: $0) }

        if !readable.isEmpty {
            fullDiskAccessStatus = .granted
            fullDiskAccessEvidence = .init(
                source: "File readability probe",
                observed: "readable_sentinels=\(readable.count)",
                detail: "Readable protected files: \(readable.joined(separator: ", "))",
                checkedAt: Date()
            )
        } else if !existing.isEmpty {
            fullDiskAccessStatus = .denied
            fullDiskAccessEvidence = .init(
                source: "File readability probe",
                observed: "existing=\(existing.count), readable=0",
                detail: "Protected files exist but are unreadable. Likely Full Disk Access not granted.",
                checkedAt: Date()
            )
        } else {
            // Cannot infer if no protected sentinel files exist on this machine.
            fullDiskAccessStatus = .unknown
            fullDiskAccessEvidence = .init(
                source: "File readability probe",
                observed: "existing=0",
                detail: "No sentinel files were found to infer Full Disk Access state.",
                checkedAt: Date()
            )
        }
        // PKT-362 D6: Detect transition to .granted for restart-required grant
        if previousStatus != .granted && fullDiskAccessStatus == .granted {
            needsRestart = true
        }
    }

    /// Automation: No direct API available.
    /// Probes all registered automation targets by executing a minimal
    /// NSAppleScript against each. On first probe to a new target, macOS
    /// will show the TCC consent prompt for that target, registering
    /// NotionBridge in the Automation preferences pane.
    ///
    /// V1-03: Dynamic target probing. Previously only checked System Events
    /// and Messages. Now probes all targets in `automationTargets`, including
    /// Chrome and Contacts. This fixes the bug where Chrome Apple Events
    /// were silently denied because no probe ever triggered the TCC prompt.
    /// V1-PATCH-003: Now async — probes run via Task.detached on background thread.
    public func checkAutomation() async {
        var results: [String: Bool] = [:]
        for target in Self.automationTargets {
            results[target.bundleID] = await runAppleScriptProbe(target.probe)
        }
        automationTargetGrants = results

        let grantedCount = results.values.filter { $0 }.count
        let totalCount = results.count

        switch grantedCount {
        case totalCount:
            automationStatus = .granted
        case 0:
            automationStatus = .denied
        default:
            automationStatus = .partiallyGranted
        }

        // Build per-target status string for evidence
        let targetDetails = Self.automationTargets.map { target in
            let granted = results[target.bundleID] ?? false
            return "\(target.name)=\(granted ? "granted" : "denied")"
        }.joined(separator: ", ")

        automationEvidence = .init(
            source: "NSAppleScript probe (\(totalCount) targets)",
            observed: "\(grantedCount)/\(totalCount) granted: \(targetDetails)",
            detail: "Automation is target-specific; each target app requires its own TCC consent. "
                + "Probing a target for the first time triggers the macOS permission prompt.",
            checkedAt: Date()
        )
    }

    /// Request Automation permission by re-probing all targets.
    /// On macOS Sequoia, fresh probes to un-granted targets will trigger
    /// the TCC consent prompt. This is non-destructive — it does NOT
    /// reset existing grants via tccutil.
    ///
    /// V1-03: Replaced destructive tccutil reset approach. The old method
    /// (`tccutil reset AppleEvents kup.solutions.notion-bridge`) wiped ALL
    /// existing Automation grants (Messages, System Events, etc.), which
    /// broke working functionality. Now we simply re-probe, which is safe.
    public func requestAutomationAccess() async {
        // Brief pause then re-probe all targets to trigger any missing prompts.
        // Each un-granted target will show a macOS TCC consent dialog.
        try? await Task.sleep(nanoseconds: 300_000_000)
        await checkAutomation()
    }

    /// Contacts: CNContactStore.authorizationStatus(for:) — direct API.
    /// Returns .granted, .denied, or .unknown based on authorization state.
    public func checkContacts() {
        let authStatus = CNContactStore.authorizationStatus(for: .contacts)
        switch authStatus {
        case .authorized:
            contactsStatus = .granted
        case .denied, .restricted:
            contactsStatus = .denied
        case .notDetermined, .limited:
            contactsStatus = .unknown
        @unknown default:
            contactsStatus = .unknown
        }
        contactsEvidence = .init(
            source: "CNContactStore.authorizationStatus(for: .contacts)",
            observed: "status=\(String(describing: authStatus))",
            detail: "Contacts status comes directly from Contacts framework authorization API.",
            checkedAt: Date()
        )
    }

    /// Contacts: Request access — triggers the macOS system prompt.
    /// Call before opening System Settings so the app appears in the Contacts panel.
    /// PKT-346 D2: Added to support permission triggering on Grant tap.
    public func requestContactsAccess() async -> Bool {
        let store = CNContactStore()
        do {
            let granted = try await store.requestAccess(for: .contacts)
            contactsStatus = granted ? .granted : .denied
            contactsEvidence = .init(
                source: "CNContactStore.requestAccess(for: .contacts)",
                observed: granted ? "granted=true" : "granted=false",
                detail: "This reflects the result of an explicit Contacts authorization request.",
                checkedAt: Date()
            )
            return granted
        } catch {
            contactsStatus = .denied
            contactsEvidence = .init(
                source: "CNContactStore.requestAccess(for: .contacts)",
                observed: "error",
                detail: "Contacts authorization threw error: \(error.localizedDescription)",
                checkedAt: Date()
            )
            return false
        }
    }

    /// Notifications: UNUserNotificationCenter — async API.
    /// Unlike synchronous TCC checks, notification status requires async.
    /// Called from recheckAllForTruth() and animatedRecheckAll().
    /// checkAll() remains synchronous and skips this check.
    public func checkNotifications() async {
        // V3-QUALITY: Guard against CLI context (test runner has no bundle → UNUserNotificationCenter crashes)
        guard Bundle.main.bundleIdentifier != nil else {
            print("[PermissionManager] Skipping notification check — no bundle context (CLI/test runner)")
            return
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        // PKT-369 N1: Diagnostic probe — log raw authorization status
        print("[PermissionManager] N1 diagnostic: authorizationStatus=\(settings.authorizationStatus.rawValue) (0=notDetermined, 1=denied, 2=authorized, 3=provisional, 4=ephemeral)")
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            notificationStatus = .granted
        case .denied:
            notificationStatus = .denied
        case .notDetermined:
            notificationStatus = .unknown
        @unknown default:
            notificationStatus = .unknown
        }
        notificationEvidence = .init(
            source: "UNUserNotificationCenter.notificationSettings()",
            observed: "authorizationStatus=\(settings.authorizationStatus.rawValue)",
            detail: "Notification authorization status from UserNotifications framework.",
            checkedAt: Date()
        )
    }

    /// Request notification authorization. Triggers system prompt if .notDetermined.
    /// PKT-369 N2: Always uses notificationSettings() as the source of truth after
    /// requestAuthorization(). The boolean return from requestAuthorization is unreliable
    /// when authorization was determined externally (e.g., granted via System Settings) —
    /// it returns false even though the permission IS granted (UNErrorDomain error 1).
    public func requestNotificationAccess() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            print("[PermissionManager] requestAuthorization error: \(error.localizedDescription)")
        }
        // N2: Source of truth — notificationSettings() reflects actual macOS grant state
        let settings = await center.notificationSettings()
        print("[PermissionManager] N2 source-of-truth: authorizationStatus=\(settings.authorizationStatus.rawValue)")
        let granted: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            granted = true
        default:
            granted = false
        }
        notificationStatus = granted ? .granted : .denied
        notificationEvidence = .init(
            source: "requestAuthorization + notificationSettings() [N2 source-of-truth]",
            observed: "authorizationStatus=\(settings.authorizationStatus.rawValue)",
            detail: granted
                ? "Notification authorization confirmed via notificationSettings()."
                : "Not authorized. authorizationStatus=\(settings.authorizationStatus.rawValue).",
            checkedAt: Date()
        )
        return granted
    }

    // MARK: - UX helpers

    public func statusLabel(for grant: Grant) -> String {
        switch status(for: grant) {
        case .granted:
            return "Granted"
        case .denied:
            return "Not Granted"
        case .unknown:
            return "Unknown"
        case .partiallyGranted:
            return "Partially Granted"
        case .restartRecommended:
            return "Restart Recommended"
        }
    }

    public func remediation(for grant: Grant) -> String {
        switch grant {
        case .accessibility:
            return "Enable in System Settings > Privacy & Security > Accessibility."
        case .screenRecording:
            return "Enable in Screen Recording. Relaunch Notion Bridge if status does not update."
        case .fullDiskAccess:
            return "Enable in Full Disk Access. Relaunch Notion Bridge to ensure new entitlement is observed."
        case .automation:
            if automationStatus == .partiallyGranted {
                let denied = Self.automationTargets.filter {
                    !(automationTargetGrants[$0.bundleID] ?? false)
                }.map(\.name)
                return "Grant Automation access for: \(denied.joined(separator: ", ")). Open System Settings > Privacy & Security > Automation."
            }
            return "Enable Automation targets used by tools (System Events, Messages, Chrome, Contacts)."
        case .notifications:
            return "Allow Notifications when prompted or enable in System Settings > Notifications."
        case .contacts:
            return "Allow Contacts access when prompted or in System Settings > Privacy & Security > Contacts."
        }
    }

    public func debugDetail(for grant: Grant) -> String? {
        switch grant {
        case .automation:
            let details = Self.automationTargets.map { target in
                let granted = automationTargetGrants[target.bundleID] ?? false
                return "\(target.name): \(granted ? "granted" : "not granted")"
            }.joined(separator: " · ")
            return details
        case .fullDiskAccess where fullDiskAccessStatus == .unknown:
            return "No protected sentinel files found to infer Full Disk Access."
        default:
            return nil
        }
    }

    public func evidence(for grant: Grant) -> GrantEvidence? {
        switch grant {
        case .accessibility: return accessibilityEvidence
        case .screenRecording: return screenRecordingEvidence
        case .fullDiskAccess: return fullDiskAccessEvidence
        case .automation: return automationEvidence
        case .notifications: return notificationEvidence
        case .contacts: return contactsEvidence
        }
    }

    // MARK: - Public Target Query

    /// Check if a specific application has Automation permission.
    /// Useful for pre-flight checks before sending Apple Events.
    public func isAutomationGranted(forBundleID bundleID: String) -> Bool {
        automationTargetGrants[bundleID] ?? false
    }

    /// Returns the list of automation targets that are currently denied.
    public var deniedAutomationTargets: [AutomationTarget] {
        Self.automationTargets.filter {
            !(automationTargetGrants[$0.bundleID] ?? false)
        }
    }

    // MARK: - Internal probes

    /// V1-PATCH-003 v2: Runs osascript in a child Process to completely isolate
    /// Security framework calls (code signing, TCC validation) from our process's
    /// main thread. NSAppleScript.executeAndReturnError() internally dispatches
    /// TCC validation to the main thread even from Task.detached — Process-based
    /// approach eliminates this entirely.
    private func runAppleScriptProbe(_ source: String) async -> Bool {
        let probeSource = source
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", probeSource]
            // Suppress stdout/stderr — we only care about exit code
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }
}
