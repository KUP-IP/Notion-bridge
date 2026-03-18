// NotionBridgeApp.swift — @main App Entry Point
// Notion Bridge v2: macOS Tahoe 26 — Liquid Glass
// PKT-353: Removed sparkle fallback, content-adaptive popover, Liquid Glass adoption.
// Previous history: PKT-317, PKT-341, PKT-342, V1-QUALITY-C2, PKT-349 B1
// No Dock icon — pure menu bar app via MenuBarExtra pattern

import SwiftUI
import NotionBridgeLib

/// Load menu bar icon from SPM resource bundle.
/// Uses the bridge logo as a template image for the menu bar.
/// Runtime alpha cleanup: thresholds low-alpha corner pixels to fully transparent
/// so isTemplate rendering doesn't show a faint square outline.
/// PKT-353: Unified to Bundle.module (SPM executable target with processed resources).
/// Bundle.main kept as secondary lookup for .app packaging scenarios.
private func loadMenuBarIcon() -> NSImage? {
    let nsImage: NSImage? =
        Bundle.module.image(forResource: "MenuBarIcon")
        ?? Bundle.main.image(forResource: "MenuBarIcon")
    guard let nsImage else { return nil }

    // Runtime alpha cleanup: pixels with alpha < 0.25 become fully transparent.
    // The source PNGs (Gray colorspace) have near-zero but non-zero alpha in corners,
    // which isTemplate renders as a visible gray square outline.
    if let tiff = nsImage.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff) {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        for y in 0..<h {
            for x in 0..<w {
                if let c = rep.colorAt(x: x, y: y),
                   c.alphaComponent > 0 && c.alphaComponent < 0.25 {
                    rep.setColor(.clear, atX: x, y: y)
                }
            }
        }
        let cleaned = NSImage(size: nsImage.size)
        cleaned.addRepresentation(rep)
        cleaned.size = NSSize(width: 22, height: 22)
        cleaned.isTemplate = true
        return cleaned
    }

    // Fallback if TIFF conversion fails — just resize
    nsImage.size = NSSize(width: 22, height: 22)
    nsImage.isTemplate = true
    return nsImage
}

@main
struct NotionBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// Pre-load the icon once to avoid repeated loading in body evaluations
    private let menuBarIcon: NSImage? = loadMenuBarIcon()

    var body: some Scene {
        MenuBarExtra {
            DashboardView(
                statusBar: appDelegate.statusBar,
                onOpenSettings: {
                    appDelegate.openSettings()
                }
            )
        } label: {
            if let icon = menuBarIcon {
                Image(nsImage: icon)
            } else {
                // Fallback: text label if icon resource unavailable
                Text("NB")
                    .font(.caption2)
                    .fontWeight(.bold)
            }
        }
        .menuBarExtraStyle(.window)

        // Cmd+, keyboard shortcut opens Settings window
        Settings {
            SettingsView(
                statusBar: appDelegate.statusBar,
                permissionManager: appDelegate.permissionManager
            )
        }
    }
}
