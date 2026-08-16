// VoiceMemoMemoryRelationMatcher.swift — cache-only Memory relation attach
// TheBridge · Modules · VoiceMemo
//
// Conservative matcher for memory_keep: unique 2+ token contact titles
// or aliases only (1-token names never attach), distinctive project/doc
// phrases (including unique 2-token prefixes), exact-title blocks.
// Never creates PEOPLE rows.
// Dual-sided Notion reverse-fill is accepted; we only write the Memory side.

import Foundation
import MCP

public struct VoiceMemoCacheEntry: Sendable, Equatable {
    public var id: String
    public var title: String
    public var aliases: [String]

    public init(id: String, title: String, aliases: [String] = []) {
        self.id = PacketRegistryEnvelope.dashedId(id)
        self.title = title
        self.aliases = aliases
    }
}

public struct VoiceMemoRelationCatalog: Sendable, Equatable {
    public var contacts: [VoiceMemoCacheEntry]
    public var projects: [VoiceMemoCacheEntry]
    public var docs: [VoiceMemoCacheEntry]
    public var blocks: [VoiceMemoCacheEntry]

    public init(
        contacts: [VoiceMemoCacheEntry] = [],
        projects: [VoiceMemoCacheEntry] = [],
        docs: [VoiceMemoCacheEntry] = [],
        blocks: [VoiceMemoCacheEntry] = []
    ) {
        self.contacts = contacts
        self.projects = projects
        self.docs = docs
        self.blocks = blocks
    }

    public var isEmpty: Bool {
        contacts.isEmpty && projects.isEmpty && docs.isEmpty && blocks.isEmpty
    }

    public static func loadFromSharedCache() async -> VoiceMemoRelationCatalog {
        let cache = RegistryRowCache.shared
        return VoiceMemoRelationCatalog(
            contacts: entries(from: await cache.readAll(entity: "contact")),
            projects: entries(from: await cache.readAll(entity: "project")),
            docs: entries(from: await cache.readAll(entity: "doc")),
            blocks: entries(from: await cache.readAll(entity: "block"))
        )
    }

    public static func entries(from rows: [CachedRow]) -> [VoiceMemoCacheEntry] {
        rows.compactMap { row in
            let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !row.pageId.isEmpty else { return nil }
            return VoiceMemoCacheEntry(id: row.pageId, title: title, aliases: aliases(in: row.properties))
        }
    }

    private static func aliases(in properties: Value) -> [String] {
        guard case .object(let props) = properties else { return [] }
        var out: [String] = []
        for key in ["alias", "aliases", "name"] {
            out.append(contentsOf: strings(from: props[key]))
        }
        return out
    }

    private static func strings(from value: Value?) -> [String] {
        switch value {
        case .string(let s):
            return splitNewlines(s)
        case .array(let arr):
            return arr.flatMap { item -> [String] in
                guard case .string(let s) = item else { return [] }
                return splitNewlines(s)
            }
        default:
            return []
        }
    }

    /// Notion Alias often stores one blob with newline-separated phrases.
    /// Index each line on its own so a shared pair on one line cannot be
    /// glued to the rest of the blob.
    static func splitNewlines(_ raw: String) -> [String] {
        raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

public struct VoiceMemoRelationMatch: Sendable, Equatable {
    public var contactIds: [String]
    public var projectIds: [String]
    public var docIds: [String]
    public var blockIds: [String]
    public var notes: [String]

    public init(
        contactIds: [String] = [],
        projectIds: [String] = [],
        docIds: [String] = [],
        blockIds: [String] = [],
        notes: [String] = []
    ) {
        self.contactIds = contactIds
        self.projectIds = projectIds
        self.docIds = docIds
        self.blockIds = blockIds
        self.notes = notes
    }
}

public enum VoiceMemoMemoryRelationMatcher {
    /// High-frequency tokens that must never attach a project/doc by themselves.
    public static let stoplist: Set<String> = [
        "a", "an", "and", "the", "of", "for", "to", "in", "on", "with", "my",
        "this", "that", "or", "os", "mcp", "app", "site",
        "bridge", "keep", "focus", "energy",
    ]

    public static func match(haystack: String, catalog: VoiceMemoRelationCatalog) -> VoiceMemoRelationMatch {
        let hay = normalize(haystack)
        guard !hay.isEmpty, !catalog.isEmpty else { return VoiceMemoRelationMatch() }

        let contacts = matchContacts(hay: hay, entries: catalog.contacts)
        // Projects and docs share distinctive-token/pair uniqueness so a
        // geographic alias on a doc can block the same pair on a project.
        let distinctiveEntries = catalog.projects + catalog.docs
        let tokenOwners = distinctiveTokenIndex(distinctiveEntries)
        let pairOwners = distinctivePairIndex(distinctiveEntries)
        return VoiceMemoRelationMatch(
            contactIds: contacts.ids,
            projectIds: matchDistinctive(
                hay: hay, entries: catalog.projects, tokenOwners: tokenOwners, pairOwners: pairOwners
            ),
            docIds: matchDistinctive(
                hay: hay, entries: catalog.docs, tokenOwners: tokenOwners, pairOwners: pairOwners
            ),
            blockIds: matchExactTitles(hay: hay, entries: catalog.blocks, requireTwoTokens: true),
            notes: contacts.notes
        )
    }

    // MARK: - Contacts (unique 2+ token title/alias only; first-name collisions noted)

    private static func matchContacts(
        hay: String,
        entries: [VoiceMemoCacheEntry]
    ) -> (ids: [String], notes: [String]) {
        var attached: [String] = []
        var notes: [String] = []
        var attachedIds = Set<String>()

        var phraseOwners: [String: [VoiceMemoCacheEntry]] = [:]
        for entry in entries {
            for phrase in multiTokenPhrases(entry) {
                phraseOwners[phrase, default: []].append(entry)
            }
        }
        for (phrase, group) in phraseOwners {
            guard containsPhrase(hay, phrase) else { continue }
            let uniqueIds = Set(group.map(\.id))
            if uniqueIds.count == 1, let only = group.first, attachedIds.insert(only.id).inserted {
                attached.append(only.id)
            } else if uniqueIds.count >= 2 {
                notes.append(collisionNote(label: group[0].title, entries: group))
            }
        }

        // First-name hits are notes only when two or more contacts share the
        // token and none of them already attached via a full name. Unique
        // first names never attach (PEOPLE: full_name_only).
        let byFirst = Dictionary(grouping: entries) { firstToken(normalize($0.title)) }
        for (first, group) in byFirst where !first.isEmpty && first.count >= 2 {
            guard containsPhrase(hay, first) else { continue }
            let uniqueIds = Set(group.map(\.id))
            guard uniqueIds.count >= 2 else { continue }
            let already = group.contains { attachedIds.contains($0.id) }
            if !already {
                notes.append(collisionNote(label: first.capitalized, entries: group))
            }
        }
        return (attached, notes)
    }

    /// Titles and aliases with two or more tokens. 1-token names never attach.
    private static func multiTokenPhrases(_ entry: VoiceMemoCacheEntry) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in sourcePhrases(entry) {
            let phrase = normalize(raw)
            let tokens = phrase.split(separator: " ")
            guard tokens.count >= 2, seen.insert(phrase).inserted else { continue }
            out.append(phrase)
        }
        return out
    }

    private static func collisionNote(label: String, entries: [VoiceMemoCacheEntry]) -> String {
        let names = Array(Set(entries.map(\.title))).sorted()
        let shown = names.prefix(5).joined(separator: ", ")
        let extra = names.count > 5 ? "…" : ""
        return "Skipped “\(label)” — \(names.count) contacts (\(shown)\(extra))"
    }

    // MARK: - Projects / docs (exact title/alias, unique 2-token prefix, or unique token)

    private static func matchDistinctive(
        hay: String,
        entries: [VoiceMemoCacheEntry],
        tokenOwners: [String: Set<String>],
        pairOwners: [String: Set<String>]
    ) -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        for entry in entries {
            guard matchProjectOrDoc(
                hay: hay, entry: entry, tokenOwners: tokenOwners, pairOwners: pairOwners
            ) else { continue }
            if seen.insert(entry.id).inserted { ids.append(entry.id) }
        }
        return ids
    }

    private static func matchProjectOrDoc(
        hay: String,
        entry: VoiceMemoCacheEntry,
        tokenOwners: [String: Set<String>],
        pairOwners: [String: Set<String>]
    ) -> Bool {
        let phrases = sourcePhrases(entry)
            .map(normalize)
            .filter { !$0.isEmpty }
        for phrase in phrases {
            let tokens = phrase.split(separator: " ").map(String.init)
            let distinctive = tokens.filter { !stoplist.contains($0) }
            guard !distinctive.isEmpty else { continue }
            if containsPhrase(hay, phrase) { return true }
            if distinctive.count >= 2, containsPhrase(hay, distinctive.joined(separator: " ")) {
                return true
            }
            let pairTokens = distinctive.filter { $0.count >= 3 }
            if pairTokens.count >= 2 {
                for i in 0..<(pairTokens.count - 1) {
                    let pair = pairTokens[i] + " " + pairTokens[i + 1]
                    let owners = pairOwners[pair] ?? []
                    if owners.count == 1, containsPhrase(hay, pair) { return true }
                }
            }
            if distinctive.count == 1, let token = distinctive.first, token.count >= 3 {
                let owners = tokenOwners[token] ?? []
                if owners.count == 1, containsPhrase(hay, token) { return true }
            }
        }
        return false
    }

    private static func distinctiveTokenIndex(_ entries: [VoiceMemoCacheEntry]) -> [String: Set<String>] {
        var index: [String: Set<String>] = [:]
        for entry in entries {
            let phrases = sourcePhrases(entry).map(normalize)
            var tokens = Set<String>()
            for phrase in phrases {
                for token in phrase.split(separator: " ").map(String.init) where !stoplist.contains(token) && token.count >= 3 {
                    tokens.insert(token)
                }
            }
            for token in tokens {
                index[token, default: []].insert(entry.id)
            }
        }
        return index
    }

    /// Consecutive distinctive ≥3-char token pairs, e.g. "emmiwood obk" from
    /// "Emmiwood / OBK Website + Booking System". Shared pairs never attach.
    private static func distinctivePairIndex(_ entries: [VoiceMemoCacheEntry]) -> [String: Set<String>] {
        var index: [String: Set<String>] = [:]
        for entry in entries {
            for phrase in sourcePhrases(entry).map(normalize) {
                let distinctive = phrase.split(separator: " ").map(String.init)
                    .filter { !stoplist.contains($0) && $0.count >= 3 }
                guard distinctive.count >= 2 else { continue }
                for i in 0..<(distinctive.count - 1) {
                    let pair = distinctive[i] + " " + distinctive[i + 1]
                    index[pair, default: []].insert(entry.id)
                }
            }
        }
        return index
    }

    // MARK: - Blocks (exact full title only; skip 1-token titles)

    private static func matchExactTitles(
        hay: String,
        entries: [VoiceMemoCacheEntry],
        requireTwoTokens: Bool
    ) -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        for entry in entries {
            let phrase = normalize(entry.title)
            guard !phrase.isEmpty else { continue }
            let tokens = phrase.split(separator: " ").map(String.init)
            if requireTwoTokens, tokens.count < 2 { continue }
            guard containsPhrase(hay, phrase) else { continue }
            if seen.insert(entry.id).inserted { ids.append(entry.id) }
        }
        return ids
    }

    // MARK: - Normalize / phrase

    private static func sourcePhrases(_ entry: VoiceMemoCacheEntry) -> [String] {
        ([entry.title] + entry.aliases).flatMap(VoiceMemoRelationCatalog.splitNewlines)
    }

    public static func normalize(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        var lastSpace = true
        for ch in raw.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastSpace = false
            } else if !lastSpace {
                out.append(" ")
                lastSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    public static func containsPhrase(_ haystack: String, _ phrase: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        return " \(haystack) ".contains(" \(phrase) ")
    }

    private static func firstToken(_ normalized: String) -> String {
        String(normalized.split(separator: " ").first ?? "")
    }
}
