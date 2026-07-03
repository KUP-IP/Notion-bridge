// MemoryRecallTab.swift — Settings → Memory → Recall tab (2026-07-03 redesign)
// TheBridge · UI · Sections
//
// Replaces the old "Agent" tab (renamed to avoid a name collision with the section
// itself). Long-term agent memory (MemoryStore, SQLite+FTS5) — browse, pin, forget.
// Wave 1 scaffold — full port lands in the dedicated implementation wave.

import SwiftUI

public struct MemoryRecallTab: View {
    public init() {}

    public var body: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                BridgeCardLabel("Recall")
                Text("Scaffold placeholder — real implementation lands in the Recall wave.")
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg4)
            }
        }
        .padding(.horizontal, BridgeTokens.Space.paneH)
        .padding(.vertical, BridgeTokens.Space.cardGap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
