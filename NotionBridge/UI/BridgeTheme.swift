// BridgeTheme.swift — Design System for NotionBridge
// PKT-353: Liquid Glass + Popover Redesign
// Semantic color palette, spacing scale, and reusable ViewModifiers
// Applied to DashboardView; other UI files can adopt incrementally.

import SwiftUI

// MARK: - Color Palette

/// Semantic color palette for NotionBridge UI.
/// Uses system-adaptive colors that work with Liquid Glass materials.
enum BridgeColors {
    /// Primary text color — high contrast, used for headings and key labels
    static let primary = Color.primary

    /// Secondary text color — medium contrast, used for supporting text
    static let secondary = Color.secondary

    /// Success indicator — server running, connected status
    static let success = Color.green

    /// Error indicator — server stopped, disconnected status
    static let error = Color.red

    /// Muted text color — tertiary info, timestamps, subtle labels
    static let muted = Color(nsColor: .tertiaryLabelColor)
}

// MARK: - Spacing Scale

/// Consistent spacing constants based on a 4pt grid.
enum BridgeSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
}

// MARK: - View Modifiers

/// Standard label style for primary row labels in the dashboard.
/// Callout font, primary color, no extra weight.
struct BridgeLabelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.callout)
            .foregroundStyle(BridgeColors.primary)
    }
}

/// Secondary value style for supporting info — version numbers, timestamps, stats.
/// Caption font, secondary color.
struct BridgeSecondaryModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption)
            .foregroundStyle(BridgeColors.secondary)
    }
}

/// Standard row layout modifier — consistent horizontal padding and vertical spacing.
/// Used for each content section in the dashboard popover.
struct BridgeRowModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, BridgeSpacing.md)
            .padding(.vertical, BridgeSpacing.sm)
    }
}

// MARK: - View Extensions

extension View {
    /// Apply primary label styling (callout font, primary color).
    func bridgeLabel() -> some View {
        modifier(BridgeLabelModifier())
    }

    /// Apply secondary value styling (caption font, secondary color).
    func bridgeSecondary() -> some View {
        modifier(BridgeSecondaryModifier())
    }

    /// Apply standard row padding (16pt horizontal, 12pt vertical).
    func bridgeRow() -> some View {
        modifier(BridgeRowModifier())
    }
}
