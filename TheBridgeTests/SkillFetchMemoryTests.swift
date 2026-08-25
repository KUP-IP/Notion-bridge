// SkillFetchMemoryTests.swift — policy-then-memory fetch_skill seam
// TheBridge · Tests

@_spi(Testing) import TheBridgeLib
import Foundation
import MCP

private let fetchNow = Date(timeIntervalSince1970: 1_785_196_800)
private let fetchPageA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
private let fetchPageB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

private func fetchGeneration(id: String = fetchPageA) -> SkillRuntimeGeneration {
    .init(generationID: "generation-1", snapshotID: "snapshot-1",
          compilerVersion: "1.0.0", compiledAt: fetchNow,
          entries: [.init(notionPageUUID: id, displayName: "Alpha", slug: "alpha",
                          desiredExposure: .standard, publishedExposure: .standard,
                          lifecycleOverrideReason: nil, approvalID: "approval-1",
                          notionLastEditedTime: "2026-07-28T00:00:00.000Z",
                          url: "https://www.notion.so/\(id)")])
}

func runSkillFetchMemoryTests() async {
    print("\n🧠 fetch_skill policy-then-memory")

    await test("disabled skill is denied even when memory cache is warm") {
        let cache = SkillCache()
        let key = "alpha|meta=warm"
        await cache.set(key, content: .object(["content": .string("stale-body")]))
        let gate = SkillRuntimeExposureGate(generation: fetchGeneration())
        let result = await SkillsModule.fetchMemoryResult(
            enabled: false, pageId: fetchPageA, cacheKey: key,
            cache: cache, gate: gate
        )
        guard case .disabled = result else {
            throw TestError.assertion("disabled must beat a warm cache, got \(result)")
        }
    }

    await test("unpublished page is denied even when memory cache is warm") {
        let cache = SkillCache()
        let key = "alpha|meta=warm"
        await cache.set(key, content: .object(["content": .string("stale-body")]))
        let gate = SkillRuntimeExposureGate(generation: fetchGeneration(id: fetchPageA))
        let result = await SkillsModule.fetchMemoryResult(
            enabled: true, pageId: fetchPageB, cacheKey: key,
            cache: cache, gate: gate
        )
        guard case .unpublished = result else {
            throw TestError.assertion("unpublished must beat a warm cache, got \(result)")
        }
    }

    await test("denylisted page is denied even when memory cache is warm") {
        let cache = SkillCache()
        let key = "alpha|meta=warm"
        await cache.set(key, content: .object(["content": .string("stale-body")]))
        let gate = SkillRuntimeExposureGate(
            generation: fetchGeneration(),
            emergencyDenylist: [fetchPageA]
        )
        let result = await SkillsModule.fetchMemoryResult(
            enabled: true, pageId: fetchPageA, cacheKey: key,
            cache: cache, gate: gate
        )
        guard case .unpublished = result else {
            throw TestError.assertion("denylist must beat a warm cache, got \(result)")
        }
    }

    await test("allowed skill may serve memory cache after policy") {
        let cache = SkillCache()
        let key = "alpha|meta=warm"
        await cache.set(key, content: .object(["content": .string("fresh-body")]))
        let gate = SkillRuntimeExposureGate(generation: fetchGeneration())
        let result = await SkillsModule.fetchMemoryResult(
            enabled: true, pageId: fetchPageA, cacheKey: key,
            cache: cache, gate: gate
        )
        guard case .cached(let value) = result,
              case .object(let obj) = value,
              case .string(let body) = obj["content"],
              body == "fresh-body" else {
            throw TestError.assertion("policy pass must serve memory, got \(result)")
        }
    }

    await test("URL identity change misses memory when the cache key includes page id") {
        let cache = SkillCache()
        let oldKey = "alpha|meta=old-page"
        await cache.set(oldKey, content: .object(["content": .string("old-body")]))
        let gate = SkillRuntimeExposureGate(generation: fetchGeneration())
        let result = await SkillsModule.fetchMemoryResult(
            enabled: true, pageId: fetchPageA, cacheKey: "alpha|meta=new-page",
            cache: cache, gate: gate
        )
        guard case .miss = result else {
            throw TestError.assertion("page-id token change must miss, got \(result)")
        }
    }

    await test("unresolved child or intent skips memory even when a parent key is warm") {
        let cache = SkillCache()
        let key = "alpha|p=executor|meta=warm"
        await cache.set(key, content: .object(["content": .string("child-body")]))
        let gate = SkillRuntimeExposureGate(generation: fetchGeneration())
        let result = await SkillsModule.fetchMemoryResult(
            enabled: true, pageId: fetchPageA, cacheKey: key,
            cache: cache, gate: gate, skipMemoryCache: true
        )
        guard case .miss = result else {
            throw TestError.assertion("unresolved selector must not serve memory, got \(result)")
        }
    }

    await test("SkillCache.clear drops seeded entries") {
        let cache = SkillCache()
        await cache.set("k", content: .string("v"))
        await cache.clear()
        try expect(await cache.get("k") == nil, "clear must drop entries")
    }
}
