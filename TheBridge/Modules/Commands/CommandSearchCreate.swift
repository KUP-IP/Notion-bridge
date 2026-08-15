// CommandSearchCreate.swift — GitHub #140 C1
//
// Search may create a command only through an explicit confirmation. Ordinary
// Return, empty results, and failed matches never write. Duplicate and
// sensitive-path warnings are assessed before Save. Edit deep-links by
// immutable command ID, not display slug.

import Foundation

public struct CommandCreateDraft: Equatable, Sendable {
    public var name: String
    public var body: String
    public var sensitive: Bool
    public var keySlot: Int?

    public init(name: String = "", body: String = "", sensitive: Bool = false, keySlot: Int? = nil) {
        self.name = name
        self.body = body
        self.sensitive = sensitive
        self.keySlot = keySlot
    }

    public var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedBody: String {
        body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum CommandCreateDuplicate: Equatable, Sendable {
    case exactSlug(String)
    case exactName(String)
    case nearName(String)
}

public struct CommandCreateAssessment: Equatable, Sendable {
    public var draft: CommandCreateDraft
    public var duplicates: [CommandCreateDuplicate]
    public var sensitiveHits: [String]
    public var requiresConfirmation: Bool { true }

    public var hasExactDuplicate: Bool {
        duplicates.contains {
            switch $0 {
            case .exactSlug, .exactName: return true
            case .nearName: return false
            }
        }
    }

    public var canProposeSave: Bool {
        !draft.trimmedName.isEmpty && !hasExactDuplicate
    }
}

public enum CommandSettingsDeepLink {
    public static let prefix = "command-id:"

    public static func anchor(commandID: String) -> String {
        prefix + commandID
    }

    public static func commandID(fromAnchor anchor: String?) -> String? {
        guard let anchor, anchor.hasPrefix(prefix) else { return nil }
        let id = String(anchor.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    public static func slug(forID id: String, in commands: [CommandStore.Command]) -> String? {
        commands.first(where: { $0.id == id })?.slug
    }
}

public enum CommandSearchCreate {
    /// Failed searches and ordinary Return never create.
    public static let returnCreatesCommand = false

    public static func draft(fromSearchText text: String) -> CommandCreateDraft {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        let name = String(firstLine.prefix(80))
        return CommandCreateDraft(name: name, body: trimmed)
    }

    public static func assess(
        draft: CommandCreateDraft,
        existing: [CommandStore.Command],
        sensitivePaths: [String]
    ) -> CommandCreateAssessment {
        let slug = CommandStore.slugify(draft.trimmedName)
        var duplicates: [CommandCreateDuplicate] = []
        var seen = Set<String>()
        for command in existing {
            if !slug.isEmpty, command.slug == slug, seen.insert("slug:\(command.slug)").inserted {
                duplicates.append(.exactSlug(command.slug))
            } else if command.name.compare(draft.trimmedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame,
                      seen.insert("name:\(command.slug)").inserted {
                duplicates.append(.exactName(command.slug))
            } else if isNearDuplicate(draftName: draft.trimmedName, existingName: command.name),
                      seen.insert("near:\(command.slug)").inserted {
                duplicates.append(.nearName(command.slug))
            }
        }
        let hits = sensitiveHits(in: draft.body, paths: sensitivePaths)
        var next = draft
        next.sensitive = !hits.isEmpty || draft.sensitive
        return CommandCreateAssessment(draft: next, duplicates: duplicates, sensitiveHits: hits)
    }

    /// Search never shows command bodies that mention a sensitive path.
    public static func shouldSuppressBodyPreview(body: String, sensitivePaths: [String]) -> Bool {
        !sensitiveHits(in: body, paths: sensitivePaths).isEmpty
    }

    public static func searchSubtitle(slot: Int?, body: String, sensitivePaths: [String]) -> String? {
        let slotLabel = slot.map { "slot \($0)" }
        if shouldSuppressBodyPreview(body: body, sensitivePaths: sensitivePaths) {
            return [slotLabel, "Sensitive"].compactMap { $0 }.joined(separator: " · ")
        }
        return slotLabel
    }

    public static func sensitiveHits(in body: String, paths: [String]) -> [String] {
        let haystack = body.lowercased()
        var hits: [String] = []
        for path in paths {
            let needle = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { continue }
            if haystack.contains(needle.lowercased()) {
                hits.append(path)
            }
        }
        return hits
    }

    public static func duplicateBody(of command: CommandStore.Command, existingNames: [String]) -> (name: String, body: String) {
        var name = "\(command.name) copy"
        var i = 1
        let set = Set(existingNames.map { $0.lowercased() })
        while set.contains(name.lowercased()) {
            i += 1
            name = "\(command.name) copy \(i)"
        }
        return (name, command.body)
    }

    private static func isNearDuplicate(draftName: String, existingName: String) -> Bool {
        let a = normalize(draftName)
        let b = normalize(existingName)
        guard !a.isEmpty, !b.isEmpty, a != b else { return false }
        if a.hasPrefix(b) || b.hasPrefix(a) { return abs(a.count - b.count) <= 4 }
        return levenshtein(a, b) <= 2 && min(a.count, b.count) >= 4
    }

    private static func normalize(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var prev = Array(0...bChars.count)
        var cur = Array(repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            cur[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[bChars.count]
    }
}
