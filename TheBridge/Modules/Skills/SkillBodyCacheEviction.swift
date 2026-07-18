// SkillBodyCacheEviction.swift — Bridge (Wave 3 FB)
// Evict the persistent skill body cache when Notion writes touch a skill page.

import Foundation

public struct SkillCacheImpact: Sendable, Equatable {
    public let pageId: String
    public let parentPageIds: [String]

    public init(pageId: String, parentPageIds: [String]) {
        self.pageId = pageId
        self.parentPageIds = parentPageIds
    }
}


public struct SkillCacheRefreshReceipt: Sendable, Equatable {
    public let matchedSkillPage: Bool
    public let bodyEvicted: Bool
    public let routingRefreshAttempted: Bool
    public let routingParentsExpected: Int
    public let routingParentsRefreshed: Int

    public var routingRefreshSucceeded: Bool {
        routingRefreshAttempted && routingParentsExpected > 0
            && routingParentsRefreshed == routingParentsExpected
    }
}

public enum SkillBodyCacheEviction {
    /// Pure classification used by tests and the live invalidation path.
    /// A skill page is either a configured top-level parent or a curated
    /// specialist already present in the routing cache.
    public static func impact(
        rawPageId: String,
        configuredPageIds: [String],
        cachedParents: [CachedParent]
    ) -> SkillCacheImpact? {
        let normalized = NotionClient.normalizePageId(rawPageId)
        guard normalized.count >= 32 else { return nil }

        let configured = Set(configuredPageIds.map(NotionClient.normalizePageId))
        if configured.contains(normalized) {
            return SkillCacheImpact(pageId: normalized, parentPageIds: [normalized])
        }

        let parents = cachedParents.compactMap { parent -> String? in
            let isChild = parent.children.contains {
                NotionClient.normalizePageId($0.id) == normalized
            }
            return isChild ? NotionClient.normalizePageId(parent.parentId) : nil
        }
        guard !parents.isEmpty else { return nil }
        return SkillCacheImpact(
            pageId: normalized,
            parentPageIds: Array(Set(parents)).sorted()
        )
    }


    public static func mergedMetadata(
        currentSummary: String,
        currentTriggers: [String],
        currentAntiTriggers: [String],
        pulled: SkillNotionPulledMetadata
    ) -> SkillNotionPulledMetadata {
        SkillNotionPulledMetadata(
            summary: pulled.summary.isEmpty ? currentSummary : pulled.summary,
            triggerPhrases: pulled.triggerPhrases.isEmpty ? currentTriggers : pulled.triggerPhrases,
            antiTriggerPhrases: pulled.antiTriggerPhrases.isEmpty ? currentAntiTriggers : pulled.antiTriggerPhrases
        )
    }

    /// When `pageId` matches a configured skill or cached specialist, evict
    /// its body and refresh the parent routing cache. The refresh is best-
    /// effort: eviction is the correctness boundary for `fetch_skill`, while
    /// routing refresh heals summaries/aliases immediately when Notion access
    /// is available.
    @discardableResult
    public static func evictIfConfiguredSkillPage(
        _ rawPageId: String,
        refreshRouting: Bool = true
    ) async -> Bool {
        await refreshReceipt(rawPageId, refreshRouting: refreshRouting).matchedSkillPage
    }

    public static func refreshReceipt(
        _ rawPageId: String,
        refreshRouting: Bool = true
    ) async -> SkillCacheRefreshReceipt {
        let configuredPageIds = await MainActor.run {
            SkillsManager().skills.compactMap { skill -> String? in
                let pid = skill.notionPageId.trimmingCharacters(in: .whitespacesAndNewlines)
                return pid.isEmpty ? nil : pid
            }
        }
        let cachedParents = await SkillsCacheReader.shared.readAll()
        guard let affected = impact(
            rawPageId: rawPageId,
            configuredPageIds: configuredPageIds,
            cachedParents: cachedParents
        ) else {
            return SkillCacheRefreshReceipt(
                matchedSkillPage: false, bodyEvicted: false,
                routingRefreshAttempted: false, routingParentsExpected: 0,
                routingParentsRefreshed: 0
            )
        }

        await SkillBodyCacheStore.shared.evict(pageId: affected.pageId)
        await SkillCache.shared.clear()

        guard refreshRouting, let client = try? NotionClient() else {
            return SkillCacheRefreshReceipt(
                matchedSkillPage: true, bodyEvicted: true,
                routingRefreshAttempted: false,
                routingParentsExpected: affected.parentPageIds.count,
                routingParentsRefreshed: 0
            )
        }

        var configuredSkills = SkillsModule.readAllSkills()
        if let index = configuredSkills.firstIndex(where: {
            NotionClient.normalizePageId($0.notionPageId) == affected.pageId
        }), let pageData = try? await client.getPage(pageId: affected.pageId),
           let pageJSON = try? JSONSerialization.jsonObject(with: pageData) as? [String: Any],
           let properties = pageJSON["properties"] as? [String: Any] {
            let current = configuredSkills[index]
            let pulled = SkillNotionMetadata.parsePulledMetadata(properties: properties)
            let merged = mergedMetadata(
                currentSummary: current.summary,
                currentTriggers: current.triggerPhrases,
                currentAntiTriggers: current.antiTriggerPhrases,
                pulled: pulled
            )
            configuredSkills[index] = SkillsModule.SkillConfig(
                name: current.name, source: current.source, enabled: current.enabled,
                routingDiscoverable: current.routingDiscoverable, inCommandPalette: current.inCommandPalette,
                summary: SkillMetadataLimits.clampedSummary(merged.summary),
                triggerPhrases: SkillMetadataLimits.clampedPhraseList(merged.triggerPhrases),
                antiTriggerPhrases: SkillMetadataLimits.clampedPhraseList(merged.antiTriggerPhrases),
                url: current.url, platform: current.platform
            )
            SkillsModule.writeSkills(configuredSkills)
        }

        let source = await MainActor.run {
            SkillsCacheWriter.ParentSource.fromSkillsManager(SkillsManager())
        }
        let expected = await source.load().count
        let refreshed = await SkillsCacheWriter.shared.refreshAll(
            source: source, enumerator: .live(client: client)
        )
        return SkillCacheRefreshReceipt(
            matchedSkillPage: true, bodyEvicted: true,
            routingRefreshAttempted: true, routingParentsExpected: expected,
            routingParentsRefreshed: refreshed
        )
    }

}
