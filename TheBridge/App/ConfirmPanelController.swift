// ConfirmPanelController.swift — sticky NSPanel for the Confirm body
// TheBridge · App
//
// MenuBarExtra `.window` on an LSUIElement app is not a reliable Confirm
// host (PR #260 live-fail: popover window count 0, 0 AXButtons). #262
// fronts this panel on escalate (activate + `.regular`, status-bar level,
// becomes key). It stays until Deny / Allow / Always Allow or the surface
// empties. Always Allow is never the AppKit default button (#264).

import AppKit
import SwiftUI

@MainActor
public final class ConfirmPanelController {
    public static let shared = ConfirmPanelController()

    public nonisolated static let windowTitle = "The Bridge — Confirm"
    /// Confirm never assigns an AppKit default button. Always Allow must
    /// not fire on Return / Focus delivery (#264).
    public nonisolated static let assignsDefaultButton = false

    private var panel: NSPanel?

    public init() {}

    /// True when a Confirm panel is on-screen (tests inspect host state;
    /// this is the AppKit mirror for the live app).
    public var isPanelVisible: Bool {
        panel?.isVisible == true
    }

    public func sync() {
        let host = ConfirmPanelHost.shared
        if host.isPresented && !host.prompts.isEmpty {
            present(prompts: host.prompts)
        } else {
            dismiss()
        }
    }

    public func present(prompts: [PendingApprovalPrompt]) {
        guard Self.canPresentPanel else { return }
        let host = NSHostingController(rootView: ConfirmPanelView(prompts: prompts))
        let fitting = host.view.fittingSize
        let size = NSSize(width: max(fitting.width, 400), height: max(fitting.height, 220))
        host.view.frame = NSRect(origin: .zero, size: size)
        host.view.wantsLayer = true

        let panel = self.panel ?? makePanel(size: size)
        panel.title = Self.windowTitle
        panel.contentView = host.view
        panel.setContentSize(size)
        position(panel, size: size)
        panel.defaultButtonCell = nil
        ConfirmFrontApplicator.apply(to: panel)
        self.panel = panel
    }

    public func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func makePanel(size: NSSize) -> NSPanel {
        // Key-capable titled panel (not `.nonactivatingPanel`). Accessory
        // LSUIElement windows hide on deactivate — #262 fronts this as a
        // regular, key window at status-bar level. Always Allow is never
        // an AppKit default button (#264 / PR #267).
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        panel.title = Self.windowTitle
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = ConfirmDelivery.hidesOnDeactivate
        panel.becomesKeyOnlyIfNeeded = !ConfirmDelivery.becomesKey
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.defaultButtonCell = nil
        return panel
    }

    private func position(_ panel: NSPanel, size: NSSize) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let origin = NSPoint(
            x: screen.maxX - size.width - 16,
            y: screen.maxY - size.height - 8
        )
        panel.setFrameOrigin(origin)
    }

    /// Real NSPanel only in the bundled app — never in TheBridgeTests.
    /// `nonisolated` so SecurityGateUXTests can read it off the main actor
    /// under `-strict-concurrency=complete`.
    public nonisolated static var canPresentPanel: Bool {
        let processName = ProcessInfo.processInfo.processName.lowercased()
        if processName.contains("thebridgetests") || processName.contains("notionbridgetests") {
            return false
        }
        return Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }
}
