// ConfirmPresentation.swift — Confirm body host (not ATTENTION-only)
// TheBridge · Security
//
// #260 published a menu-bar badge + Dashboard Confirm card. Live-verify on
// installed main (PR #260) showed ATTENTION / "N Confirm waiting" working,
// then a status-item click cleared the badge and never presented
// Deny / Allow / Always Allow (MenuBarExtra `.window` on LSUIElement
// produced 0 AX windows; UN default/dismiss was mapped to Deny).
//
// This type is the single action path for:
//   • status-item / ATTENTION click
//   • remote (or local) Request publish
//   • SECURITY_APPROVAL banner tap / swipe-away
// Explicit Deny / Allow / Always Allow (and expiry) still resolve.
// Default tap and dismiss only present the Confirm body.

import Foundation
import UserNotifications

/// Result of a UN action or status-item click against an in-flight Confirm.
public enum ConfirmNotificationOutcome: Equatable, Sendable {
    /// Operator chose Deny / Allow / Always Allow — resume the gate.
    case resolve(SecurityApprovalDecision)
    /// Open the Confirm body. Do **not** clear pending or the badge.
    case presentBody
}

/// Pure mapping + presented-state host for the Confirm body.
public enum ConfirmPresentation {
    public static let denyTitle = "Deny"
    public static let allowTitle = "Allow"
    public static let alwaysAllowTitle = "Always Allow"

    /// Titles shown on the Confirm body. Always Allow is on every
    /// Request card (#258) unless the prompt itself opts out.
    public static func actionTitles(allowAlwaysAllow: Bool) -> [String] {
        if allowAlwaysAllow {
            return [denyTitle, allowTitle, alwaysAllowTitle]
        }
        return [denyTitle, allowTitle]
    }

    /// SECURITY_APPROVAL actions only. Unknown / default / dismiss
    /// present the body — they must not grant and must not Deny.
    public static func outcome(forNotificationActionIdentifier identifier: String) -> ConfirmNotificationOutcome {
        switch identifier {
        case NotificationApprovalManager.allowActionIdentifier:
            return .resolve(.allow)
        case NotificationApprovalManager.alwaysAllowActionIdentifier:
            return .resolve(.alwaysAllow)
        case NotificationApprovalManager.cancelActionIdentifier:
            return .resolve(.deny)
        case UNNotificationDefaultActionIdentifier,
             UNNotificationDismissActionIdentifier:
            return .presentBody
        default:
            return .presentBody
        }
    }
}

/// In-process Confirm body. AppKit presents a sticky NSPanel from this
/// state; tests assert presentation without a WindowServer panel.
@MainActor
@Observable
public final class ConfirmPanelHost {
    public static let shared = ConfirmPanelHost()

    public private(set) var isPresented: Bool = false
    public private(set) var prompts: [PendingApprovalPrompt] = []
    public private(set) var lastPresentReason: PresentReason = .none

    public enum PresentReason: String, Sendable, Equatable {
        case none
        case statusItemClick
        case pendingRequest
        case notificationPresentBody
    }

    public init() {}

    public var badgeCount: Int {
        PendingApprovalSurface.shared.pendingCount
    }

    /// Flattened Deny / Allow / Always Allow titles for the visible cards.
    public var visibleActionTitles: [String] {
        guard isPresented, let first = prompts.first else { return [] }
        return ConfirmPresentation.actionTitles(allowAlwaysAllow: first.allowAlwaysAllow)
    }

    /// Status-item / ATTENTION click. Opens the body when anything is
    /// pending. Never toggles closed and never clears the surface.
    public func handleStatusItemClick() {
        refreshPrompts()
        guard !prompts.isEmpty else { return }
        isPresented = true
        lastPresentReason = .statusItemClick
    }

    /// Surface publish / remove. A new pending Request presents the body
    /// (remote and local — origin is not a second gate). Empty → hide.
    public func handleSurfaceChange() {
        refreshPrompts()
        if prompts.isEmpty {
            isPresented = false
            lastPresentReason = .none
        } else {
            isPresented = true
            if lastPresentReason == .none {
                lastPresentReason = .pendingRequest
            }
        }
    }

    /// Banner tap or swipe-away: same body as a status-item click.
    public func handlePresentBodyRequest() {
        refreshPrompts()
        guard !prompts.isEmpty else { return }
        isPresented = true
        lastPresentReason = .notificationPresentBody
    }

    public func resetForTesting() {
        isPresented = false
        prompts = []
        lastPresentReason = .none
    }

    private func refreshPrompts() {
        prompts = PendingApprovalSurface.shared.snapshot()
    }
}
