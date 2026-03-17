// PermissionManager.swift — TCC Grant Detection Logic
// V1-02: Detects grant status for all 5 required TCC permissions
// V1-QUALITY-POLISH (PKT-346 D2): Added requestContactsAccess()
//
// Detection methods per grant:
//   - Accessibility: AXIsProcessTrusted() — direct API
//   - Screen Recording: CGPreflightScreenCaptureAccess() — direct API
//   - Full Disk Access: Probe Messages chat.db readability — no direct API
//   - Automation: Probe via NSAppleScript to System Events — no direct API
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
        case contacts

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .screenRecording: return "Screen Recording"
            case .fullDiskAccess: return "Full Disk Access"
            case .automation: return "Automation"
            case .contacts: return "Contacts"
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

    // MARK: - State

    public private(set) var accessibilityStatus: GrantStatus = .unknown
    public private(set) var screenRecordingStatus: GrantStatus = .unknown
    public private(set) var fullDiskAccessStatus: GrantStatus = .unknown
    public private(set) var automationStatus: GrantStatus = .unknown
    public private(set) var contactsStatus: GrantStatus = .unknown
    public private(set) var automationSystemEventsGranted: Bool = false
    public private(set) var automationMessagesGranted: Bool = false
    public private(set) var lastCheckedAt: Date?
    public private(set) var accessibilityEvidence: GrantEvidence?
    public private(set) var screenRecordingEvidence: GrantEvidence?
    public private(set) var fullDiskAccessEvidence: GrantEvidence?
    public private(set) var automationEvidence: GrantEvidence?
    public private(set) var contactsEvidence: GrantEvidence?

    // MARK: - Public API

    /// Returns the current status for the given grant.
    public func status(for grant: Grant) -> GrantStatus {
        switch grant {
        case .accessibility: return accessibilityStatus
        case .screenRecording: return screenRecordingStatus
        case .fullDiskAccess: return fullDiskAccessStatus
        case .automation: return automationStatus
        case .contacts: return contactsStatus
        }
    }

    /// Check all 5 TCC grants. Safe to call from main thread —
    /// individual checks are fast (<100ms total).
    /// Call on popover open and periodically to detect re-grant needs.
    public func checkAll() {
        checkAccessibility()
        checkScreenRecording()
        checkFullDiskAccess()
        checkAutomation()
        checkContacts()
        lastCheckedAt = Date()
    }

    /// Active reconciliation pass intended for "truth sync" from UI.
    /// Re-runs all probes and briefly waits for TCC state propagation.
    public func recheckAllForTruth() async {
        checkAll()
        try? await Task.sleep(nanoseconds: 300_000_000)
        checkAccessibility()
        checkScreenRecording()
        checkFullDiskAccess()
        checkAutomation()
        checkContacts()
        lastCheckedAt = Date()
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
    public func checkScreenRecording() {
        let granted = CGPreflightScreenCaptureAccess()
        screenRecordingStatus = granted ? .granted : .denied
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
        let granted = CGPreflightScreenCaptureAccess()
        screenRecordingStatus = granted ? .granted : .restartRecommended
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
    public func checkFullDiskAccess() {
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
    }

    /// Automation: No direct API available.
    /// Probes by executing a minimal NSAppleScript targeting System Events.
    /// If the script runs without error, Automation permission is granted.
    /// Note: This checks Automation for System Events specifically.
    /// Messages automation is a separate grant checked at send time.
    public func checkAutomation() {
        automationSystemEventsGranted = runAppleScriptProbe("""
            tell application "System Events"
                return name of first process whose frontmost is true
            end tell
        """)
        automationMessagesGranted = runAppleScriptProbe("""
            tell application "Messages"
                return name
            end tell
        """)

        switch (automationSystemEventsGranted, automationMessagesGranted) {
        case (true, true):
            automationStatus = .granted
        case (true, false), (false, true):
            automationStatus = .partiallyGranted
        case (false, false):
            automationStatus = .denied
        }
        automationEvidence = .init(
            source: "NSAppleScript probe (System Events + Messages)",
            observed: "systemEvents=\(automationSystemEventsGranted), messages=\(automationMessagesGranted)",
            detail: "Automation is target-specific; both targets should be allowed for full functionality.",
            checkedAt: Date()
        )
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
            return "Enable Automation targets used by tools (at minimum System Events and Messages)."
        case .contacts:
            return "Allow Contacts access when prompted or in System Settings > Privacy & Security > Contacts."
        }
    }

    public func debugDetail(for grant: Grant) -> String? {
        switch grant {
        case .automation:
            return "System Events: \(automationSystemEventsGranted ? "granted" : "not granted") · Messages: \(automationMessagesGranted ? "granted" : "not granted")"
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
        case .contacts: return contactsEvidence
        }
    }

    // MARK: - Internal probes

    private func runAppleScriptProbe(_ source: String) -> Bool {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        _ = script?.executeAndReturnError(&error)
        return error == nil
    }
}
