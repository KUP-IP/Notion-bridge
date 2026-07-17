// SkillMutationTargetResolver.swift — shared parent/specialist identity resolution
//
// Skill reads have long supported `parent/specialist` paths through
// `fetch_skill`, while mutation tools historically looked only at configured
// top-level SkillsManager rows. This pure resolver gives every mutation path
// the same bounded identity surface: configured parents plus specialists that
// are already present in the routing cache.

import Foundation

public struct SkillMutationConfiguredSkill: Sendable, Equatable {
    public let name: String
    public let pageId: String

    public init(name: String, pageId: String) {
        self.name = name
        self.pageId = pageId
    }
}

public struct SkillMutationTarget: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case configuredParent
        case cachedSpecialist
    }

    public let kind: Kind
    public let name: String
    public let pageId: String
    public let parentName: String?
    public let parentPageId: String?
    public let cachedSummary: String

    public init(
        kind: Kind,
        name: String,
        pageId: String,
        parentName: String? = nil,
        parentPageId: String? = nil,
        cachedSummary: String = ""
    ) {
        self.kind = kind
        self.name = name
        self.pageId = pageId
        self.parentName = parentName
        self.parentPageId = parentPageId
        self.cachedSummary = cachedSummary
    }
}

public enum SkillMutationTargetResolution: Sendable, Equatable {
    case found(SkillMutationTarget)
    case notFound
    case ambiguous([String])
}

public enum SkillMutationTargetResolver: Sendable {
    public static func resolve(
        _ rawName: String,
        configured: [SkillMutationConfiguredSkill],
        cachedParents: [CachedParent]
    ) -> SkillMutationTargetResolution {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notFound }

        let pathParts = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
        if pathParts.count == 2 {
            return resolvePath(
                parent: pathParts[0], child: pathParts[1],
                configured: configured, cachedParents: cachedParents
            )
        }

        let wanted = normalize(trimmed)
        if let parent = configured.first(where: { normalize($0.name) == wanted }) {
            return .found(SkillMutationTarget(
                kind: .configuredParent,
                name: parent.name,
                pageId: parent.pageId
            ))
        }

        let childMatches = cachedParents.flatMap { parent in
            parent.children.compactMap { child -> SkillMutationTarget? in
                let names = [child.title] + child.aliases
                guard names.contains(where: { normalize($0) == wanted }) else { return nil }
                return SkillMutationTarget(
                    kind: .cachedSpecialist,
                    name: child.title,
                    pageId: child.id,
                    parentName: parent.parentTitle,
                    parentPageId: parent.parentId,
                    cachedSummary: child.summary
                )
            }
        }
        return unique(childMatches)
    }

    private static func resolvePath(
        parent rawParent: String,
        child rawChild: String,
        configured: [SkillMutationConfiguredSkill],
        cachedParents: [CachedParent]
    ) -> SkillMutationTargetResolution {
        let wantedParent = normalize(rawParent)
        let wantedChild = normalize(rawChild)

        let configuredParent = configured.first { normalize($0.name) == wantedParent }
        let parentMatches = cachedParents.filter { parent in
            normalize(parent.parentTitle) == wantedParent
                || configuredParent.map { CachedSkillBody.normalize($0.pageId) }
                    == CachedSkillBody.normalize(parent.parentId)
        }
        guard !parentMatches.isEmpty else { return .notFound }

        let childMatches = parentMatches.flatMap { parent in
            parent.children.compactMap { child -> SkillMutationTarget? in
                let names = [child.title] + child.aliases
                guard names.contains(where: { normalize($0) == wantedChild }) else { return nil }
                return SkillMutationTarget(
                    kind: .cachedSpecialist,
                    name: child.title,
                    pageId: child.id,
                    parentName: parent.parentTitle,
                    parentPageId: parent.parentId,
                    cachedSummary: child.summary
                )
            }
        }
        return unique(childMatches)
    }

    private static func unique(_ matches: [SkillMutationTarget]) -> SkillMutationTargetResolution {
        let deduped = Dictionary(grouping: matches, by: { CachedSkillBody.normalize($0.pageId) })
            .compactMap { $0.value.first }
        if deduped.count == 1, let only = deduped.first { return .found(only) }
        if deduped.count > 1 {
            let labels = deduped.map { target in
                if let parent = target.parentName { return "\(parent)/\(target.name)" }
                return target.name
            }.sorted()
            return .ambiguous(labels)
        }
        return .notFound
    }

    private static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("sk ") { value.removeFirst(3) }
        value = value.replacingOccurrences(of: "_", with: "-")
        value = value.replacingOccurrences(of: " ", with: "-")
        while value.contains("--") { value = value.replacingOccurrences(of: "--", with: "-") }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

extension SkillsModule {
    static func resolveMutationTarget(named name: String) async -> SkillMutationTargetResolution {
        let configured = readAllSkills().compactMap { skill -> SkillMutationConfiguredSkill? in
            let pageId = skill.notionPageId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pageId.isEmpty else { return nil }
            return SkillMutationConfiguredSkill(name: skill.name, pageId: pageId)
        }
        let cachedParents = await SkillsCacheReader.shared.readAll()
        return SkillMutationTargetResolver.resolve(
            name, configured: configured, cachedParents: cachedParents
        )
    }
}
