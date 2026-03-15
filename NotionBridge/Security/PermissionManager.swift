// PermissionManager.swift — TCC Grant Detection Logic
// V1-02: Detects grant status for all 5 required TCC permissions
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
    }

    // MARK: - State

    public private(set) var accessibilityStatus: GrantStatus = .unknown
    public private(set) var screenRecordingStatus: GrantStatus = .unknown
    public private(set) var fullDiskAccessStatus: GrantStatus = .unknown
    public private(set) var automationStatus: GrantStatus = .unknown
    public private(set) var contactsStatus: GrantStatus = .unknown

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
    }

    // MARK: - Detection Methods

    /// Accessibility: AXIsProcessTrusted() — direct API, synchronous Bool.
    /// Returns .granted if the app has Accessibility permission.
    public func checkAccessibility() {
        accessibilityStatus = AXIsProcessTrusted() ? .granted : .denied
    }

    /// Screen Recording: CGPreflightScreenCaptureAccess() — direct API.
    ///
    /// Warning: macOS 15+ (Sequoia) limitation:
    /// Screen Recording permission expires every 7 days. Apple enforces
    /// a weekly re-authorization prompt. There is no API to detect the
    /// remaining time on the grant — only whether it is currently active.
    /// When expired, this will return .denied until the user re-authorizes.
    public func checkScreenRecording() {
        screenRecordingStatus = CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    /// Full Disk Access: No direct API available.
    /// Probes the Messages database readability as a TCC-protected sentinel file.
    /// This file requires Full Disk Access. If readable, FDA is granted.
    /// Uses FileManager.urls(for:in:) to locate the user domain path.
    public func checkFullDiskAccess() {
        guard let libURL = FileManager.default.urls(
            for: .libraryDirectory, in: .userDomainMask
        ).first else {
            fullDiskAccessStatus = .denied
            return
        }
        let chatDbURL = libURL.appendingPathComponent("Messages/chat.db")
        let accessible = FileManager.default.isReadableFile(atPath: chatDbURL.path)
        fullDiskAccessStatus = accessible ? .granted : .denied
    }

    /// Automation: No direct API available.
    /// Probes by executing a minimal NSAppleScript targeting System Events.
    /// If the script runs without error, Automation permission is granted.
    /// Note: This checks Automation for System Events specifically.
    /// Messages automation is a separate grant checked at send time.
    public func checkAutomation() {
        let script = NSAppleScript(source: """
            tell application "System Events"
                return name of first process whose frontmost is true
            end tell
        """)
        var error: NSDictionary?
        _ = script?.executeAndReturnError(&error)
        automationStatus = (error == nil) ? .granted : .denied
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
    }
}
