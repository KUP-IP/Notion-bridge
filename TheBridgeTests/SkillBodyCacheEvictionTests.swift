// SkillBodyCacheEvictionTests.swift — Wave 3 FB (fetch_skill stale cache)
// TheBridge · Tests

import Foundation
import MCP
import TheBridgeLib

private let skillsDefaultsKey = "com.notionbridge.skills"

private func evictionSampleBody(pageId: String, markdown: String) -> CachedSkillBody {
    CachedSkillBody(
        pageId: pageId, markdown: markdown, title: "Demo", url: "https://www.notion.so/demo",
        properties: .object([:]), lastEditedTime: "2026-06-11T10:00:00.000Z",
        writtenAt: Date(timeIntervalSince1970: 1_700_000_000), ttlHours: 24, callCount: 1
    )
}

private func withTempHomeEviction(_ body: () async throws -> Void) async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bridge-skill-evict-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let priorSkills = UserDefaults.standard.data(forKey: skillsDefaultsKey)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        if let priorSkills {
            UserDefaults.standard.set(priorSkills, forKey: skillsDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: skillsDefaultsKey)
        }
        try? FileManager.default.removeItem(at: tmp)
    }
    try await body()
}

func runSkillBodyCacheEvictionTests() async {
    print("\n\u{1F9F9} SkillBodyCacheEviction (Notion write → body cache evict)")

    await test("evictIfConfiguredSkillPage removes cached body for configured skill") {
        try await withTempHomeEviction {
            let pageId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            await MainActor.run {
                _ = SkillsManager().addSkill(name: "demo-skill-evict", notionPageId: pageId)
            }
            let entry = evictionSampleBody(pageId: pageId, markdown: "# stale")
            try await SkillBodyCacheStore.shared.write(entry)

            await SkillBodyCacheEviction.evictIfConfiguredSkillPage(pageId, refreshRouting: false)
            try expect(await SkillBodyCacheStore.shared.read(pageId: pageId) == nil, "expected cache evicted")
        }
    }

    await test("evictIfConfiguredSkillPage recognizes cached specialist pages") {
        try await withTempHomeEviction {
            UserDefaults.standard.removeObject(forKey: skillsDefaultsKey)
            let parentId = "cccccccccccccccccccccccccccccccc"
            let childId = "dddddddddddddddddddddddddddddddd"
            try await SkillsCacheWriter.shared.write(parent: CachedParent(
                writtenAt: Date(), ttlHours: 24,
                parentId: parentId, parentTitle: "time-keepr",
                children: [CachedSpecialist(id: childId, title: "events-admin")]
            ))
            try await SkillBodyCacheStore.shared.write(
                evictionSampleBody(pageId: childId, markdown: "# stale specialist")
            )

            let changed = await SkillBodyCacheEviction.evictIfConfiguredSkillPage(
                childId, refreshRouting: false
            )
            try expect(changed, "cached specialist should be classified as a skill page")
            try expect(
                await SkillBodyCacheStore.shared.read(pageId: childId) == nil,
                "specialist body cache should be evicted"
            )
        }
    }

    await test("evictIfConfiguredSkillPage is no-op for non-skill pages") {
        try await withTempHomeEviction {
            UserDefaults.standard.removeObject(forKey: skillsDefaultsKey)
            let pageId = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            let entry = evictionSampleBody(pageId: pageId, markdown: "# keep")
            try await SkillBodyCacheStore.shared.write(entry)

            let changed = await SkillBodyCacheEviction.evictIfConfiguredSkillPage(
                pageId, refreshRouting: false
            )
            try expect(!changed, "non-skill page should not be classified")
            try expect(await SkillBodyCacheStore.shared.read(pageId: pageId) != nil, "non-skill page cache should remain")
        }
    }

    await test("cache refresh receipt separates eviction from routing refresh") {
        try await withTempHomeEviction {
            let pageId = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
            await MainActor.run {
                _ = SkillsManager().addSkill(name: "receipt-skill", notionPageId: pageId)
            }
            try await SkillBodyCacheStore.shared.write(
                evictionSampleBody(pageId: pageId, markdown: "# stale")
            )
            let receipt = await SkillBodyCacheEviction.refreshReceipt(
                pageId, refreshRouting: false
            )
            try expect(receipt.matchedSkillPage)
            try expect(receipt.bodyEvicted)
            try expect(!receipt.routingRefreshAttempted)
            try expect(!receipt.routingRefreshSucceeded)
        }
    }

    await test("metadata convergence preserves non-empty local values when Notion fields are empty") {
        let merged = SkillBodyCacheEviction.mergedMetadata(
            currentSummary: "local summary",
            currentTriggers: ["local trigger"],
            currentAntiTriggers: ["local anti"],
            pulled: SkillNotionPulledMetadata(
                summary: "",
                triggerPhrases: [],
                antiTriggerPhrases: []
            )
        )
        try expect(merged.summary == "local summary")
        try expect(merged.triggerPhrases == ["local trigger"])
        try expect(merged.antiTriggerPhrases == ["local anti"])
    }

    await test("metadata convergence prefers canonical Notion values when present") {
        let merged = SkillBodyCacheEviction.mergedMetadata(
            currentSummary: "old",
            currentTriggers: ["old trigger"],
            currentAntiTriggers: ["old anti"],
            pulled: SkillNotionPulledMetadata(
                summary: "new",
                triggerPhrases: ["new trigger"],
                antiTriggerPhrases: ["new anti"]
            )
        )
        try expect(merged.summary == "new")
        try expect(merged.triggerPhrases == ["new trigger"])
        try expect(merged.antiTriggerPhrases == ["new anti"])
    }

}
