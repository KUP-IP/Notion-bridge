// ConfirmPanelView.swift — sticky Confirm body (Deny / Allow / Always Allow)
// TheBridge · UI
//
// Hosted in a dedicated NSPanel (`ConfirmPanelController`) so LSUIElement
// MenuBarExtra popover failure cannot hide the actions. Same submit path
// as the SECURITY_APPROVAL notification (`PendingApprovalSurface.submit`).

import SwiftUI

/// Shared Confirm cards — Dashboard popover and the sticky panel.
public struct ConfirmCardStack: View {
    let prompts: [PendingApprovalPrompt]

    public init(prompts: [PendingApprovalPrompt]) {
        self.prompts = prompts
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(prompts) { prompt in
                ConfirmCard(prompt: prompt)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("confirm-panel-body")
    }
}

public struct ConfirmCard: View {
    let prompt: PendingApprovalPrompt

    public init(prompt: PendingApprovalPrompt) {
        self.prompt = prompt
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 12, weight: .semibold))
                Text("Confirm")
                    .font(BridgeTokens.Typeface.micro.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                if prompt.origin == .remote {
                    Text("remote")
                        .font(BridgeTokens.Typeface.micro.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(0.4)
                        .foregroundStyle(BridgeTokens.warnText)
                }
                Spacer(minLength: 4)
            }
            .foregroundStyle(BridgeTokens.warnText)
            Text(prompt.title)
                .font(BridgeTokens.Typeface.sub.weight(.semibold))
                .foregroundStyle(BridgeTokens.fg1)
                .fixedSize(horizontal: false, vertical: true)
            Text(prompt.body)
                .font(BridgeTokens.Typeface.micro.monospaced())
                .foregroundStyle(BridgeTokens.fg3)
                .lineLimit(3)
            HStack(spacing: 6) {
                BridgeButton(ConfirmPresentation.denyTitle, variant: .danger) {
                    PendingApprovalSurface.shared.submit(id: prompt.id, decision: .deny)
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("confirm-deny")
                BridgeButton(ConfirmPresentation.allowTitle) {
                    PendingApprovalSurface.shared.submit(id: prompt.id, decision: .allow)
                }
                .accessibilityIdentifier("confirm-allow")
                if prompt.allowAlwaysAllow {
                    // Visual primary only — never `.defaultAction`. Return /
                    // Focus / LSUIElement default-button delivery must not
                    // persist Notify (#264). UX polish of this card is #262.
                    BridgeButton(ConfirmPresentation.alwaysAllowTitle, variant: .primary) {
                        PendingApprovalSurface.shared.submit(id: prompt.id, decision: .alwaysAllow)
                    }
                    .accessibilityIdentifier("confirm-always-allow")
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(BridgeTokens.warn.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(BridgeTokens.warn.opacity(0.28), lineWidth: 0.5)
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Confirm \(prompt.toolName)")
    }
}

/// Standalone Confirm window contents (no Dashboard chrome).
public struct ConfirmPanelView: View {
    let prompts: [PendingApprovalPrompt]

    public init(prompts: [PendingApprovalPrompt]) {
        self.prompts = prompts
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Confirm")
                .font(BridgeTokens.Typeface.body.weight(.semibold))
                .foregroundStyle(BridgeTokens.fg1)
                .accessibilityAddTraits(.isHeader)
            ConfirmCardStack(prompts: prompts)
        }
        .padding(14)
        .frame(width: 360)
        .background(BridgeTokens.bgCanvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("confirm-panel")
        .accessibilityLabel("Confirm")
    }
}
