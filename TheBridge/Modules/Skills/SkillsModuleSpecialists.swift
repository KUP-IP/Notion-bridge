// Extracted from SkillsModule.swift by PKT-1126. Pure decomposition; behavior unchanged.

import Foundation
import MCP

extension SkillsModule {
    // MARK: - PKT-907 (Bridge v3.6 · 10) fetch_skill orchestrator helpers

    /// Resolution outcome from the path/intent dispatcher. Either we
    /// swapped in a specialist (live page identity) or we are returning
    /// the parent body with an annotation. `score` / `reason` only
    /// populate when intent ranking ran.
    /// `@unchecked Sendable`: the inner `[String: Any]` is a read-only
    /// snapshot of the Notion `getPage` response. Created inside one
    /// async task and consumed in the same task — never mutated, never
    /// shared. The unchecked annotation suppresses the conservative
    /// strict-concurrency diagnostic without weakening the actual safety
    /// (no aliased mutable state is ever shared across actors).
    struct SpecialistDispatch: @unchecked Sendable {
        struct ResolvedNotion {
            let title: String
            let url: String
            let pageId: String
            let properties: [String: Any]
            let lastEditedTime: String
        }
        let resolvedSpecialist: ResolvedNotion?
        let resolvedPath: String?
        let annotation: SkillAnnotation?
        let matchScore: Double?
        let matchReason: String?
        /// Routing-reliability (confidence → clarify): when the annotation
        /// is `.disambiguate`, the close candidates the agent should pick
        /// between (path + title + score + reason). Empty otherwise.
        var disambiguationCandidates: [DispatchCandidate] = []
        /// Routing-footer: every specialist title under this parent (the
        /// curated, doc-page-filtered set) so the envelope footer can name
        /// the siblings and how to re-route to them. Empty for the
        /// bare-parent fast path (no enumeration was done).
        var siblingTitles: [String] = []
    }

    /// One candidate row for a disambiguation surface.
    struct DispatchCandidate: Sendable, Equatable {
        let title: String
        let path: String
        let score: Double
        let reason: String
    }

    /// PKT-907 W1: file-source path/intent dispatch.
    /// Returns the full envelope for either the resolved child or the
    /// parent body with an annotation injected.
    static func dispatchFileSpecialist(
        parent: ParsedSkill,
        parsedPath: SkillPath,
        intent: String?
    ) async -> Value {
        let parentName = parent.name

        // Routing-reliability: enumerate the curated specialist titles once
        // up front so every return path can carry the sibling footer. The
        // file resolver already lists only `specialists/` files + curated
        // frontmatter entries (no doc-page leakage on the file source).
        let allSpecialists = SkillSpecialistFileResolver.listAll(parent: parent)
        let siblingTitles = allSpecialists.map { $0.name }

        // Depth guard wins over everything else.
        if parsedPath.depthExceeded {
            let parentEnvelope = await Self.buildFileSkillResult(parent)
            return Self.annotateFileEnvelope(
                parentEnvelope,
                parentName: parentName,
                annotation: .depthGuard,
                resolvedPath: nil,
                score: nil,
                reason: nil,
                siblingTitles: siblingTitles
            )
        }

        // Path lookup.
        if let child = parsedPath.child {
            if let resolved = SkillSpecialistFileResolver.resolve(parent: parent, child: child) {
                let pseudo = ParsedSkill(
                    name: resolved.name,
                    path: resolved.path,
                    isUserSource: parent.isUserSource,
                    frontmatter: resolved.frontmatter,
                    body: resolved.body,
                    displayPath: parent.displayPath + "/specialists/\(resolved.name)"
                )
                let env = await Self.buildFileSkillResult(pseudo)
                return Self.annotateFileEnvelope(
                    env,
                    parentName: parentName,
                    annotation: nil,
                    resolvedPath: "\(parentName)/\(resolved.name)",
                    score: 1.0,
                    reason: "exact path",
                    currentSpecialistTitle: resolved.name,
                    siblingTitles: siblingTitles
                )
            }
            // Path looked valid but no such child file → parent + annotation.
            let parentEnvelope = await Self.buildFileSkillResult(parent)
            return Self.annotateFileEnvelope(
                parentEnvelope,
                parentName: parentName,
                annotation: .specialistNotFound,
                resolvedPath: nil,
                score: nil,
                reason: nil,
                siblingTitles: siblingTitles
            )
        }

        // Intent ranking → confident / disambiguate / none.
        if let intent = intent {
            // An exact canonical parent with no specialist roster is already
            // resolved. Intent cannot route anywhere, so do not mislabel the
            // authoritative parent body as low-confidence.
            if allSpecialists.isEmpty {
                let parentEnvelope = await Self.buildFileSkillResult(parent)
                return Self.annotateFileEnvelope(
                    parentEnvelope,
                    parentName: parentName,
                    annotation: nil,
                    resolvedPath: nil,
                    score: 1.0,
                    reason: "exact canonical name; no specialists configured",
                    siblingTitles: []
                )
            }
            let candidates: [SkillIntentCandidate] = allSpecialists.map { s in
                var aliases: [String] = []
                if case .array(let arr) = s.frontmatter["aliases"] { aliases = arr }
                let summary: String = {
                    if case .string(let d) = s.frontmatter["description"] { return d }
                    return SpecialistSummaryExtractor.firstSentence(from: s.body)
                }()
                return SkillIntentCandidate(name: s.name, aliases: aliases, summary: summary)
            }
            switch SkillIntentScorer.decide(intent: intent, candidates: candidates) {
            case .confident(let best):
                if let resolved = allSpecialists.first(where: { $0.name.lowercased() == best.candidate.name.lowercased() }) {
                    let pseudo = ParsedSkill(
                        name: resolved.name,
                        path: resolved.path,
                        isUserSource: parent.isUserSource,
                        frontmatter: resolved.frontmatter,
                        body: resolved.body,
                        displayPath: parent.displayPath + "/specialists/\(resolved.name)"
                    )
                    let env = await Self.buildFileSkillResult(pseudo)
                    NSLog("[fetch_skill] intent=\"%@\" parent=%@ → %@/%@ score=%.2f (%@)",
                          intent, parentName, parentName, resolved.name, best.score, best.reason)
                    return Self.annotateFileEnvelope(
                        env,
                        parentName: parentName,
                        annotation: nil,
                        resolvedPath: "\(parentName)/\(resolved.name)",
                        score: best.score,
                        reason: best.reason,
                        currentSpecialistTitle: resolved.name,
                        siblingTitles: siblingTitles
                    )
                }
                // Defensive fall-through (classified but didn't re-resolve).
                let parentEnvelope = await Self.buildFileSkillResult(parent)
                return Self.annotateFileEnvelope(
                    parentEnvelope, parentName: parentName, annotation: .lowConfidence,
                    resolvedPath: nil, score: best.score, reason: best.reason,
                    siblingTitles: siblingTitles
                )
            case .disambiguate(let close):
                NSLog("[fetch_skill] intent=\"%@\" parent=%@ → disambiguate (%d candidates, top=%.2f)",
                      intent, parentName, close.count, close.first?.score ?? 0)
                let parentEnvelope = await Self.buildFileSkillResult(parent)
                let cands = close.map {
                    DispatchCandidate(title: $0.candidate.name,
                                      path: "\(parentName)/\($0.candidate.name)",
                                      score: $0.score, reason: $0.reason)
                }
                return Self.annotateFileEnvelope(
                    parentEnvelope,
                    parentName: parentName,
                    annotation: .disambiguate,
                    resolvedPath: nil,
                    score: close.first?.score,
                    reason: close.first?.reason,
                    candidates: cands,
                    siblingTitles: siblingTitles
                )
            case .none:
                NSLog("[fetch_skill] intent=\"%@\" parent=%@ → no candidate scored",
                      intent, parentName)
                let parentEnvelope = await Self.buildFileSkillResult(parent)
                return Self.annotateFileEnvelope(
                    parentEnvelope,
                    parentName: parentName,
                    annotation: .lowConfidence,
                    resolvedPath: nil,
                    score: nil,
                    reason: nil,
                    siblingTitles: siblingTitles
                )
            }
        }

        // Bare parent name — pre-PKT-907 path. Still attach a footer so the
        // agent sees the routable specialists from the parent body.
        let parentEnvelope = await Self.buildFileSkillResult(parent)
        return Self.annotateFileEnvelope(
            parentEnvelope,
            parentName: parentName,
            annotation: nil,
            resolvedPath: nil,
            score: nil,
            reason: nil,
            siblingTitles: siblingTitles
        )
    }

    /// PKT-907 W1+W2: Notion-source path/intent dispatch. Returns a
    /// `SpecialistDispatch` for the caller to splice into the envelope
    /// build (we do this outside so the existing /markdown fetch path
    /// stays the single network choke-point).
    static func dispatchNotionSpecialist(
        client: NotionClient,
        parentPageId: String,
        parentName: String,
        parsedPath: SkillPath,
        intent: String?
    ) async -> SpecialistDispatch {
        // Depth guard short-circuits before any network call.
        if parsedPath.depthExceeded {
            return SpecialistDispatch(
                resolvedSpecialist: nil,
                resolvedPath: nil,
                annotation: .depthGuard,
                matchScore: nil,
                matchReason: nil
            )
        }

        // Bare-parent fast path — no extra network calls.
        if parsedPath.child == nil && intent == nil {
            return SpecialistDispatch(
                resolvedSpecialist: nil,
                resolvedPath: nil,
                annotation: nil,
                matchScore: nil,
                matchReason: nil
            )
        }

        // Enumerate the parent's curated specialists. listNotionChildPages
        // reads the parent's `Specialist` relation property as the primary
        // source (falling back to a child_page walk only when the relation
        // is absent), and applies SpecialistFilter as a defensive guard, so
        // `childPages` already holds only curated specialists.
        let childPages = await Self.listNotionChildPages(client: client, pageId: parentPageId)
        let siblingTitles = childPages.map { $0.title }

        // Intent on an exact canonical parent that has no curated specialists
        // is a definitive parent fetch, not a routing failure.
        if parsedPath.child == nil, intent != nil, childPages.isEmpty {
            return SpecialistDispatch(
                resolvedSpecialist: nil,
                resolvedPath: nil,
                annotation: nil,
                matchScore: 1.0,
                matchReason: "exact canonical name; no specialists configured",
                siblingTitles: []
            )
        }

        if let childName = parsedPath.child {
            let needle = childName.lowercased()
            // Exact (case-insensitive), then partial substring (first
            // match wins per packet) match on child page titles.
            if let exact = childPages.first(where: { $0.title.lowercased() == needle }) {
                return SpecialistDispatch(
                    resolvedSpecialist: SpecialistDispatch.ResolvedNotion(
                        title: exact.title,
                        url: exact.url,
                        pageId: exact.pageId,
                        properties: exact.properties,
                        lastEditedTime: exact.lastEditedTime
                    ),
                    resolvedPath: "\(parentName)/\(exact.title)",
                    annotation: nil,
                    matchScore: 1.0,
                    matchReason: "exact path",
                    siblingTitles: siblingTitles
                )
            }
            if let partial = childPages.first(where: { $0.title.lowercased().contains(needle) || needle.contains($0.title.lowercased()) }) {
                return SpecialistDispatch(
                    resolvedSpecialist: SpecialistDispatch.ResolvedNotion(
                        title: partial.title,
                        url: partial.url,
                        pageId: partial.pageId,
                        properties: partial.properties,
                        lastEditedTime: partial.lastEditedTime
                    ),
                    resolvedPath: "\(parentName)/\(partial.title)",
                    annotation: nil,
                    matchScore: 0.7,
                    matchReason: "partial title",
                    siblingTitles: siblingTitles
                )
            }
            // Unresolvable child → parent + annotation.
            return SpecialistDispatch(
                resolvedSpecialist: nil,
                resolvedPath: nil,
                annotation: .specialistNotFound,
                matchScore: nil,
                matchReason: nil,
                siblingTitles: siblingTitles
            )
        }

        // Intent path — score against child page titles, then classify into
        // confident / disambiguate / none (routing-reliability item 4).
        if let intent = intent {
            let candidates = childPages.map { cp in
                SkillIntentCandidate(name: cp.title, aliases: [], summary: "")
            }
            switch SkillIntentScorer.decide(intent: intent, candidates: candidates) {
            case .confident(let best):
                if let resolved = childPages.first(where: { $0.title.lowercased() == best.candidate.name.lowercased() }) {
                    NSLog("[fetch_skill] intent=\"%@\" parent=%@ → %@/%@ score=%.2f (%@)",
                          intent, parentName, parentName, resolved.title, best.score, best.reason)
                    return SpecialistDispatch(
                        resolvedSpecialist: SpecialistDispatch.ResolvedNotion(
                            title: resolved.title,
                            url: resolved.url,
                            pageId: resolved.pageId,
                            properties: resolved.properties,
                            lastEditedTime: resolved.lastEditedTime
                        ),
                        resolvedPath: "\(parentName)/\(resolved.title)",
                        annotation: nil,
                        matchScore: best.score,
                        matchReason: best.reason,
                        siblingTitles: siblingTitles
                    )
                }
                // Defensive: classified confident but title didn't re-resolve.
                return SpecialistDispatch(
                    resolvedSpecialist: nil, resolvedPath: nil,
                    annotation: .lowConfidence, matchScore: best.score,
                    matchReason: best.reason, siblingTitles: siblingTitles
                )
            case .disambiguate(let close):
                NSLog("[fetch_skill] intent=\"%@\" parent=%@ → disambiguate (%d candidates, top=%.2f)",
                      intent, parentName, close.count, close.first?.score ?? 0)
                let cands = close.map {
                    DispatchCandidate(title: $0.candidate.name,
                                      path: "\(parentName)/\($0.candidate.name)",
                                      score: $0.score, reason: $0.reason)
                }
                return SpecialistDispatch(
                    resolvedSpecialist: nil,
                    resolvedPath: nil,
                    annotation: .disambiguate,
                    matchScore: close.first?.score,
                    matchReason: close.first?.reason,
                    disambiguationCandidates: cands,
                    siblingTitles: siblingTitles
                )
            case .none:
                NSLog("[fetch_skill] intent=\"%@\" parent=%@ → no candidate scored",
                      intent, parentName)
                return SpecialistDispatch(
                    resolvedSpecialist: nil,
                    resolvedPath: nil,
                    annotation: .lowConfidence,
                    matchScore: nil,
                    matchReason: nil,
                    siblingTitles: siblingTitles
                )
            }
        }

        // Should not reach (early-exited above when both nil).
        return SpecialistDispatch(
            resolvedSpecialist: nil,
            resolvedPath: nil,
            annotation: nil,
            matchScore: nil,
            matchReason: nil,
            siblingTitles: siblingTitles
        )
    }

    /// Inner record carrying just what `dispatchNotionSpecialist` needs.
    /// `@unchecked Sendable`: see `SpecialistDispatch` doc above —
    /// same read-only-snapshot-inside-one-task contract applies.
    struct NotionChildPageRef: @unchecked Sendable {
        let pageId: String
        let title: String
        let url: String
        let properties: [String: Any]
        let lastEditedTime: String
    }

    /// Enumerate a parent skill's CURATED specialists and hydrate each to a
    /// `NotionChildPageRef` (title + url + properties via one `getPage` per
    /// specialist). Failures degrade silently (empty list) — the caller maps
    /// that to a `specialistNotFound` annotation, never an error envelope.
    ///
    /// routing/specialist-relation (v3.7.4): the PRIMARY source is the
    /// parent's `Specialist` **relation property** — the operator-curated set
    /// of related specialist pages — read off the parent's `properties`
    /// (one `getPage`). This is what stops doc-pages from leaking in and
    /// surfaces real specialists that live as sibling database rows rather
    /// than as `child_page` blocks under the parent. Verified live: the
    /// property is singular `Specialist` (see
    /// `NotionJSON.specialistRelationPropertyNames`).
    ///
    /// Fallback: if there is NO `Specialist` relation (empty / property
    /// absent), we degrade to the legacy `child_page` walk so older pages
    /// keep resolving. `SpecialistFilter` runs as a defensive secondary
    /// guard on BOTH paths (belt + suspenders) so any doc-page that slips
    /// into the relation is still excluded.
    ///
    /// Implementation note: the fallback walk uses `fetchChildBlocksRaw`
    /// (returns `Data` which IS Sendable) + manual pagination instead of
    /// the actor's `fetchAllSiblingBlocks` helper (`[[String: Any]]` is NOT
    /// Sendable under strict concurrency). Same wire contract.
    static func listNotionChildPages(
        client: NotionClient,
        pageId: String
    ) async -> [NotionChildPageRef] {
        // 1) PRIMARY: the parent's curated `Specialist` relation.
        var relationIds: [String] = []
        if let parentData = try? await client.getPage(pageId: pageId),
           let parentJSON = try? JSONSerialization.jsonObject(with: parentData) as? [String: Any],
           let props = parentJSON["properties"] as? [String: Any] {
            relationIds = NotionJSON.extractSpecialistRelationIDs(from: props)
        }

        let candidateIds: [String]
        if relationIds.isEmpty {
            // 2) FALLBACK: no curated relation → walk child_page blocks.
            candidateIds = await listChildPageBlockIds(client: client, pageId: pageId)
        } else {
            candidateIds = relationIds
        }

        var out: [NotionChildPageRef] = []
        for cid in candidateIds {
            var props: [String: Any] = [:]
            var url = ""
            var resolvedTitle = ""
            var lastEditedTime = ""
            if let pageData = try? await client.getPage(pageId: cid),
               let json = try? JSONSerialization.jsonObject(with: pageData) as? [String: Any] {
                url = json["url"] as? String ?? ""
                lastEditedTime = json["last_edited_time"] as? String ?? ""
                props = json["properties"] as? [String: Any] ?? [:]
                if !props.isEmpty {
                    let t = NotionJSON.extractTitle(from: props)
                    if !t.isEmpty && t != "Untitled" { resolvedTitle = t }
                }
            }
            // Two hydration-time guards (belt + suspenders):
            //  1) exclude any doc-page (changelogs, PRDs, §-sections, test
            //     matrices, evolution logs, phase/pruning notes, duplicate
            //     stubs) that slipped into the curated relation or the
            //     fallback walk, by title; and
            //  2) exclude a retired specialist by lifecycle status — a
            //     deprecated/archived/folded row (or one with a Deprecation
            //     Date) may linger in the curated relation for history but
            //     must never surface in routing (v3.7.6).
            // isActiveSpecialist fails open, so an absent/odd Status keeps the
            // specialist (an empty props from a failed fetch is already
            // dropped by the title guard above).
            guard SpecialistFilter.isSpecialist(title: resolvedTitle),
                  SpecialistFilter.isActiveSpecialist(properties: props) else { continue }
            out.append(NotionChildPageRef(
                pageId: cid,
                title: resolvedTitle,
                url: url,
                properties: props,
                lastEditedTime: lastEditedTime
            ))
        }
        return out
    }

    /// Bounded `child_page`-block walk (the legacy fallback source for
    /// `listNotionChildPages`). 50 pages × 100 = 5000-block defensive cap.
    /// Returns child page ids in document order.
    static func listChildPageBlockIds(
        client: NotionClient,
        pageId: String
    ) async -> [String] {
        var ids: [String] = []
        var cursor: String? = nil
        for _ in 0..<50 {
            guard let data = try? await client.fetchChildBlocksRaw(blockId: pageId, startCursor: cursor, pageSize: 100) else {
                break
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                break
            }
            for block in results {
                guard let type = block["type"] as? String, type == "child_page",
                      let cid = block["id"] as? String else { continue }
                ids.append(cid)
            }
            let hasMore = json["has_more"] as? Bool ?? false
            guard hasMore, let next = json["next_cursor"] as? String, !next.isEmpty else { break }
            cursor = next
        }
        return ids
    }

    /// Inject the PKT-907 envelope keys (`resolvedPath`, `matchConfidence`,
    /// `matchReason`, `annotation`) into a Notion-source envelope.
    static func annotateEnvelope(
        _ envelope: Value,
        parentName: String,
        dispatch: SpecialistDispatch
    ) -> Value {
        guard case .object(var dict) = envelope else { return envelope }
        if let rp = dispatch.resolvedPath {
            dict["resolvedPath"] = .string(rp)
        }
        if let s = dispatch.matchScore {
            dict["matchConfidence"] = .double(s)
        }
        if let r = dispatch.matchReason {
            dict["matchReason"] = .string(r)
        }
        if let a = dispatch.annotation {
            dict["annotation"] = .string(a.rawValue)
            // Always surface the parent's name when annotating — agents
            // need to know that they got the parent body and why.
            dict["parentName"] = .string(parentName)
        }
        // Routing-reliability item 4: structured disambiguation candidates.
        if !dispatch.disambiguationCandidates.isEmpty {
            dict["candidates"] = .array(dispatch.disambiguationCandidates.map { c in
                .object([
                    "title": .string(c.title),
                    "path": .string(c.path),
                    "score": .double(c.score),
                    "reason": .string(c.reason)
                ])
            })
            dict["disambiguationPrompt"] = .string(
                "Multiple specialists could fit. Re-fetch one by path: " +
                dispatch.disambiguationCandidates.map { "fetch_skill('\($0.path)')" }.joined(separator: " or ") +
                " — or send a sharper intent."
            )
        }
        // Routing-reliability item 3: sibling-specialists routing footer.
        let resolvedTitle = dispatch.resolvedSpecialist?.title
        if let footer = Self.routingFooter(
            parentName: parentName,
            currentSpecialistTitle: resolvedTitle,
            siblingTitles: dispatch.siblingTitles
        ) {
            dict["routingFooter"] = .string(footer)
        }
        return .object(dict)
    }

    /// fb-resultsize: annotate the `fetch_skill` envelope with the outcome
    /// of a `section` selector. When a section matched, records
    /// `section` (the requested name) + `sectionMatched: true` so the agent
    /// knows the body is a partial slice. When the section was requested but
    /// no heading matched, records `annotation: "section-not-found"` plus
    /// the requested name and `sectionMatched: false` — a compact heading
    /// index is returned instead of the full body. No-op when no section was requested.
    ///
    /// Pure + nonisolated: mutates only its own envelope copy.
    nonisolated static func annotateSection(
        _ envelope: Value,
        requested: String?,
        matched: Bool,
        missed: Bool
    ) -> Value {
        guard let requested else { return envelope }
        guard case .object(var dict) = envelope else { return envelope }
        dict["section"] = .string(requested)
        dict["sectionMatched"] = .bool(matched)
        if missed {
            dict["annotation"] = .string("section-not-found")
        }
        return .object(dict)
    }

    /// fb-resultsize: post-process an already-built envelope (file-source
    /// path) to honour a `section` selector. Slices the envelope's
    /// `content` markdown to the requested heading, recomputes the honest
    /// `blockCount` (non-empty line count), and stamps the section
    /// annotation. No section requested → returns the envelope untouched.
    /// No match → compact heading index + `section-not-found` annotation.
    ///
    /// Pure + nonisolated: reads/writes only its own envelope copy.
    nonisolated static func applySectionToEnvelope(
        _ envelope: Value,
        section: String?
    ) -> Value {
        guard let section else { return envelope }
        guard case .object(var dict) = envelope,
              case .string(let content)? = dict["content"] else {
            // No content to slice — still record the request + miss so the
            // result is never silently unannotated.
            return Self.annotateSection(envelope, requested: section, matched: false, missed: true)
        }
        if let slice = Self.extractMarkdownSection(content, section: section), !slice.isEmpty {
            dict["content"] = .string(slice)
            let nonEmptyLineCount = slice
                .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .reduce(into: 0) { acc, line in
                    if !line.trimmingCharacters(in: .whitespaces).isEmpty { acc += 1 }
                }
            dict["blockCount"] = .int(nonEmptyLineCount)
            return Self.annotateSection(.object(dict), requested: section, matched: true, missed: false)
        }
        let headings = Self.markdownHeadings(content)
        dict["content"] = .string(Self.sectionMissMarkdown(requested: section, markdown: content))
        dict["availableSections"] = .array(headings.prefix(100).map(Value.string))
        dict["blockCount"] = .int(headings.isEmpty ? 1 : headings.count + 2)
        return Self.annotateSection(.object(dict), requested: section, matched: false, missed: true)
    }

    /// Routing-reliability item 3: build a short footer naming the OTHER
    /// specialists under this parent + how to re-route. Returns nil when
    /// there are no other specialists to route to (so a single-specialist
    /// parent or the bare-parent fast path adds no footer noise).
    ///
    /// Pure + nonisolated: touches only its string arguments.
    nonisolated static func routingFooter(
        parentName: String,
        currentSpecialistTitle: String?,
        siblingTitles: [String]
    ) -> String? {
        let current = currentSpecialistTitle?.lowercased()
        let others = siblingTitles.filter { $0.lowercased() != current }
        guard !others.isEmpty else { return nil }
        let list = others.map { "\(parentName)/\($0)" }.joined(separator: ", ")
        return "Other \(parentName) specialists: \(list). " +
               "For a different sub-task, fetch_skill('\(parentName)', intent: '<that sub-task>') " +
               "or fetch one directly by path."
    }

    /// Public, network-free entry point mirroring the private `routingFooter`
    /// so the routing-reliability test suite can assert footer shape without
    /// driving a live Notion fetch. Same logic, same nil-when-no-siblings
    /// contract.
    public nonisolated static func routingFooterForTesting(
        parentName: String,
        currentSpecialistTitle: String?,
        siblingTitles: [String]
    ) -> String? {
        routingFooter(
            parentName: parentName,
            currentSpecialistTitle: currentSpecialistTitle,
            siblingTitles: siblingTitles
        )
    }

    /// File-source annotation helper. Same envelope keys as the Notion
    /// path — agents read one shape across both sources.
    static func annotateFileEnvelope(
        _ envelope: Value,
        parentName: String,
        annotation: SkillAnnotation?,
        resolvedPath: String?,
        score: Double?,
        reason: String?,
        candidates: [DispatchCandidate] = [],
        currentSpecialistTitle: String? = nil,
        siblingTitles: [String] = []
    ) -> Value {
        guard case .object(var dict) = envelope else { return envelope }
        if let rp = resolvedPath { dict["resolvedPath"] = .string(rp) }
        if let s = score { dict["matchConfidence"] = .double(s) }
        if let r = reason { dict["matchReason"] = .string(r) }
        if let a = annotation {
            dict["annotation"] = .string(a.rawValue)
            dict["parentName"] = .string(parentName)
        }
        // Routing-reliability item 4: disambiguation candidates.
        if !candidates.isEmpty {
            dict["candidates"] = .array(candidates.map { c in
                .object([
                    "title": .string(c.title),
                    "path": .string(c.path),
                    "score": .double(c.score),
                    "reason": .string(c.reason)
                ])
            })
            dict["disambiguationPrompt"] = .string(
                "Multiple specialists could fit. Re-fetch one by path: " +
                candidates.map { "fetch_skill('\($0.path)')" }.joined(separator: " or ") +
                " — or send a sharper intent."
            )
        }
        // Routing-reliability item 3: sibling-specialists routing footer.
        if let footer = Self.routingFooter(
            parentName: parentName,
            currentSpecialistTitle: currentSpecialistTitle,
            siblingTitles: siblingTitles
        ) {
            dict["routingFooter"] = .string(footer)
        }
        return .object(dict)
    }

    // MARK: - PKT-907 W3: surface specialists in skills_routing_list

    /// Post-process the `mergedRoutingSkills` rows to attach a
    /// `specialists: [{path,title,summary}]` array for every parent that
    /// has children — file-source parents from the local `specialists/`
    /// directory or a frontmatter `specialists:` array, and (v3.7·1)
    /// Notion-source parents from the on-disk `SkillsCacheReader` cache.
    ///
    /// Notion enumeration used to be deferred here ("N×(getPage +
    /// fetchAllSiblingBlocks) blows the cold-start budget"); the v3.7·1
    /// cache makes the read O(1) per parent so the eager surface is now
    /// safe. Stale cache entries are still surfaced — flagged via the
    /// row-level `specialistsStale` key — so a long-running operator
    /// without network never loses the routing hints. Cache misses
    /// remain silent (no specialists rendered), preserving the previous
    /// degrade-gracefully contract.
    static func surfaceSpecialistsInRows(_ rows: [Value]) async -> [Value] {
        let maxSurfacedSpecialists = 5

        // Build a name → ParsedSkill map for file-source skills.
        let fileSkills = await FilesystemSkillIndex.shared.allSkills()
        var byName: [String: ParsedSkill] = [:]
        for fs in fileSkills { byName[fs.name.lowercased()] = fs }

        // v3.7·1: snapshot the Notion-source cache once per call. The
        // reader is O(N) over cached parents (single JSON load each) so
        // even with 100s of parents this is well under the per-handshake
        // budget. The previous N×N cold-start path is gone.
        let cachedParents = await SkillsCacheReader.shared.readAll()
        var cacheByName: [String: CachedParent] = [:]
        for cp in cachedParents { cacheByName[cp.parentTitle.lowercased()] = cp }

        var out: [Value] = []
        for row in rows {
            guard case .object(var dict) = row else {
                out.append(row)
                continue
            }
            guard case .string(let name) = dict["name"] else {
                out.append(row)
                continue
            }
            let isFileSource: Bool = {
                if case .string(let src)? = dict["source"], src == "file" { return true }
                return false
            }()
            if isFileSource, let parent = byName[name.lowercased()] {
                let specialists = SkillSpecialistFileResolver.listAll(parent: parent)
                if !specialists.isEmpty {
                    let visible = specialists.prefix(maxSurfacedSpecialists)
                    let arr: [Value] = visible.map { sp in
                        let summary: String = {
                            if case .string(let d) = sp.frontmatter["description"] { return d }
                            if case .string(let s) = sp.frontmatter["summary"] { return s }
                            return SpecialistSummaryExtractor.firstSentence(from: sp.body)
                        }()
                        return .object([
                            "path": .string("\(name)/\(sp.name)"),
                            "title": .string(sp.name),
                            "summary": .string(summary)
                        ])
                    }
                    dict["specialists"] = .array(arr)
                    dict["specialistCount"] = .int(specialists.count)
                    if specialists.count > maxSurfacedSpecialists {
                        dict["specialistsTruncated"] = .bool(true)
                    }
                }
            } else if let cached = cacheByName[name.lowercased()], !cached.children.isEmpty {
                // Notion-source row with a cache hit.
                let visible = cached.children.prefix(maxSurfacedSpecialists)
                let arr: [Value] = visible.map { child in
                    .object([
                        "path": .string("\(name)/\(child.title)"),
                        "title": .string(child.title),
                        "summary": .string(child.summary),
                        "pageId": .string(child.id)
                    ])
                }
                dict["specialists"] = .array(arr)
                dict["specialistCount"] = .int(cached.children.count)
                if cached.children.count > maxSurfacedSpecialists {
                    dict["specialistsTruncated"] = .bool(true)
                }
                if cached.stale {
                    dict["specialistsStale"] = .bool(true)
                }
            }

            let specialistSummaries: [SpecialistSummary] = {
                guard case .array(let values)? = dict["specialists"] else { return [] }
                return values.compactMap { value in
                    guard case .object(let item) = value,
                          case .string(let path)? = item["path"],
                          case .string(let title)? = item["title"] else { return nil }
                    let summary: String = {
                        if case .string(let text)? = item["summary"] { return text }
                        return ""
                    }()
                    return SpecialistSummary(path: path, title: title, summary: summary)
                }
            }()
            let summary: String = {
                if case .string(let text)? = dict["summary"] { return text }
                return ""
            }()
            let triggers: [String] = {
                guard case .array(let values)? = dict["triggerPhrases"] else { return [] }
                return values.compactMap { if case .string(let text) = $0 { return text }; return nil }
            }()
            let antiTriggers: [String] = {
                guard case .array(let values)? = dict["antiTriggerPhrases"] else { return [] }
                return values.compactMap { if case .string(let text) = $0 { return text }; return nil }
            }()
            let warnings = SkillRoutingConsistencyLinter.warnings(
                parentName: name,
                summary: summary,
                triggerPhrases: triggers,
                antiTriggerPhrases: antiTriggers,
                specialists: specialistSummaries
            )
            if !warnings.isEmpty {
                dict["routingWarnings"] = .array(warnings.map(Value.string))
            }

            out.append(.object(dict))
        }
        return out
    }
}
