// MemoryRecallTab.swift — Settings → Memory → Recall tab (2026-07-03 redesign)
// TheBridge · UI · Sections
//
// Replaces the old "Agent" tab (MemoryAgentTab.swift, renamed to avoid a name
// collision with the section itself — "Memory" section, "Recall" sub-tab).
// Long-term agent memory, backed by MemoryStore (actor, SQLite+FTS5 — the same
// store behind the memory_remember/memory_recall MCP tools): browse, pin,
// soft-forget. Per the mockup (design/the-bridge-design-system/project/pages/
// page-memory.jsx, `function RecallTab()`): a single-column list of cards with
// a per-row expand toggle, tag badges, source+used-count meta, and a Pin/Forget
// action row, plus a content search field with an explicit empty state.
//
// Deliberately NOT ported from MemoryAgentTab.swift:
//   - MemorySurfacingSettingsCard() (the inline handshake-inject card) — moved
//     to MemorySettingsTab (a separate wave); this tab is memory browsing only.
//   - The scope/type Picker filter bar — the mockup's Recall has no filter UI,
//     only a content search field. Client-side search below matches on `.full`
//     text (== MemoryEntry.text), mirroring the mockup's `m.full` search.
//   - MemoryNotionTab's registry-bound rows — a separate, retired tab (see
//     MemoryNavigationAnchor.swift); Recall is exclusively the MemoryStore list.
//
// Real store bindings preserved from MemoryAgentTab.swift (no fake/stub data):
//   MemoryStore.shared.open() → .list(scope: nil) (no scope filter — matches
//   the mockup, which shows all scopes in one list) → .pin(id:_:) / .forget(id:)
//   (soft-delete only, tombstone via expiresAt, never hard-delete), sorted
//   pinned-first then lastUsedAt descending (client-side, same as the old tab).

import SwiftUI

public struct MemoryRecallTab: View {
    @State private var entries: [MemoryEntry] = []
    @State private var status: String = ""
    @State private var busy = false
    @State private var query: String = ""
    @State private var expanded: Set<String> = []
    @State private var forgetTarget: MemoryEntry?

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public init() {}

    private var visibleEntries: [MemoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            metaRow
            Divider().background(BridgeTokens.hairlineFaint)

            // NOTE: the AXID lives on this ScrollView (the list surface itself), NOT on
            // the outer VStack — a container-level .accessibilityIdentifier propagates
            // down onto every descendant AXUIElement that doesn't set its own, which
            // would SHADOW metaRow's searchField id below it (Loop 1 finding, caught via
            // ax_tree evidence: recall.search/expand/pin/forget/empty never resolved,
            // see memory-swiftui-uiiter-log.md). Scoping the id to just the scrollable
            // list keeps it out of the search field's ancestor chain.
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    if !status.isEmpty && entries.isEmpty {
                        Text(status)
                            .font(BridgeTokens.Typeface.sub)
                            .foregroundStyle(BridgeTokens.fg3)
                    }
                    if entries.isEmpty {
                        emptyState(title: "No agent memories", detail: "Memories saved via memory_remember appear here. Pin important rows or forget stale ones — no inline editing.")
                    } else if visibleEntries.isEmpty {
                        emptyState(title: "No matches", detail: "Try a different search term.")
                    } else {
                        ForEach(visibleEntries, id: \.id) { entry in
                            recallRow(entry)
                        }
                    }
                }
                .padding(.horizontal, BridgeTokens.Space.paneH)
                .padding(.vertical, BridgeTokens.Space.cardGap)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier(BridgeAXID.Memory.Recall.list)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay {
            if busy {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .confirmationDialog(
            "Forget this memory?",
            isPresented: Binding(
                get: { forgetTarget != nil },
                set: { if !$0 { forgetTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Forget", role: .destructive) {
                if let target = forgetTarget {
                    Task { await forgetEntry(target) }
                }
                forgetTarget = nil
            }
            Button("Cancel", role: .cancel) { forgetTarget = nil }
        } message: {
            if let target = forgetTarget {
                Text("“\(target.text)” will be soft-deleted and removed from recall and export.")
            }
        }
        .task { await reload() }
    }

    // MARK: - Meta row

    private var metaRow: some View {
        HStack(spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(BridgeTokens.fg2)
                Text("Recall")
                    .font(BridgeTokens.Typeface.body)
                    .foregroundStyle(BridgeTokens.fg1)
            }
            Text("What the agent has learned across sessions · \(visibleEntries.count) memor\(visibleEntries.count == 1 ? "y" : "ies")")
                .font(BridgeTokens.Typeface.meta)
                .foregroundStyle(BridgeTokens.fg4)
                .lineLimit(1)
            Spacer(minLength: 0)
            // NOTE: `.accessibilityIdentifier` is the OUTERMOST modifier on the whole
            // composed control (icon + field + frame/background/overlay chrome), not
            // applied to the inner TextField. `BridgeInput`'s working callers do the
            // same — e.g. MemorySettingsTab's `BridgeInput("Base URL", text:
            // $providerBaseURL).accessibilityIdentifier(...)` sits after ALL of
            // BridgeInput's own internal frame/padding/background/overlay chain. An
            // id applied to the bare `TextField` (even as its closest/last modifier,
            // still nested inside sibling frame/background/overlay) kept reading back
            // as the ambient section-level `…memory.root` id in the raw AX tree (Loop 1
            // finding — two earlier attempts at this both failed the same way).
            RecallSearchField(query: $query)
                .accessibilityIdentifier(BridgeAXID.Memory.Recall.searchField)
                .accessibilityElement(children: .contain)
        }
        .padding(.horizontal, BridgeTokens.Space.paneH)
        .padding(.vertical, 10)
    }

    // MARK: - Rows

    private func emptyState(title: String, detail: String) -> some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                BridgeCardLabel(title)
                Text(detail)
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(BridgeAXID.Memory.Recall.emptyState)
    }

    private func recallRow(_ entry: MemoryEntry) -> some View {
        let isExpanded = expanded.contains(entry.id)
        return BridgeGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(isExpanded ? entry.text : Self.summarize(entry.text))
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.fg2)
                        .lineLimit(isExpanded ? nil : 4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    RecallLinkButton(
                        title: isExpanded ? "Show summary" : "Show full text",
                        color: BridgeTokens.accentLink
                    ) {
                        if isExpanded { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
                    }
                    .layoutPriority(1)
                    .accessibilityIdentifier(BridgeAXID.Memory.Recall.expandToggle)
                }
                HStack(spacing: 7) {
                    BridgeBadge(entry.scope, tone: .neutral)
                    BridgeBadge(entry.type.rawValue, tone: .info)
                    if entry.pinned {
                        BridgeBadge("Pinned", tone: .ok, showsDot: true)
                    }
                    Spacer(minLength: 8)
                    Text("\(entry.source) · used \(entry.useCount)×")
                        .font(BridgeTokens.Typeface.micro)
                        .foregroundStyle(BridgeTokens.fg5)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    RecallPinButton(pinned: entry.pinned) {
                        Task { await togglePin(entry) }
                    }
                    .accessibilityIdentifier(BridgeAXID.Memory.Recall.pinButton)

                    RecallLinkButton(title: "Forget", color: BridgeTokens.badText) {
                        forgetTarget = entry
                    }
                    .accessibilityIdentifier(BridgeAXID.Memory.Recall.forgetButton)
                }
            }
        }
        // NOTE: deliberately no card-level .accessibilityIdentifier(BridgeAXID.Memory.
        // Recall.row) here — same propagation hazard documented in MemorySettingsTab's
        // overrideRow (and caught here in Loop 1 via ax_tree evidence): a container id
        // shadows every descendant control's own id (expandToggle/pinButton/
        // forgetButton all resolved to one shared id in the raw AX tree). The row is
        // still locatable by its expand/pin/forget button ids or by its text content.
        .accessibilityElement(children: .contain)
    }

    /// Mirrors the mockup's truncation: first ~44 chars, trimmed to a whole word, + ellipsis.
    private static func summarize(_ text: String) -> String {
        guard text.count > 140 else { return text }
        let idx = text.index(text.startIndex, offsetBy: 140)
        var truncated = String(text[..<idx])
        if let lastSpace = truncated.lastIndex(where: { $0.isWhitespace }) {
            truncated = String(truncated[..<lastSpace])
        }
        return truncated + "…"
    }

    // MARK: - Actions

    private func togglePin(_ entry: MemoryEntry) async {
        busy = true
        defer { busy = false }
        do {
            let store = MemoryStore.shared
            try await store.open()
            try await store.pin(id: entry.id, !entry.pinned)
            await reload()
        } catch {
            status = "Could not update pin: \(error.localizedDescription)"
        }
    }

    private func forgetEntry(_ entry: MemoryEntry) async {
        busy = true
        defer { busy = false }
        do {
            let store = MemoryStore.shared
            try await store.open()
            try await store.forget(id: entry.id)
            expanded.remove(entry.id)
            await reload()
        } catch {
            status = "Could not forget memory: \(error.localizedDescription)"
        }
    }

    private func reload() async {
        busy = true
        defer { busy = false }
        do {
            let store = MemoryStore.shared
            try await store.open()
            var list = try await store.list(scope: nil)
            list.sort { lhs, rhs in
                if lhs.pinned != rhs.pinned { return lhs.pinned }
                return lhs.lastUsedAt > rhs.lastUsedAt
            }
            entries = list
            status = entries.isEmpty ? "No agent memories yet." : ""
        } catch {
            entries = []
            status = "Could not load memories: \(error.localizedDescription)"
        }
    }
}

/// Mirrors the mockup's `.link-btn.plain` exactly (materials.css): borderless,
/// `font: 500 t-sub/1`, `padding: 4px 6px`, `border-radius: 5px`, hover fill
/// `color-mix(accent 12%)`, NO trailing `↗` arrow (`.plain` — Loop 1 fix in the
/// mockup's own design phase: the arrow means "opens externally", wrong for
/// Recall's in-place "Show full text"/"Forget" actions). Used for both, with the
/// color parameterized (accent-link for expand, bad-text for Forget) exactly as
/// the mockup's `RecallTab()` does via an inline `style` override.
private struct RecallLinkButton: View {
    let title: String
    let color: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(BridgeTokens.Typeface.sub.weight(.medium))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(BridgeTokens.accent.opacity(hovering ? 0.12 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }
}

/// The content-search field in the Recall meta row: icon + text field + the
/// well/hairline chrome, all self-contained (same shape as `BridgeInput`) so
/// the caller's `.accessibilityIdentifier` — applied as the outermost modifier
/// at the call site in `MemoryRecallTab.metaRow` — actually resolves on this
/// whole control instead of being shadowed by an ambient ancestor id.
private struct RecallSearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BridgeTokens.fg4)
            TextField("Search memories", text: $query)
                .textFieldStyle(.plain)
                .font(BridgeTokens.Typeface.sub)
                .foregroundStyle(BridgeTokens.fg1)
        }
        .padding(.horizontal, 9)
        .frame(width: 190, height: 28)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.input, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.input, style: .continuous).strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
    }
}

/// Pin/Unpin toggle for a Recall row. Mirrors the mockup's `.btn.sm` exactly
/// (materials.css: base `.btn` is 600-weight `t-base`/`Radius.control`/glass-control
/// fill/hairlineStrong border/bevel; `.sm` overrides height→26, padding→10, font
/// size→`t-meta`) but swaps in the `.ok`-toned fill/border/text recipe used by
/// `BridgeBadge`'s `.ok` tone when pinned — the mockup's
/// `.mem-mcard-acts .btn[aria-pressed="true"]` rule.
///
/// Loop 1 fix: an earlier version wrapped a plain `Button` in `BridgeButtonStyle`
/// and tried to override its color with an outer `.foregroundStyle` modifier —
/// that had no visible effect because `BridgeButtonStyle.makeBody` applies its OWN
/// `.foregroundStyle` inside the style's body, which wins over any outer modifier
/// (caught via live screen_capture evidence: "Pinned" rendered identically to
/// "Pin", see memory-swiftui-uiiter-log.md). A dedicated small control sidesteps
/// that pipeline entirely instead of fighting it.
private struct RecallPinButton: View {
    let pinned: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(pinned ? "Pinned" : "Pin")
                .font(BridgeTokens.Typeface.meta.weight(.semibold))
                .foregroundStyle(pinned ? BridgeTokens.okText : BridgeTokens.fg1)
                .frame(height: 26)
                .padding(.horizontal, 10)
                .background(fill)
                .clipShape(shape)
                .overlay(shape.strokeBorder(border, lineWidth: 0.5))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .accessibilityAddTraits(pinned ? [.isSelected] : [])
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous) }

    @ViewBuilder
    private var fill: some View {
        if pinned {
            shape.fill(BridgeTokens.ok.opacity(hovering ? 0.22 : 0.16))
        } else {
            // Same raised-glass base as BridgeButton(variant: .default), so the
            // unpinned state still matches its sibling Forget/BridgeButton controls.
            shape.fill(BridgeTokens.glassControl)
                .overlay(shape.fill(BridgeTokens.fg1.opacity(hovering ? 0.08 : 0)))
        }
    }

    private var border: Color {
        pinned ? BridgeTokens.ok.opacity(0.32) : BridgeTokens.hairlineStrong
    }
}
