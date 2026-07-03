// MemoryNavigationAnchor.swift — compound Memory deep-link parsing (PKT-MEM sprint)
// TheBridge · UI · Sections

import Foundation

/// Parsed Memory section anchor for MCP navigation + Settings deep-links.
public struct MemoryNavigationResolution: Sendable, Equatable {
    public var tab: MemorySection.Tab?
    public var memoId: String?
    public var inboxFilter: MemorySection.InboxFilter?

    public init(tab: MemorySection.Tab? = nil, memoId: String? = nil, inboxFilter: MemorySection.InboxFilter? = nil) {
        self.tab = tab
        self.memoId = memoId
        self.inboxFilter = inboxFilter
    }
}

public enum MemoryNavigationAnchor {

    /// Resolve a compound anchor string (`memos/<memoId>`, `memos/awaitingAgent`, …).
    ///
    /// 2026-07-03 redesign — the old 5-tab surface (Process/Inbox/Notion/Agent/Processing)
    /// consolidated into 3 (Memos/Recall/Settings). Old anchor heads stay recognized as
    /// **aliases** so already-shipped MCP tool calls / notification payloads / bookmarked
    /// deep-links keep resolving instead of silently landing nowhere:
    ///   process/inbox/curator/pipeline/activity/review/voicememos/voicememo/voice → .memos
    ///   agent/sqlite/remember  → .recall (agent long-term memory, unchanged store)
    ///   notion/registry        → .recall (MemoryNotionTab is retired — its content was fully
    ///                             redundant with the generic Data Sources "memory" entity card,
    ///                             which already cross-links back here; .recall is the closest
    ///                             surviving "browse memory-related records" destination so old
    ///                             links land somewhere sensible rather than erroring)
    ///   processing/models/routing → .settings
    public static func resolve(_ anchor: String?) -> MemoryNavigationResolution {
        guard let raw = anchor?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else { return MemoryNavigationResolution() }

        let parts = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let head = parts.first?
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "") ?? ""
        let tail = parts.count > 1 ? parts.dropFirst().joined(separator: "/") : nil

        switch head {
        case "memos", "process", "curator", "pipeline", "activity",
             "inbox", "review", "voicememos", "voicememo", "voice":
            var res = MemoryNavigationResolution(tab: .memos)
            if let tail, !tail.isEmpty {
                let filterNorm = tail.lowercased().replacingOccurrences(of: "-", with: "")
                if let f = MemorySection.InboxFilter.allCases.first(where: {
                    $0.rawValue.lowercased() == filterNorm
                }) {
                    res.inboxFilter = f
                } else {
                    res.memoId = tail
                }
            }
            return res
        case "recall", "agent", "sqlite", "remember", "notion", "registry":
            return MemoryNavigationResolution(tab: .recall)
        case "settings", "processing", "models", "routing":
            return MemoryNavigationResolution(tab: .settings)
        default:
            if let tab = MemorySection.tab(for: anchor) {
                return MemoryNavigationResolution(tab: tab)
            }
            return MemoryNavigationResolution()
        }
    }
}
