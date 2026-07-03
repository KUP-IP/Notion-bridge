// MemoryMemosTab.swift — Settings → Memory → Memos tab (2026-07-03 redesign)
// TheBridge · UI · Sections
//
// Consolidates the old Process (cockpit) + Inbox (triage queue) + Processing-status
// concerns into one status-filtered pipeline. Wave 1 scaffold — full port lands in
// the dedicated implementation wave; see memory-swiftui-uiiter-log.md.

import SwiftUI

public struct MemoryMemosTab: View {
    let initialFilter: MemorySection.InboxFilter
    let initialMemoId: String?

    public init(initialFilter: MemorySection.InboxFilter = .all, initialMemoId: String? = nil) {
        self.initialFilter = initialFilter
        self.initialMemoId = initialMemoId
    }

    public var body: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                BridgeCardLabel("Memos")
                Text("Scaffold placeholder — real implementation lands in the Memos wave.")
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg4)
            }
        }
        .padding(.horizontal, BridgeTokens.Space.paneH)
        .padding(.vertical, BridgeTokens.Space.cardGap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
