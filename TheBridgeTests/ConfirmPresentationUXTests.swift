// ConfirmPresentationUXTests.swift
// TheBridge · Tests
//
// #262 — assertive Confirm presentation + Time Sensitive registration.
// Hermetic: no WindowServer panel, no Focus LIVE. Bridge Keepr owns LIVE UX.

import Foundation
import UserNotifications
import TheBridgeLib

#if canImport(AppKit)
import AppKit
#endif

func runConfirmPresentationUXTests() async {
    print("\n🔔  Confirm presentation UX Tests (#262)")

    await test("Confirm auto-presents on escalate without status-item click") {
        PendingApprovalSurface.shared.resetForTesting()
        defer { PendingApprovalSurface.shared.resetForTesting() }
        await MainActor.run { ConfirmPanelHost.shared.resetForTesting() }
        PendingApprovalSurface.shared.publish(PendingApprovalPrompt(
            id: "ux-auto-1",
            title: "The Bridge wants to standing_orders_delete",
            body: "id=ux-auto",
            toolName: "standing_orders_delete",
            allowAlwaysAllow: true,
            origin: .remote
        ))
        await MainActor.run { ConfirmPanelHost.shared.handleSurfaceChange() }
        try expect(ConfirmDelivery.autoPresentsOnEscalate)
        try expect(await MainActor.run { ConfirmPanelHost.shared.isPresented },
                   "escalate must open the Confirm body, not ATTENTION-only")
        try expect(await MainActor.run { ConfirmPanelHost.shared.lastPresentReason } == .pendingRequest)
        try expect(await MainActor.run { ConfirmPanelHost.shared.visibleActionTitles.contains("Always Allow") })
    }

    await test("second escalate re-asserts presented (not badge-only)") {
        PendingApprovalSurface.shared.resetForTesting()
        defer { PendingApprovalSurface.shared.resetForTesting() }
        await MainActor.run { ConfirmPanelHost.shared.resetForTesting() }
        PendingApprovalSurface.shared.publish(PendingApprovalPrompt(
            id: "ux-refront-1",
            title: "The Bridge wants to standing_orders_delete",
            body: "id=refront",
            toolName: "standing_orders_delete",
            allowAlwaysAllow: true,
            origin: .local
        ))
        await MainActor.run { ConfirmPanelHost.shared.handleStatusItemClick() }
        try expect(await MainActor.run { ConfirmPanelHost.shared.lastPresentReason } == .statusItemClick)
        await MainActor.run { ConfirmPanelHost.shared.handleSurfaceChange() }
        try expect(await MainActor.run { ConfirmPanelHost.shared.isPresented })
        try expect(await MainActor.run { ConfirmPanelHost.shared.lastPresentReason } == .pendingRequest,
                   "surface publish must re-assert escalate, not stay ATTENTION-click-only")
    }

    await test("Always Allow is visual primary and never the keyboard default") {
        try expect(ConfirmDelivery.alwaysAllowIsVisualPrimary)
        try expect(ConfirmDelivery.keyboardDefaultIsAlwaysAllow == false,
                   "#264: Always Allow must not be the Return-key default")
        try expect(ConfirmPresentation.actionTitles(allowAlwaysAllow: true)
                    == ["Deny", "Allow", "Always Allow"])
        try expect(ConfirmDelivery.alwaysAllowHint.contains("Notify"),
                   "Always Allow hint must say it sticks Notify")
        try expect(ConfirmDelivery.dashboardSectionTitle == "Needs your confirmation")
        try expect(ConfirmDelivery.panelHeadline.contains("OK"))
    }

    await test("Time Sensitive registration includes Focus-breaking options") {
        try expect(
            ConfirmDelivery.authorizationOptions.contains(.timeSensitive),
            "requestAuthorization must ask for Time Sensitive (first prompt wins)"
        )
        try expect(ConfirmDelivery.authorizationOptions.contains(.alert))
        try expect(ConfirmDelivery.authorizationOptions.contains(.sound))
        try expect(ConfirmDelivery.authorizationOptions.contains(.badge))
        try expect(ConfirmDelivery.confirmInterruptionLevel == .timeSensitive)
        try expect(ConfirmDelivery.willPresentOptions.contains(.banner))
        try expect(ConfirmDelivery.willPresentOptions.contains(.sound))
        try expect(ConfirmDelivery.confirmThreadIdentifier == "bridge.confirm")
        try expect(ConfirmDelivery.notificationSubtitle.contains("Always Allow"))
        let content = UNMutableNotificationContent()
        ConfirmDelivery.applyConfirmContent(content)
        try expect(content.interruptionLevel == .timeSensitive)
        try expect(content.threadIdentifier == "bridge.confirm")
        try expect(content.subtitle == ConfirmDelivery.notificationSubtitle)
        try expect(content.sound != nil)
    }

    await test("Confirm keeps regular activation policy so LSUIElement cannot hide it") {
        try expect(ConfirmDelivery.activatesApplication)
        try expect(ConfirmDelivery.usesRegularActivationPolicy)
        try expect(ConfirmDelivery.becomesKey)
        try expect(ConfirmDelivery.hidesOnDeactivate == false)
        try expect(
            ConfirmDelivery.shouldUseRegularActivationPolicy(
                hasVisibleSettings: false,
                hasVisibleConfirm: true
            ),
            "visible Confirm must keep .regular"
        )
        try expect(
            ConfirmDelivery.shouldUseRegularActivationPolicy(
                hasVisibleSettings: true,
                hasVisibleConfirm: false
            )
        )
        try expect(
            ConfirmDelivery.shouldUseRegularActivationPolicy(
                hasVisibleSettings: false,
                hasVisibleConfirm: false
            ) == false
        )
        try expect(ConfirmDelivery.isConfirmWindowTitle(ConfirmPanelController.windowTitle))
        try expect(ConfirmDelivery.isConfirmWindowTitle("Settings") == false)
        try expect(ConfirmDelivery.panelWindowLevelName == "statusBar")
        try expect(
            Notification.Name.confirmPanelDidChange.rawValue
                == "com.notionbridge.confirmPanelDidChange",
            "dismiss must notify WindowTracker — orderOut does not fire willClose"
        )
    }

    await test("dual-notify mitigation is grouping + operator OS/Grok docs") {
        try expect(
            ConfirmDelivery.dualNotifyMitigation
                == .groupBridgeBannersDocumentOSMirroring
        )
        let doc = try String(
            contentsOfFile: "docs/operator/confirm-focus-and-dual-notify.md",
            encoding: .utf8
        )
        try expect(doc.contains("Time Sensitive"), "Focus/TCC doc must name Time Sensitive")
        try expect(doc.contains("Focus"), "Focus/TCC doc must name Focus")
        try expect(doc.contains("Grok"), "dual-notify doc must name Grok mirroring")
        try expect(doc.contains("iPhone"), "dual-notify doc must name iPhone mirroring")
        try expect(doc.contains("Notification Mirroring") || doc.contains("iPhone Notifications"),
                   "dual-notify doc must name the OS setting")
        try expect(doc.contains("bridge.confirm"))
        try expect(doc.contains("#264") || doc.contains("PR #267"),
                   "stacking note for compact-banner / default-button lane")
    }

    await test("test process still never opens a live Confirm NSPanel") {
        try expect(ConfirmPanelController.canPresentPanel == false)
        try expect(ConfirmPanelController.windowTitle == "The Bridge — Confirm")
    }
}
