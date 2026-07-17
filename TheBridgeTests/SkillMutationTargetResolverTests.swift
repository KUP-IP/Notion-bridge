// SkillMutationTargetResolverTests.swift — parent/specialist mutation identity

import Foundation
import TheBridgeLib

func runSkillMutationTargetResolverTests() async {
    print("\n\u{1F9ED} SkillMutationTargetResolver")

    let configured = [
        SkillMutationConfiguredSkill(
            name: "TIME Keepr",
            pageId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )
    ]
    let cached = [
        CachedParent(
            writtenAt: Date(), ttlHours: 24,
            parentId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            parentTitle: "time-keepr",
            children: [
                CachedSpecialist(
                    id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                    title: "events-admin",
                    summary: "sync specialist",
                    aliases: ["calendar-registry-sync"]
                )
            ]
        )
    ]

    await test("configured parent resolves by normalized name") {
        let result = SkillMutationTargetResolver.resolve(
            "time-keepr", configured: configured, cachedParents: cached
        )
        guard case .found(let target) = result else {
            throw TestError.assertion("expected configured parent, got \(result)")
        }
        try expect(target.kind == .configuredParent)
        try expect(target.pageId == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    }

    await test("specialist resolves by explicit parent/child path") {
        let result = SkillMutationTargetResolver.resolve(
            "TIME Keepr/events-admin", configured: configured, cachedParents: cached
        )
        guard case .found(let target) = result else {
            throw TestError.assertion("expected specialist, got \(result)")
        }
        try expect(target.kind == .cachedSpecialist)
        try expect(target.pageId == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        try expect(target.parentPageId == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    }

    await test("specialist alias resolves without widening beyond routing cache") {
        let result = SkillMutationTargetResolver.resolve(
            "calendar registry sync", configured: configured, cachedParents: cached
        )
        guard case .found(let target) = result else {
            throw TestError.assertion("expected alias hit, got \(result)")
        }
        try expect(target.name == "events-admin")
    }

    await test("duplicate specialist titles are reported as ambiguous") {
        let duplicate = CachedParent(
            writtenAt: Date(), ttlHours: 24,
            parentId: "cccccccccccccccccccccccccccccccc",
            parentTitle: "other-keepr",
            children: [
                CachedSpecialist(
                    id: "dddddddddddddddddddddddddddddddd",
                    title: "events-admin"
                )
            ]
        )
        let result = SkillMutationTargetResolver.resolve(
            "events-admin", configured: configured, cachedParents: cached + [duplicate]
        )
        guard case .ambiguous(let candidates) = result else {
            throw TestError.assertion("expected ambiguity, got \(result)")
        }
        try expect(candidates.count == 2)
    }
}
