// NotificationContentExtension — SecurityGate custom notification UI
// PKT-553 (SEQ 10): Full SwiftUI-equivalent AppKit implementation for the four
// SecurityGate notification categories. Reads structured data from userInfo
// populated by PKT-552 and renders a tailored layout per categoryIdentifier.
//
// Extension point:  com.apple.usernotifications.content-extension
// Principal class:  NotificationViewController
//
// The extension runs in its own process sandbox and cannot import
// NotionBridgeLib / BridgeTheme directly, so design tokens are duplicated
// locally in `NotificationColors`.
//
// Categories handled:
//   • SECURITY_APPROVAL            ~120pt  lock icon + command preview + risk accent
//   • SECURITY_APPROVAL_NO_ALWAYS  ~140pt  warning strip + lock icon + command preview
//   • NOTIFY_NOTION                 ~90pt  check icon + tool name + notion summary
//   • NOTIFY_GENERIC                ~70pt  check icon + tool name + command summary
//
// All display data is sourced from UNNotificationContent.userInfo; any
// missing key falls back to a safe default so the extension never shows empty.

import Cocoa
import UserNotifications
import UserNotificationsUI

// MARK: - Category identifiers (kept local to avoid importing parent app)

private enum NotificationCategory: String {
    case securityApproval          = "SECURITY_APPROVAL"
    case securityApprovalNoAlways  = "SECURITY_APPROVAL_NO_ALWAYS"
    case notifyNotion              = "NOTIFY_NOTION"
    case notifyGeneric             = "NOTIFY_GENERIC"
}

// MARK: - Risk levels

private enum RiskLevel: String {
    case low, medium, high

    init(rawString: String?) {
        switch (rawString ?? "").lowercased() {
        case "low":    self = .low
        case "high":   self = .high
        default:       self = .medium
        }
    }

    var accentColor: NSColor {
        switch self {
        case .low:    return NotificationColors.riskLow
        case .medium: return NotificationColors.riskMedium
        case .high:   return NotificationColors.riskHigh
        }
    }
}

// MARK: - Design tokens (duplicated from BridgeTheme for extension isolation)

private enum NotificationColors {
    static let riskLow           = NSColor.systemGreen.withAlphaComponent(0.70)
    static let riskMedium        = NSColor.systemOrange.withAlphaComponent(0.70)
    static let riskHigh          = NSColor.systemRed.withAlphaComponent(0.70)
    static let codeBackground    = NSColor.secondaryLabelColor.withAlphaComponent(0.15)
    static let warningBackground = NSColor.systemYellow.withAlphaComponent(0.15)
    static let warningText       = NSColor.systemOrange
    static let successAccent     = NSColor.systemGreen.withAlphaComponent(0.70)
    static let mutedText         = NSColor.secondaryLabelColor
}

// MARK: - userInfo key names (mirror PKT-552 contract)

private enum UserInfoKey {
    static let toolName          = "toolName"
    static let argumentsSummary  = "argumentsSummary"
    static let riskLevel         = "riskLevel"
    static let categoryType      = "categoryType"
    static let notionPageURL     = "notionPageURL"
    static let notionBlockURL    = "notionBlockURL"
}

// MARK: - View controller

@objc(NotificationViewController)
final class NotificationViewController: NSViewController, UNNotificationContentExtension {

    // Root container. We rebuild the subview hierarchy per-notification so each
    // category gets exactly the layout it needs without leftover constraints.
    private let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 90))

    override func loadView() {
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        self.view = container
    }

    func didReceive(_ notification: UNNotification) {
        let request = notification.request
        let content = request.content
        let userInfo = content.userInfo

        // Prefer explicit categoryType in userInfo, fall back to
        // categoryIdentifier on the request content.
        let categoryRaw =
            (userInfo[UserInfoKey.categoryType] as? String)
            ?? content.categoryIdentifier
        let category = NotificationCategory(rawValue: categoryRaw)

        let toolName = (userInfo[UserInfoKey.toolName] as? String)
            ?? (content.title.isEmpty ? "Tool" : content.title)

        let argumentsSummary = (userInfo[UserInfoKey.argumentsSummary] as? String)
            ?? (content.body.isEmpty ? "Tool was called" : content.body)

        let riskLevel = RiskLevel(rawString: userInfo[UserInfoKey.riskLevel] as? String)
        let notionPageURL = userInfo[UserInfoKey.notionPageURL] as? String

        // Clear any previously rendered subviews.
        container.subviews.forEach { $0.removeFromSuperview() }

        switch category {
        case .securityApproval:
            renderSecurityApproval(toolName: toolName,
                                   argumentsSummary: argumentsSummary,
                                   risk: riskLevel)
            preferredContentSize = NSSize(width: 360, height: 120)

        case .securityApprovalNoAlways:
            renderSecurityApprovalNoAlways(toolName: toolName,
                                           argumentsSummary: argumentsSummary,
                                           risk: riskLevel)
            preferredContentSize = NSSize(width: 360, height: 140)

        case .notifyNotion:
            renderNotifyNotion(toolName: toolName,
                               argumentsSummary: argumentsSummary,
                               notionPageURL: notionPageURL)
            preferredContentSize = NSSize(width: 360, height: 90)

        case .notifyGeneric:
            renderNotifyGeneric(toolName: toolName,
                                argumentsSummary: argumentsSummary)
            preferredContentSize = NSSize(width: 360, height: 70)

        case .none:
            // Unknown category — fall back to a neutral, generic layout.
            renderNotifyGeneric(toolName: toolName,
                                argumentsSummary: argumentsSummary)
            preferredContentSize = NSSize(width: 360, height: 70)
        }
    }

    // MARK: - Category renderers

    /// SECURITY_APPROVAL — request-tier with Always Allow available.
    /// Layout: risk-accent bar | 🔒 toolName | monospaced command preview
    private func renderSecurityApproval(toolName: String,
                                        argumentsSummary: String,
                                        risk: RiskLevel) {
        let accent = makeAccentBar(color: risk.accentColor)
        let header = makeHeader(icon: "🔒", title: toolName)
        let leadIn = makeBodyLabel("\(toolName) wants to run:")
        let codeBlock = makeCodeBlock(text: argumentsSummary)

        let stack = verticalStack(spacing: 6, views: [header, leadIn, codeBlock])
        container.addSubview(accent)
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            accent.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            accent.topAnchor.constraint(equalTo: container.topAnchor),
            accent.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            accent.widthAnchor.constraint(equalToConstant: 4),

            stack.leadingAnchor.constraint(equalTo: accent.trailingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -10),
        ])
    }

    /// SECURITY_APPROVAL_NO_ALWAYS — request-tier for neverAutoApprove tools.
    /// Layout: warning strip | ⚠️ toolName | monospaced command preview
    private func renderSecurityApprovalNoAlways(toolName: String,
                                                argumentsSummary: String,
                                                risk: RiskLevel) {
        let warning = makeWarningStrip(text: "Per-call approval required")
        let header = makeHeader(icon: "⚠️", title: toolName)
        let leadIn = makeBodyLabel("\(toolName) wants to run:")
        let codeBlock = makeCodeBlock(text: argumentsSummary)

        let stack = verticalStack(spacing: 6, views: [warning, header, leadIn, codeBlock])
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -10),
        ])
    }

    /// NOTIFY_NOTION — notify-tier Notion tools, success accent.
    /// Layout: green accent | ✓ toolName | page / property summary
    private func renderNotifyNotion(toolName: String,
                                    argumentsSummary: String,
                                    notionPageURL: String?) {
        let accent = makeAccentBar(color: NotificationColors.successAccent)
        let header = makeHeader(icon: "✓", title: toolName)
        let summary = makeBodyLabel(argumentsSummary)
        summary.maximumNumberOfLines = 2

        var children: [NSView] = [header, summary]
        if let urlString = notionPageURL, !urlString.isEmpty {
            let hint = makeMutedLabel("Page: \(urlString)")
            hint.maximumNumberOfLines = 1
            hint.lineBreakMode = .byTruncatingMiddle
            children.append(hint)
        }

        let stack = verticalStack(spacing: 4, views: children)
        container.addSubview(accent)
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            accent.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            accent.topAnchor.constraint(equalTo: container.topAnchor),
            accent.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            accent.widthAnchor.constraint(equalToConstant: 4),

            stack.leadingAnchor.constraint(equalTo: accent.trailingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -10),
        ])
    }

    /// NOTIFY_GENERIC — notify-tier non-Notion tools, neutral styling.
    /// Layout: ✓ toolName | "Ran: <summary>"
    private func renderNotifyGeneric(toolName: String,
                                     argumentsSummary: String) {
        let header = makeHeader(icon: "✓", title: toolName, titleColor: NotificationColors.mutedText)
        let body = makeMutedLabel("Ran: \(argumentsSummary)")
        body.maximumNumberOfLines = 2

        let stack = verticalStack(spacing: 2, views: [header, body])
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -8),
        ])
    }

    // MARK: - View factories

    private func verticalStack(spacing: CGFloat, views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func makeAccentBar(color: NSColor) -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = color.cgColor
        bar.layer?.cornerRadius = 2
        bar.translatesAutoresizingMaskIntoConstraints = false
        return bar
    }

    private func makeHeader(icon: String,
                            title: String,
                            titleColor: NSColor = .labelColor) -> NSView {
        let iconLabel = NSTextField(labelWithString: icon)
        iconLabel.font = .systemFont(ofSize: 14)
        iconLabel.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = titleColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [iconLabel, titleLabel])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .firstBaseline
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func makeBodyLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeMutedLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = NotificationColors.mutedText
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeCodeBlock(text: String) -> NSView {
        let wrapper = NSView()
        wrapper.wantsLayer = true
        wrapper.layer?.backgroundColor = NotificationColors.codeBackground.cgColor
        wrapper.layer?.cornerRadius = 4
        wrapper.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -6),
        ])
        return wrapper
    }

    private func makeWarningStrip(text: String) -> NSView {
        let wrapper = NSView()
        wrapper.wantsLayer = true
        wrapper.layer?.backgroundColor = NotificationColors.warningBackground.cgColor
        wrapper.layer?.cornerRadius = 4
        wrapper.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NotificationColors.warningText
        label.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -4),
        ])
        return wrapper
    }
}
