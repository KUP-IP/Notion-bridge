// RoutingReliabilityTests.swift — routing-reliability wave.
//
// Coverage for the routing-reliability fixes:
//   • SpecialistFilter — doc-page exclusion (changelogs / PRDs / §-sections /
//     test matrices / evolution logs / phase / pruning / duplicate stubs)
//     vs curated specialist titles.
//   • SkillIntentScorer.decide — confident / disambiguate / none classification
//     (the confidence → clarify path).
//   • ClientOverlayStore get/set + composition(clientName:) overlay append.
//   • SkillsModule.routingFooter — sibling-specialist footer shape + nil cases.
//   • DeliveryLog.skillFetched event ingest + skillFetchFields parsing.
//
// All pure / hermetic: SpecialistFilter + scorer are pure; the overlay +
// composition tests run under a per-test tmp HOME via withRoutingTempHome;
// the DeliveryLog tests use an injected hash + resetForTesting (no file I/O).

import Foundation
import MCP
import TheBridgeLib

func runRoutingReliabilityTests() async {
    print("\n\u{1F9ED} Routing Reliability Tests")

    // MARK: - SpecialistFilter: doc-page exclusion

    await test("Filter: doc-page titles are excluded from specialists") {
        // The audit's doc-page noise must all be filtered out.
        let docPages = [
            "§ 3.2 Architecture",
            "Changelog",
            "v3.7 Change Log",
            "PRD",
            "PRD — Routing v2",
            "Test Matrix",
            "Evolution Log",
            "Phase 1",
            "Phase 2.5 Planning",
            "Pruning Notes",
            "Decision Log",
            "Roadmap",
            "Backlog",
            "Archive (old specialists)",
            "Update (duplicate)",
            "Triage (stub)"
        ]
        for t in docPages {
            try expect(SpecialistFilter.isDocPage(title: t), "expected doc-page: '\(t)'")
            try expect(!SpecialistFilter.isSpecialist(title: t), "doc-page must not be a specialist: '\(t)'")
        }
    }

    await test("Filter: curated specialist titles are kept") {
        let specialists = ["update", "triage", "close", "enrich", "Dedupe Contacts", "session reflow"]
        for t in specialists {
            try expect(SpecialistFilter.isSpecialist(title: t), "expected specialist: '\(t)'")
            try expect(!SpecialistFilter.isDocPage(title: t), "specialist must not be a doc-page: '\(t)'")
        }
    }

    await test("Filter: empty / whitespace title is not a specialist") {
        try expect(SpecialistFilter.isDocPage(title: ""))
        try expect(SpecialistFilter.isDocPage(title: "   "))
        try expect(!SpecialistFilter.isSpecialist(title: ""))
    }

    await test("Filter: 'rephrase' / 'phased' do NOT trip the Phase pattern") {
        // The Phase pattern requires a word boundary + digit, so prose words
        // containing 'phase' must remain specialists.
        try expect(SpecialistFilter.isSpecialist(title: "rephrase the message"))
        try expect(SpecialistFilter.isSpecialist(title: "phased rollout helper"))
        // But a real "Phase 3" page is excluded.
        try expect(SpecialistFilter.isDocPage(title: "Phase 3"))
    }

    // MARK: - SkillIntentScorer.decide (confidence → clarify)

    await test("Decide: clear winner → .confident") {
        let cands = [
            SkillIntentCandidate(name: "update"),
            SkillIntentCandidate(name: "archive-old-projects")
        ]
        let d = SkillIntentScorer.decide(intent: "update", candidates: cands)
        guard case .confident(let s) = d else {
            throw TestError.assertion("expected .confident, got \(d)")
        }
        try expect(s.candidate.name == "update")
        try expect(s.score >= SkillIntentScorer.confidenceThreshold)
    }

    await test("Decide: two near-tied candidates → .disambiguate") {
        // Both are exact-ish matches to overlapping intent tokens, landing in
        // the keyword-overlap band within the disambiguation margin.
        let cands = [
            SkillIntentCandidate(name: "triage stale projects", summary: "triage stale projects"),
            SkillIntentCandidate(name: "triage stale contacts", summary: "triage stale contacts")
        ]
        let d = SkillIntentScorer.decide(intent: "triage stale", candidates: cands)
        guard case .disambiguate(let close) = d else {
            throw TestError.assertion("expected .disambiguate, got \(d)")
        }
        try expect(close.count >= 2, "disambiguation must surface the close candidates")
    }

    await test("Decide: near-tied keyword-overlap candidates → .disambiguate") {
        // Two candidates that both land on the SAME keyword-overlap score
        // (one shared token each) are within the disambiguation margin → the
        // dispatcher must clarify rather than arbitrarily picking one.
        let cands = [
            SkillIntentCandidate(name: "alpha", summary: "handles widgets"),
            SkillIntentCandidate(name: "beta", summary: "handles widgets")
        ]
        let d = SkillIntentScorer.decide(intent: "widgets task", candidates: cands)
        guard case .disambiguate(let close) = d else {
            throw TestError.assertion("equal-scoring candidates must clarify, got \(d)")
        }
        try expect(close.count == 2, "both tied candidates are surfaced")
        try expect(close.allSatisfy { $0.score > 0 }, "surfaced candidates carry a score")
    }

    await test("Decide: no scoring candidate → .none") {
        let cands = [SkillIntentCandidate(name: "update"), SkillIntentCandidate(name: "triage")]
        let d = SkillIntentScorer.decide(intent: "zzqqxx nonsense token", candidates: cands)
        guard case .none = d else {
            throw TestError.assertion("expected .none for a no-signal intent, got \(d)")
        }
    }

    // MARK: - Archive-vs-canonical matcher-confidence fix (2026-07-03)
    //
    // Live-reproduced bug: fetch_skill(name: "close-agent") resolved to a
    // nested "sk close agent · Archive" child page (an "Archived reference
    // material" container's descendant) at matchConfidence 0.4 / "keyword
    // overlap", instead of the canonical live page
    // (6673dba8-26b1-4b1d-aa0a-6aad084a861c). Root cause: SpecialistFilter.
    // isDocPage only excludes an archive *container* whose title STARTS WITH
    // "archive" — it never catches a live-looking child title that merely
    // CARRIES an archive marker as a suffix ("sk close agent · Archive"), so
    // that title reached SkillIntentScorer as an ordinary candidate and won
    // on raw keyword overlap because the canonical page's title didn't happen
    // to share as many tokens with the intent string.
    //
    // General fix: SpecialistFilter.isArchived(title:) is a broader, word-
    // boundary "archive"/"archived" detector (catches prefix, suffix, and
    // delimited placements) that SkillIntentScorer.rank uses to DEPRIORITIZE
    // — never unconditionally exclude — an archived candidate relative to a
    // non-archived sibling that scored equal-or-better. This is a relative,
    // general rule (keyed off the title predicate, not any hardcoded id or
    // skill name), so an archived page with no live sibling in the candidate
    // set still resolves normally (fail-open).

    await test("Archive: isArchived matches prefix, suffix, and delimited placements") {
        try expect(SpecialistFilter.isArchived(title: "sk close agent · Archive"),
                   "suffix marker (the real close-agent collision title) must be detected")
        try expect(SpecialistFilter.isArchived(title: "Archive (old specialists)"),
                   "prefix marker still detected")
        try expect(SpecialistFilter.isArchived(title: "Archived reference material"),
                   "the container page's own title (word 'Archived') is detected")
        try expect(SpecialistFilter.isArchived(title: "close-agent (Archived)"),
                   "parenthesized suffix marker detected")
        try expect(SpecialistFilter.isArchived(title: "Archive: close agent"),
                   "delimited-segment prefix marker detected")
    }

    await test("Archive: isArchived does NOT false-positive on titles merely containing the letters") {
        try expect(!SpecialistFilter.isArchived(title: "close-agent"),
                   "the canonical live title carries no archive marker")
        try expect(!SpecialistFilter.isArchived(title: "update"))
        try expect(!SpecialistFilter.isArchived(title: ""))
    }

    await test("Archive-vs-canonical: real close-agent collision — canonical wins over the archived sibling") {
        // The exact fixture from the live repro: a canonical "close-agent"
        // specialist competing against the archived nested child "sk close
        // agent · Archive" for the same intent. Before the fix, the archived
        // title's higher raw keyword-overlap score (it happens to share more
        // tokens with the intent) would have won .confident outright.
        let canonical = SkillIntentCandidate(
            name: "close-agent",
            summary: "Close out an active agent session cleanly."
        )
        let archived = SkillIntentCandidate(
            name: "sk close agent · Archive",
            summary: "Archived reference material for the retired close agent session flow."
        )
        let candidates = [canonical, archived]

        // Intent matches the canonical title EXACTLY (score 1.0) while the
        // archived title only shares keyword-overlap tokens — a clean,
        // unambiguous win margin, so this isolates the archive-vs-canonical
        // rule from the separate near-tie disambiguation-band behaviour
        // (covered by its own tests below).
        let ranked = SkillIntentScorer.rank(intent: "close-agent", candidates: candidates)
        try expect(ranked.first?.candidate.name == "close-agent",
                   "canonical must rank first, got \(ranked.map { ($0.candidate.name, $0.score) })")

        let decision = SkillIntentScorer.decide(intent: "close-agent", candidates: candidates)
        guard case .confident(let winner) = decision else {
            throw TestError.assertion("expected a confident resolution to the canonical page, got \(decision)")
        }
        try expect(winner.candidate.name == "close-agent",
                   "fetch_skill must resolve to the canonical live page, not the archive child")
        try expect(!SpecialistFilter.isArchived(title: winner.candidate.name),
                   "the winning candidate must never be an archive-marked title when a canonical one exists")
    }

    await test("Archive-vs-canonical: near-tied raw scores still resolve to the canonical, not a disambiguate stall") {
        // A tighter case than the exact-title fixture above: the intent
        // gives both candidates comparable RAW keyword-overlap scores (the
        // archived title happens to repeat more shared tokens). Pre-fix,
        // this is precisely the live repro shape — a close, non-exact
        // intent where the archived child's raw score could equal or beat
        // the canonical's. The deprioritization must still land the
        // dispatcher on a resolvable, non-archived outcome — either a
        // confident canonical win, or (if genuinely still close after the
        // archive penalty) a disambiguate band that does NOT consist solely
        // of the archived candidate.
        let canonical = SkillIntentCandidate(
            name: "close-agent",
            summary: "close agent session triage close out"
        )
        let archived = SkillIntentCandidate(
            name: "sk close agent · Archive",
            summary: "close agent session triage close out archived history"
        )
        let decision = SkillIntentScorer.decide(intent: "close agent session triage", candidates: [canonical, archived])
        switch decision {
        case .confident(let winner):
            try expect(winner.candidate.name == "close-agent",
                       "a confident decision must be the canonical page, not the archive child")
        case .disambiguate(let close):
            try expect(close.contains(where: { $0.candidate.name == "close-agent" }),
                       "the canonical page must be offered in any disambiguation band, got \(close.map(\.candidate.name))")
        case .none:
            throw TestError.assertion("expected a resolvable decision, got .none")
        }
    }

    await test("Archive-vs-canonical: archived candidate still resolves when it is the ONLY candidate (fail-open)") {
        // No canonical alternative exists in this candidate set — the
        // deprioritization rule is relative, so an archived-only match must
        // still be usable rather than being silently hidden.
        let onlyArchived = [
            SkillIntentCandidate(name: "sk close agent · Archive",
                                  summary: "Archived reference material for the retired close agent flow.")
        ]
        let best = SkillIntentScorer.bestMatch(intent: "close agent", candidates: onlyArchived)
        try expect(best?.candidate.name == "sk close agent · Archive",
                   "an archived page with no live sibling must still resolve on its own merits")
    }

    await test("Archive-vs-canonical: archived candidate never wins even with a HIGHER raw keyword score") {
        // Construct the raw scores so the archived title would win on pure
        // keyword overlap alone (more shared tokens with the intent) — the
        // deprioritization must still hand the win to the non-archived
        // candidate that clears the confidence bar.
        let canonical = SkillIntentCandidate(name: "close-agent", summary: "close agent")
        let archived = SkillIntentCandidate(
            name: "close agent workflow notes · Archive",
            summary: "close agent workflow notes archive old session close agent"
        )
        let decision = SkillIntentScorer.decide(intent: "close agent workflow notes", candidates: [canonical, archived])
        switch decision {
        case .confident(let winner):
            try expect(!SpecialistFilter.isArchived(title: winner.candidate.name),
                       "a confident resolution must never be the archived title")
        case .disambiguate(let close):
            try expect(close.allSatisfy { !SpecialistFilter.isArchived(title: $0.candidate.name) } || close.count > 1,
                       "if disambiguating, the archived-only outcome is not acceptable on its own")
        case .none:
            throw TestError.assertion("expected a resolvable decision, got .none")
        }
    }

    // MARK: - Regression: multi-specialist disambiguation is UNCHANGED
    // (the focus-keepr-style case — genuinely live candidates, NOT an
    // archive collision — must still correctly disambiguate rather than
    // being conflated with the archive-deprioritization rule above).

    await test("Regression: focus-keepr-style multi-specialist disambiguation still works (no archive markers)") {
        // Mirrors the live fetch_skill('focus-keepr') behaviour: two
        // genuinely live specialist children under one parent, both
        // plausible for an ambiguous intent — must still ask the caller to
        // pick rather than silently resolving to one.
        let closeAgent = SkillIntentCandidate(
            name: "close-agent",
            summary: "Close out an active agent session cleanly."
        )
        let projectsPlanning = SkillIntentCandidate(
            name: "projects planning",
            summary: "Plan and triage active projects."
        )
        let candidates = [closeAgent, projectsPlanning]

        // Neither candidate carries an archive marker — the archive rule
        // must be a complete no-op here.
        try expect(candidates.allSatisfy { !SpecialistFilter.isArchived(title: $0.name) })

        // An intent that shares a token with BOTH titles' summaries lands
        // both in the same keyword-overlap band → disambiguate.
        let decision = SkillIntentScorer.decide(intent: "session projects", candidates: candidates)
        guard case .disambiguate(let close) = decision else {
            throw TestError.assertion("expected .disambiguate across genuinely live specialists, got \(decision)")
        }
        try expect(close.count == 2, "both live candidates must be surfaced, got \(close.map(\.candidate.name))")
        let names = Set(close.map { $0.candidate.name })
        try expect(names == Set(["close-agent", "projects planning"]),
                   "disambiguation must name both genuinely live candidates: \(names)")
    }

    await test("Regression: disambiguation between two non-archived candidates is untouched by the archive rule") {
        // Direct before/after comparison: scoring the exact same two
        // non-archived candidates with and without the archive-aware rank
        // logic must be byte-identical, since nonArchivedScores.max() over
        // an all-non-archived set never mutates any entry (every candidate
        // IS the "best non-archived" comparison baseline for itself).
        let cands = [
            SkillIntentCandidate(name: "triage stale projects", summary: "triage stale projects"),
            SkillIntentCandidate(name: "triage stale contacts", summary: "triage stale contacts")
        ]
        let ranked = SkillIntentScorer.rank(intent: "triage stale", candidates: cands)
        try expect(ranked.count == 2)
        try expect(ranked[0].score == ranked[1].score,
                   "tied non-archived candidates must remain exactly tied")
        let d = SkillIntentScorer.decide(intent: "triage stale", candidates: cands)
        guard case .disambiguate(let close) = d else {
            throw TestError.assertion("expected .disambiguate, got \(d)")
        }
        try expect(close.count == 2)
    }

    // MARK: - ClientOverlayStore + composition(clientName:)

    await test("Overlay: get/set round-trip is case-insensitive on client name") {
        try await withRoutingTempHome { _ in
            ClientOverlayStore.shared.resetForTesting()
            try expect(ClientOverlayStore.shared.overlay(forClient: "Claude Code") == nil,
                       "no overlay by default")
            ClientOverlayStore.shared.setOverlay("# Extra\n\nbe extra terse", forClient: "Claude Code")
            // Case-insensitive read.
            try expect(ClientOverlayStore.shared.overlay(forClient: "claude code") == "# Extra\n\nbe extra terse")
            // Clearing reverts to nil.
            ClientOverlayStore.shared.setOverlay(nil, forClient: "CLAUDE CODE")
            try expect(ClientOverlayStore.shared.overlay(forClient: "Claude Code") == nil,
                       "nil overlay clears the entry")
        }
    }

    await test("Overlay: empty default → composition byte-identical to no-client") {
        try await withRoutingTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            ClientOverlayStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\nuniform")
            let base = StandingOrdersDelivery.composition(clientName: nil)
            let named = StandingOrdersDelivery.composition(clientName: "claude-code")
            try expect(base == named, "no overlay set → identical content for nil and named client")
        }
    }

    await test("Overlay: composition appends the overlay for the named client") {
        try await withRoutingTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            ClientOverlayStore.shared.resetForTesting()
            // Reset the process-global overlay store on the way out too, so
            // this entry can never contaminate a sibling delivery test that
            // composes for a same-named client (UserDefaults is not scoped by
            // the temp HOME override).
            defer { ClientOverlayStore.shared.resetForTesting() }
            _ = try StandingOrdersStore.shared.write("# Orders\n\nbase orders")
            ClientOverlayStore.shared.setOverlay("CLIENT-SPECIFIC NOTE", forClient: "claude-code")

            let other = StandingOrdersDelivery.composition(clientName: "some-other-client")
            try expect(!other.instructionsMarkdown.contains("CLIENT-SPECIFIC NOTE"),
                       "a different client must not see the overlay")

            let named = StandingOrdersDelivery.composition(clientName: "claude-code")
            try expect(named.instructionsMarkdown.contains("CLIENT-SPECIFIC NOTE"),
                       "the named client's instructions must include the overlay")
            try expect(named.instructionsMarkdown.hasSuffix("CLIENT-SPECIFIC NOTE"),
                       "overlay is appended at the tail")
            // The overlay changes content → the content hash diverges.
            try expect(named.contentHash != other.contentHash,
                       "overlay must change the content hash")
        }
    }

    // MARK: - Routing footer (item 3)

    await test("Footer: names sibling specialists and the re-route instruction") {
        let footer = SkillsModule.routingFooterForTesting(
            parentName: "project-keepr",
            currentSpecialistTitle: "update",
            siblingTitles: ["update", "triage", "close"]
        )
        try expect(footer != nil, "footer must be present when siblings exist")
        let f = footer ?? ""
        try expect(f.contains("project-keepr/triage"), "footer names a sibling by path")
        try expect(f.contains("project-keepr/close"), "footer names a sibling by path")
        try expect(!f.contains("project-keepr/update"), "the current specialist is excluded from the siblings")
        try expect(f.contains("fetch_skill('project-keepr', intent:"), "footer carries the re-route instruction")
    }

    await test("Footer: nil when there are no other specialists") {
        // Single specialist that IS the current one → no siblings → no footer.
        try expect(SkillsModule.routingFooterForTesting(
            parentName: "p", currentSpecialistTitle: "only", siblingTitles: ["only"]) == nil)
        // Empty sibling list → no footer.
        try expect(SkillsModule.routingFooterForTesting(
            parentName: "p", currentSpecialistTitle: nil, siblingTitles: []) == nil)
    }

    await test("Footer: parent-body case (no current specialist) lists all siblings") {
        let footer = SkillsModule.routingFooterForTesting(
            parentName: "people-keepr",
            currentSpecialistTitle: nil,
            siblingTitles: ["brief", "enrich"]
        )
        let f = footer ?? ""
        try expect(f.contains("people-keepr/brief"))
        try expect(f.contains("people-keepr/enrich"))
    }

    // MARK: - DeliveryLog.skillFetched (item 5)

    await test("DeliveryLog: skillFetched event ingests with skill + intent") {
        await MainActor.run {
            DeliveryLog.shared.resetForTesting()
            DeliveryLog.shared.recordSkillFetched(
                sessionID: "sess-1", clientName: "claude-code",
                skill: "project-keepr/update", intent: "triage stale projects"
            )
        }
        // The record* hop is an unawaited Task { @MainActor } — give it a turn.
        try await Task.sleep(nanoseconds: 50_000_000)
        let events = await MainActor.run { DeliveryLog.shared.timeline(limit: 10) }
        guard let e = events.first(where: { $0.kind == .skillFetched }) else {
            throw TestError.assertion("expected a skillFetched event in the timeline")
        }
        try expect(e.uri == "project-keepr/update", "skill name/path stored under uri")
        try expect(e.intent == "triage stale projects", "intent stored on the event")
        try expect(e.sessionID == "sess-1")
    }

    await test("DeliveryLog: skillFetchFields parses name + trimmed intent") {
        let (skill, intent) = DeliveryLog.skillFetchFields(from: .object([
            "name": .string("project-keepr"),
            "intent": .string("  triage stale projects  ")
        ]))
        try expect(skill == "project-keepr")
        try expect(intent == "triage stale projects", "intent must be trimmed")

        // Missing intent → nil; blank intent → nil; non-object → empty.
        let (s2, i2) = DeliveryLog.skillFetchFields(from: .object(["name": .string("p")]))
        try expect(s2 == "p" && i2 == nil)
        let (s3, i3) = DeliveryLog.skillFetchFields(from: .object(["name": .string("p"), "intent": .string("   ")]))
        try expect(s3 == "p" && i3 == nil, "whitespace-only intent → nil")
        let (s4, i4) = DeliveryLog.skillFetchFields(from: nil)
        try expect(s4 == "" && i4 == nil)
    }
}

// MARK: - Test fixture helpers (local, not exported)

private func withRoutingTempHome(_ body: (URL) async throws -> Void) async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("RoutingReliability-test-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? fm.removeItem(at: tmp)
    }
    try await body(tmp)
}
