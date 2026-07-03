// MemorySettingsTab.swift — Settings → Memory → Settings tab (2026-07-03 redesign)
// TheBridge · UI · Sections
//
// Consolidates the old Processing tab (curator routing / transcription ladder / cloud
// provider) with the Handshake Memory Inject config previously embedded inline at the
// top of the Agent tab. Wave 1 scaffold — full port lands in the dedicated
// implementation wave.

import SwiftUI

public struct MemorySettingsTab: View {
    public init() {}

    public var body: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                BridgeCardLabel("Settings")
                Text("Scaffold placeholder — real implementation lands in the Settings wave.")
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg4)
            }
        }
        .padding(.horizontal, BridgeTokens.Space.paneH)
        .padding(.vertical, BridgeTokens.Space.cardGap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
