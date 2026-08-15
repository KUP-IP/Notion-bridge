// CommandProductPublicationSheet.swift — GitHub #140 D0
//
// Compact developer-only proposal sheet. Standard Commands UI never presents
// this. Git never runs unless a product repo is identified and publication
// Git is explicitly enabled.

import AppKit
import SwiftUI

struct CommandProductPublicationSheet: View {
    @Binding var isPresented: Bool
    @Binding var proposal: CommandProductProposal
    let developerMode: Bool

    @State private var issueText: String = ""
    @State private var status: String = ""

    private var repoIdentity: String? {
        CommandProductPublication.productRepoIdentity()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Propose as Product Change")
                .font(BridgeTokens.Typeface.detail)
                .foregroundStyle(BridgeTokens.fg1)
            Text("Ordinary command updates stay local. Commit and push stay refused until every approval is explicit.")
                .font(BridgeTokens.Typeface.sub)
                .foregroundStyle(BridgeTokens.fg4)

            TextField("Intended product outcome", text: outcomeBinding)
                .textFieldStyle(.roundedBorder)
            TextField("GitHub issue number", text: $issueText)
                .textFieldStyle(.roundedBorder)
                .onChange(of: issueText) { _, value in
                    proposal.issueNumber = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
                    proposal.approvals.issueAssociated = proposal.issueNumber != nil
                }
            TextField("Issue-linked branch", text: branchBinding)
                .textFieldStyle(.roundedBorder)

            if proposal.findings.isEmpty {
                Text("Privacy scan: no secret or sensitive-path tokens found.")
                    .font(BridgeTokens.Typeface.micro)
                    .foregroundStyle(BridgeTokens.ok)
            } else {
                Text("Privacy scan blocked: \(proposal.findings.map(\.token).joined(separator: ", "))")
                    .font(BridgeTokens.Typeface.micro)
                    .foregroundStyle(BridgeTokens.warnText)
                Toggle("I acknowledge these findings and still want to propose", isOn: privacyBinding)
            }

            ScrollView {
                Text(CommandProductPublication.reviewablePatch(proposal))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(BridgeTokens.fg2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 120, maxHeight: 180)
            .padding(8)
            .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 8))

            Text(repoIdentity == nil
                 ? "Repository identity is ambiguous. Git is refused."
                 : "Product repo: \(repoIdentity!)")
                .font(BridgeTokens.Typeface.micro)
                .foregroundStyle(repoIdentity == nil ? BridgeTokens.warnText : BridgeTokens.fg4)

            HStack {
                Toggle("Approve commit", isOn: commitBinding)
                Toggle("Approve push", isOn: pushBinding)
            }
            .font(BridgeTokens.Typeface.sub)

            if !status.isEmpty {
                Text(status)
                    .font(BridgeTokens.Typeface.micro)
                    .foregroundStyle(BridgeTokens.fg3)
            }

            HStack {
                Button("Copy patch") { copyPatch() }
                Button("Mark Ready") { markReady() }
                    .disabled(!CommandProductPublication.canBecomeReady(proposal, developerMode: developerMode))
                Button("Apply approved Git") { applyGit() }
                    .disabled(
                        CommandProductPublication.intendedGitAction(
                            proposal,
                            developerMode: developerMode,
                            hasRepo: repoIdentity != nil,
                            repoIdentity: repoIdentity
                        ) == nil
                        || !CommandProductPublication.gitExecutionEnabled()
                    )
                Spacer()
                Button("Close") { isPresented = false }
            }
        }
        .padding(18)
        .frame(width: 520)
        .onAppear {
            issueText = proposal.issueNumber.map(String.init) ?? "140"
            if proposal.issueNumber == nil {
                proposal.issueNumber = 140
                proposal.approvals.issueAssociated = true
            }
            if proposal.branch == nil || proposal.branch?.isEmpty == true {
                proposal.branch = "feat/issue-140-command-publication"
                proposal.approvals.branchSelected = true
            }
        }
    }

    private var outcomeBinding: Binding<String> {
        Binding(
            get: { proposal.diff.intendedProductOutcome },
            set: { proposal.diff.intendedProductOutcome = $0 }
        )
    }

    private var branchBinding: Binding<String> {
        Binding(
            get: { proposal.branch ?? "" },
            set: {
                proposal.branch = $0
                proposal.approvals.branchSelected = !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        )
    }

    private var privacyBinding: Binding<Bool> {
        Binding(
            get: { proposal.approvals.privacyAcknowledged },
            set: { proposal.approvals.privacyAcknowledged = $0 }
        )
    }

    private var commitBinding: Binding<Bool> {
        Binding(
            get: { proposal.approvals.commitApproved },
            set: { proposal.approvals.commitApproved = $0 }
        )
    }

    private var pushBinding: Binding<Bool> {
        Binding(
            get: { proposal.approvals.pushApproved },
            set: { proposal.approvals.pushApproved = $0 }
        )
    }

    private func copyPatch() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            CommandProductPublication.reviewablePatch(proposal),
            forType: .string
        )
        status = "Copied reviewable patch. Favorite layout and usage history were not included."
    }

    private func markReady() {
        guard let next = CommandProductPublication.markReady(proposal, developerMode: developerMode) else {
            status = "Need outcome, issue, branch, and a clean or acknowledged privacy scan."
            return
        }
        proposal = next
        status = "Ready. Git still requires explicit commit and push approval."
    }

    private func applyGit() {
        guard CommandProductPublication.gitExecutionEnabled() else {
            status = "Publication Git is disabled. Copy the patch instead."
            return
        }
        proposal = CommandProductPublication.applyApprovedGit(
            proposal,
            developerMode: developerMode,
            hasRepo: repoIdentity != nil,
            repoIdentity: repoIdentity,
            execute: { _ in false }
        )
        if proposal.state == .published {
            status = "Published."
        } else {
            status = "Git execute refused. No silent commit or push."
        }
    }
}
