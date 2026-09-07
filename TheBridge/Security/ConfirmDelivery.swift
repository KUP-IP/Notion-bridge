// ConfirmDelivery.swift — assertive Confirm + Time Sensitive contract
// TheBridge · Security
//
// #262 (parent #258): Isaiah LIVE UX FAIL on installed 892727ac — Confirm
// lived behind an ATTENTION badge / NC glance / Dashboard section. This
// type is the hermetic contract for:
//   • auto-present + assertively front a sticky panel on escalate
//   • Time Sensitive / Focus-breaking UN registration
//   • Always Allow as the obvious visual primary (not the keyboard default —
//     #264 / PR #267 owns compact-banner / default-button ordering)
//   • dual Grok iPhone↔Mac + Bridge stack (in-app grouping; OS settings
//     for Continuity mirroring — Bridge cannot suppress another app)

import Foundation
import UserNotifications

#if canImport(AppKit)
import AppKit
#endif

/// Presentation + notification registration for Request-tier Confirm.
/// Tests assert this contract without a WindowServer panel or Focus LIVE.
public enum ConfirmDelivery {
    public static let dashboardSectionTitle = "Needs your confirmation"
    public static let panelHeadline = "This action needs your OK"
    public static let alwaysAllowHint = "Remember this tool — next time it runs as Notify (no Confirm card)"
    public static let notificationSubtitle = "Needs your OK — Deny, Allow, or Always Allow"

    /// Always Allow is the visual primary on the Confirm body / Dashboard.
    /// It is never the AppKit keyboard default (Return) — that misfire is #264.
    public static let alwaysAllowIsVisualPrimary = true
    public static let keyboardDefaultIsAlwaysAllow = false

    /// Escalate (surface publish) must open the body without a status-item click.
    public static let autoPresentsOnEscalate = true
    public static let activatesApplication = true
    public static let usesRegularActivationPolicy = true
    public static let becomesKey = true
    public static let hidesOnDeactivate = false

    /// Confirm sits above ordinary document windows (status-bar level).
    public static let panelWindowLevelName = "statusBar"

    public static let confirmThreadIdentifier = "bridge.confirm"
    public static let confirmInterruptionLevel = UNNotificationInterruptionLevel.timeSensitive
    public static let willPresentOptions: UNNotificationPresentationOptions = [.banner, .list, .sound]
    public static let authorizationOptions: UNAuthorizationOptions = [.alert, .sound, .badge, .timeSensitive]

    /// Grok iPhone → Mac Continuity mirroring is owned by the OS / Grok,
    /// not Bridge. We group our own banners; we cannot swallow theirs.
    public static let dualNotifyMitigation = DualNotifyMitigation.groupBridgeBannersDocumentOSMirroring

    public enum DualNotifyMitigation: String, Sendable, Equatable {
        case groupBridgeBannersDocumentOSMirroring
    }

    /// Always Allow on the compact banner must not be a silent/background
    /// action. A Focus / content-extension / first-action misfire on an
    /// unlocked Mac was rewriting notify stickies without a tap (#264 LIVE).
    public static let alwaysAllowRequiresForeground = true
    public static let alwaysAllowRequiresAuthentication = true
    public static let alwaysAllowNotificationActionOptions: UNNotificationActionOptions = [
        .authenticationRequired,
        .foreground
    ]

    /// LSUIElement windows hide on deactivate. Settings, a visible Confirm
    /// window, **or an in-flight Request** keeps `.regular`. WindowTracker
    /// must not flip to `.accessory` before the panel is in `NSApp.windows`
    /// (#262 LIVE on f1c71cc7).
    public static func shouldUseRegularActivationPolicy(
        hasVisibleSettings: Bool,
        hasVisibleConfirm: Bool,
        pendingConfirmCount: Int = 0
    ) -> Bool {
        hasVisibleSettings || hasVisibleConfirm || pendingConfirmCount > 0
    }

    public static func isConfirmWindowTitle(_ title: String) -> Bool {
        title == ConfirmPanelController.windowTitle
    }

    /// Shared Confirm banner fields — tests assert without posting to NC.
    public static func applyConfirmContent(_ content: UNMutableNotificationContent) {
        content.subtitle = notificationSubtitle
        content.threadIdentifier = confirmThreadIdentifier
        content.relevanceScore = 1.0
        content.interruptionLevel = confirmInterruptionLevel
        content.sound = .default
    }
}

/// Apply an assertive front to a live Confirm panel. Tests never call this
/// against a WindowServer surface (`canPresentPanel` is false in TheBridgeTests).
public enum ConfirmFrontApplicator {
    #if canImport(AppKit)
    @MainActor
    public static func apply(to panel: NSPanel, app: NSApplication? = NSApp) {
        guard ConfirmDelivery.usesRegularActivationPolicy, let app else {
            panel.orderFrontRegardless()
            return
        }
        if app.activationPolicy() != .regular {
            app.setActivationPolicy(.regular)
        }
        app.activate(ignoringOtherApps: ConfirmDelivery.activatesApplication)
        panel.level = .statusBar
        panel.hidesOnDeactivate = ConfirmDelivery.hidesOnDeactivate
        panel.becomesKeyOnlyIfNeeded = !ConfirmDelivery.becomesKey
        if ConfirmDelivery.becomesKey {
            panel.makeKeyAndOrderFront(nil)
        }
        panel.orderFrontRegardless()
        if ConfirmDelivery.activatesApplication {
            app.requestUserAttention(.criticalRequest)
        }
    }
    #endif
}
