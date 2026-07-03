// MemorySection.swift — Settings → Memory pane (PKT-MEM-102 + PKT-MEM-111).
//
// Tabs: Memos · Recall · Settings (2026-07-03 redesign — consolidated from the old
// 5-tab Process/Inbox/Notion/Agent/Processing surface; see
// design/the-bridge-design-system/project/memory-uiiter-log.md for the design phase
// and memory-swiftui-uiiter-log.md for this implementation's iteration log).
// The old Notion tab (registry-bound "memory" entity rows) is retired — fully
// redundant with DataSourcesSection's generic entity card, which already
// cross-links back here (see DataSourcesSection.memoryPaneCrossLink).
//
// This container stays thin, matching every other tab's convention (each tab is a
// self-contained view owning its own state/MCP calls) — the old inline Inbox
// implementation that used to live here directly has moved into MemoryMemosTab,
// which absorbs both the old Process cockpit and the old Inbox triage queue.

import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted when the voice-memo review queue mutates (dismiss, enqueue, …).
    static let voiceMemoReviewDidChange = Notification.Name("com.notionbridge.voiceMemoReviewDidChange")
    /// PKT-MEM-134 — posted from `VoiceMemoProcessor.get`/`.commit` when a connected MCP
    /// agent proposes (`memoConsidering`) or executes (`memoCommitted`) a memo intent, so
    /// an open Memos tab can live-render the event without a manual reload. Deliberately
    /// SEPARATE from `.voiceMemoReviewDidChange` (the review-queue mutation channel) —
    /// this channel is agent-processing-lifecycle only. `public` (unlike the sibling
    /// `.voiceMemoReviewDidChange`) so TheBridgeTests — a separate module that only sees
    /// `TheBridgeLib`'s `public`/`open` surface — can assert delivery directly.
    public static let memoryHubLiveProcessingDidChange = Notification.Name("com.notionbridge.memoryHubLiveProcessingDidChange")
}

/// Sidebar badge counter — shared so BridgeSectionNav can show pending count.
@MainActor
@Observable
public final class MemoryReviewBadgeCounter {
    public static let shared = MemoryReviewBadgeCounter()
    public private(set) var pendingCount: Int = 0

    public func refresh() {
        pendingCount = VoiceMemoReviewStore.load().pendingCount
    }

    private init() {
        refresh()
    }
}

public struct MemorySection: View {
    let anchor: String?

    @ObservedObject private var nav = SettingsNavigation.shared
    @State private var selection: Tab
    @State private var pendingFilter: InboxFilter = .all
    @State private var pendingMemoId: String?

    public enum Tab: String, Hashable, CaseIterable, Sendable {
        case memos, recall, settings

        var label: String {
            switch self {
            case .memos: return "Memos"
            case .recall: return "Recall"
            case .settings: return "Settings"
            }
        }
    }

    /// Status/reason filter for the Memos tab's needs-review group — matches
    /// notification deep-link intent (PKT-MEM-104 follow-up). Type name predates the
    /// 2026-07-03 tab consolidation (was "Inbox"-specific); kept as-is to avoid
    /// churning the public anchor-resolution contract for a naming-only change.
    public enum InboxFilter: String, CaseIterable, Sendable {
        case all, awaitingAgent, noTranscript, routingFailed, lowConfidence

        var label: String {
            switch self {
            case .all: return "All"
            case .awaitingAgent: return "Awaiting agent"
            case .noTranscript: return "No transcript"
            case .routingFailed: return "Routing failed"
            case .lowConfidence: return "Low confidence"
            }
        }
    }

    public init(anchor: String? = nil) {
        self.anchor = anchor
        self._selection = State(initialValue: MemorySection.tab(for: anchor) ?? .memos)
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerCard
                .padding(.horizontal, BridgeTokens.Space.paneH)
                .padding(.top, BridgeTokens.Space.cardGap)
            tabBar
                .padding(.horizontal, BridgeTokens.Space.paneH)
                .padding(.top, 12)
                .padding(.bottom, 12)

            Divider().background(BridgeTokens.hairlineFaint)

            tabBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .onAppear {
            MemoryReviewBadgeCounter.shared.refresh()
            MemoryHubUIState.setMemorySectionVisible(true)
            // Memos absorbs the old Process tab's live-processing cockpit role — the
            // notification-suppression contract (background voice-memo processing skips
            // macOS notifications while the operator is already looking at the live
            // cockpit) now keys off .memos instead of the old .process case.
            MemoryHubUIState.setProcessTabSelected(selection == .memos)
            applyNavigation(from: anchor ?? nav.anchor)
            consumeNavigationAnchorIfNeeded()
        }
        .onDisappear {
            MemoryHubUIState.setMemorySectionVisible(false)
            MemoryHubUIState.setProcessTabSelected(false)
        }
        .onChange(of: selection) { _, newSelection in
            MemoryHubUIState.setProcessTabSelected(newSelection == .memos)
        }
        .onChange(of: anchor) { _, newAnchor in
            applyNavigation(from: newAnchor)
            consumeNavigationAnchorIfNeeded()
        }
        .onChange(of: nav.anchor) { _, newAnchor in
            applyNavigation(from: newAnchor)
            consumeNavigationAnchorIfNeeded()
        }
    }

    private func applyNavigation(from rawAnchor: String?) {
        let res = MemoryNavigationAnchor.resolve(rawAnchor)
        if let t = res.tab { selection = t }
        if let f = res.inboxFilter { pendingFilter = f }
        pendingMemoId = res.memoId
        if res.memoId != nil {
            Task { await BridgeSettingsAutomation.applyMemoryNavigationSideEffects(anchor: rawAnchor) }
        }
    }

    /// Skills-pattern: consume sticky MCP anchor after one apply.
    private func consumeNavigationAnchorIfNeeded() {
        if nav.section == .memory, nav.anchor != nil {
            SettingsNavigation.shared.go(.memory, anchor: nil)
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        BridgeGlassCard(cornerRadius: BridgeTokens.Radius.card, padding: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(NotionPalette.purple.opacity(0.20))
                        .frame(width: 44, height: 44)
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(NotionPalette.purple.opacity(0.85))
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Memory")
                        .font(BridgeTokens.Typeface.hero)
                        .foregroundStyle(BridgeTokens.fg1)
                        .accessibilityAddTraits(.isHeader)
                    Text("How memos get transcribed, understood, and remembered.")
                        .font(BridgeTokens.Typeface.meta)
                        .foregroundStyle(BridgeTokens.fg3)
                }
                Spacer(minLength: 8)
                if selection == .memos, MemoryReviewBadgeCounter.shared.pendingCount > 0 {
                    BridgeBadge("\(MemoryReviewBadgeCounter.shared.pendingCount) pending", tone: .warn, showsDot: true)
                }
            }
        }
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .padding(2)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Memory section tabs")
        .accessibilityIdentifier(BridgeAXID.Memory.tabBar)
    }

    private func tabButton(_ tab: Tab) -> some View {
        let on = selection == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) { selection = tab }
        } label: {
            Text(tab.label)
                .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? BridgeTokens.fg1 : BridgeTokens.fg3)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .frame(minHeight: 28)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(BridgeTokens.accent.opacity(0.18))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(BridgeTokens.accent.opacity(0.45), lineWidth: 0.5))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .accessibilityIdentifier(BridgeAXID.Memory.tab(tab.rawValue))
    }

    @ViewBuilder
    private var tabBody: some View {
        switch selection {
        case .memos: MemoryMemosTab(initialFilter: pendingFilter, initialMemoId: pendingMemoId)
        case .recall: MemoryRecallTab()
        case .settings: MemorySettingsTab()
        }
    }

    // MARK: - Deep-link anchor → tab

    public static func tab(for anchor: String?) -> Tab? {
        MemoryNavigationAnchor.resolve(anchor).tab
    }
}
