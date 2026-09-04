// SkillExposureAuthority.swift — Runtime enrollment + exposure authority
// TheBridge · Modules · Skills

import Foundation

public enum SkillRuntimeExposure: String, Codable, Sendable, CaseIterable, Equatable {
    case off = "Off"
    case standard = "Standard"
    case routing = "Routing"
    case command = "Command"

    public var routingDiscoverable: Bool { self == .routing }
    public var inCommandPalette: Bool { self == .command }
}

public enum SkillExposureSurface: Sendable {
    case exactFetch, bodyCache, routing, command, specialist
}

public enum SkillExposureTransition: String, Codable, Sendable, Equatable {
    case unchanged, reduction, expansion, surfaceSwitch
}

public enum SkillExposureIdentity {
    public static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    public static func isValid(_ raw: String) -> Bool {
        let value = normalize(raw)
        return value.count == 32 && value.allSatisfy(\.isHexDigit)
    }
}

public struct SkillExposureApproval: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case routeReceipt, migrationBaseline }
    public let id: String
    public let kind: Kind
    public let notionPageUUID: String
    public let previousExposure: SkillRuntimeExposure?
    public let requestedExposure: SkillRuntimeExposure
    public let routeID: String
    public let authorizedAt: Date

    public init(id: String, kind: Kind, notionPageUUID: String,
                previousExposure: SkillRuntimeExposure?, requestedExposure: SkillRuntimeExposure,
                routeID: String, authorizedAt: Date) {
        self.id = id
        self.kind = kind
        self.notionPageUUID = SkillExposureIdentity.normalize(notionPageUUID)
        self.previousExposure = previousExposure
        self.requestedExposure = requestedExposure
        self.routeID = routeID
        self.authorizedAt = authorizedAt
    }

    public func authorizes(uuid: String, previous: SkillRuntimeExposure?, requested: SkillRuntimeExposure) -> Bool {
        notionPageUUID == SkillExposureIdentity.normalize(uuid)
            && previousExposure == previous
            && requestedExposure == requested
            && !routeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct SkillRegistryExposureRow: Codable, Sendable, Equatable {
    public let notionPageUUID: String
    public let displayName: String
    public let slug: String
    public let status: String?
    public let maturity: String?
    public let deprecationDate: Date?
    public let desiredExposure: SkillRuntimeExposure?
    public let url: String
    public let notionLastEditedTime: String

    public init(notionPageUUID: String, displayName: String, slug: String,
                status: String?, maturity: String?, deprecationDate: Date?,
                desiredExposure: SkillRuntimeExposure?, url: String = "",
                notionLastEditedTime: String = "") {
        self.notionPageUUID = SkillExposureIdentity.normalize(notionPageUUID)
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.slug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        self.status = status?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.maturity = maturity?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.deprecationDate = deprecationDate
        self.desiredExposure = desiredExposure
        self.url = url
        self.notionLastEditedTime = notionLastEditedTime
    }
}

public struct SkillRegistryExposureSnapshot: Codable, Sendable, Equatable {
    public let snapshotID: String
    public let capturedAt: Date
    public let schemaColumns: [String: String]
    public let paginationComplete: Bool
    public let rows: [SkillRegistryExposureRow]

    public init(snapshotID: String, capturedAt: Date, schemaColumns: [String: String],
                paginationComplete: Bool, rows: [SkillRegistryExposureRow]) {
        self.snapshotID = snapshotID
        self.capturedAt = capturedAt
        self.schemaColumns = schemaColumns
        self.paginationComplete = paginationComplete
        self.rows = rows
    }
}

public struct SkillExposureBaselineEntry: Codable, Sendable, Equatable {
    public let notionPageUUID: String
    public let displayName: String
    public let exposure: SkillRuntimeExposure

    public init(notionPageUUID: String, displayName: String, exposure: SkillRuntimeExposure) {
        self.notionPageUUID = SkillExposureIdentity.normalize(notionPageUUID)
        self.displayName = displayName
        self.exposure = exposure
    }
}

public struct SkillPublishedManifestEntry: Codable, Sendable, Equatable {
    public let notionPageUUID: String
    public let sourceKind: String
    public let displayName: String
    public let slug: String
    public let desiredExposure: SkillRuntimeExposure?
    public let publishedExposure: SkillRuntimeExposure
    public let lifecycleOverrideReason: String?
    public let approvalID: String?
    public let notionLastEditedTime: String
    public let url: String

    public init(notionPageUUID: String, sourceKind: String = "notion", displayName: String,
                slug: String, desiredExposure: SkillRuntimeExposure?,
                publishedExposure: SkillRuntimeExposure, lifecycleOverrideReason: String?,
                approvalID: String?, notionLastEditedTime: String, url: String) {
        self.notionPageUUID = SkillExposureIdentity.normalize(notionPageUUID)
        self.sourceKind = sourceKind
        self.displayName = displayName
        self.slug = slug
        self.desiredExposure = desiredExposure
        self.publishedExposure = publishedExposure
        self.lifecycleOverrideReason = lifecycleOverrideReason
        self.approvalID = approvalID
        self.notionLastEditedTime = notionLastEditedTime
        self.url = url
    }
}

public struct SkillRuntimeGeneration: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let generationID: String
    public let snapshotID: String
    public let compilerVersion: String
    public let compiledAt: Date
    public let entries: [SkillPublishedManifestEntry]

    public init(schemaVersion: Int = 1, generationID: String = UUID().uuidString.lowercased(),
                snapshotID: String, compilerVersion: String, compiledAt: Date,
                entries: [SkillPublishedManifestEntry]) {
        self.schemaVersion = schemaVersion
        self.generationID = generationID
        self.snapshotID = snapshotID
        self.compilerVersion = compilerVersion
        self.compiledAt = compiledAt
        self.entries = entries.sorted { $0.notionPageUUID < $1.notionPageUUID }
    }

    public func entry(pageID: String) -> SkillPublishedManifestEntry? {
        let id = SkillExposureIdentity.normalize(pageID)
        return entries.first { $0.notionPageUUID == id }
    }
}

public struct SkillExposureCompilationResult: Sendable, Equatable {
    public let candidate: SkillRuntimeGeneration?
    public let errors: [String]
    public let warnings: [String]
    public let changes: [String]
}

public enum SkillExposureCompiler {
    public static let compilerVersion = "1.0.0"
    /// Columns that must exist on the SKILLS data source before reconcile
    /// may compile. `Deprecation Date` is intentionally not required —
    /// fleet SKILLS SSOT (audit 2026-09-04) has no such property, and
    /// retirement still works from Status / Maturity when the column is
    /// absent. A present-but-wrong type still hard-fails.
    public static let requiredSchema: [String: String] = [
        "Skill Name": "title", "Slug": "rich_text", "Status": "status",
        "Maturity": "select", "Runtime Exposure": "select",
    ]
    /// Optional SKILLS columns. Missing → warning, not `schema_missing`.
    public static let optionalSchema: [String: String] = [
        "Deprecation Date": "date",
    ]
    public static let optionalSchemaMissingPrefix = "schema_optional_missing:"

    public static func transition(from previous: SkillRuntimeExposure?,
                                  to requested: SkillRuntimeExposure) -> SkillExposureTransition {
        if previous == requested { return .unchanged }
        guard let previous else { return requested == .off ? .unchanged : .expansion }
        if requested == .off { return .reduction }
        if previous == .off { return .expansion }
        if requested == .standard && (previous == .routing || previous == .command) { return .reduction }
        if previous == .standard && (requested == .routing || requested == .command) { return .expansion }
        if (previous == .routing && requested == .command) || (previous == .command && requested == .routing) {
            return .surfaceSwitch
        }
        return .expansion
    }

    public static func retirementReason(for row: SkillRegistryExposureRow, now: Date) -> String? {
        if row.status?.caseInsensitiveCompare("Revoked") == .orderedSame { return "status_revoked" }
        if row.maturity?.caseInsensitiveCompare("Desolved") == .orderedSame { return "maturity_desolved" }
        if let date = row.deprecationDate, date <= now { return "deprecation_date_effective" }
        return nil
    }

    public static func compile(snapshot: SkillRegistryExposureSnapshot,
                               previousGeneration: SkillRuntimeGeneration?,
                               baseline: [SkillExposureBaselineEntry],
                               approvals: [SkillExposureApproval],
                               emergencyDenylist: Set<String> = [],
                               requireReviewedPublishedRows: Bool,
                               now: Date) -> SkillExposureCompilationResult {
        var errors: [String] = []
        var warnings: [String] = []
        var changes: [String] = []
        guard snapshot.paginationComplete else {
            return .init(candidate: nil, errors: ["snapshot_incomplete_pagination"], warnings: [], changes: [])
        }
        for (name, expected) in requiredSchema {
            guard let actual = snapshot.schemaColumns[name] else { errors.append("schema_missing:\(name)"); continue }
            if actual != expected { errors.append("schema_type_mismatch:\(name):\(actual):expected_\(expected)") }
        }
        for (name, expected) in optionalSchema {
            guard let actual = snapshot.schemaColumns[name] else {
                warnings.append("\(optionalSchemaMissingPrefix)\(name)")
                continue
            }
            if actual != expected { errors.append("schema_type_mismatch:\(name):\(actual):expected_\(expected)") }
        }

        let validRows = snapshot.rows.filter { row in
            if !SkillExposureIdentity.isValid(row.notionPageUUID) { errors.append("invalid_uuid:\(row.notionPageUUID)"); return false }
            if row.displayName.isEmpty { errors.append("missing_display_name:\(row.notionPageUUID)"); return false }
            return true
        }
        let grouped = Dictionary(grouping: validRows, by: \.notionPageUUID)
        for (uuid, rows) in grouped where rows.count > 1 { errors.append("duplicate_uuid:\(uuid)") }
        let rowByUUID = Dictionary(uniqueKeysWithValues: grouped.compactMap { key, rows in rows.count == 1 ? (key, rows[0]) : nil })
        let baselineByUUID = Dictionary(uniqueKeysWithValues: baseline.map { ($0.notionPageUUID, $0) })
        let previousByUUID = Dictionary(uniqueKeysWithValues: (previousGeneration?.entries ?? []).map { ($0.notionPageUUID, $0) })

        for item in baseline where rowByUUID[item.notionPageUUID] == nil {
            errors.append("orphan_local_skill:\(item.displayName):\(item.notionPageUUID)")
        }
        for item in previousGeneration?.entries ?? [] where rowByUUID[item.notionPageUUID] == nil {
            errors.append("orphan_published_skill:\(item.displayName):\(item.notionPageUUID)")
        }

        var entries: [SkillPublishedManifestEntry] = []
        for row in validRows.sorted(by: { $0.notionPageUUID < $1.notionPageUUID }) {
            guard grouped[row.notionPageUUID]?.count == 1 else { continue }
            let oldEntry = previousByUUID[row.notionPageUUID]
            let previous = oldEntry?.publishedExposure ?? baselineByUUID[row.notionPageUUID]?.exposure
            let retirement = retirementReason(for: row, now: now)
            let denied = emergencyDenylist.contains(row.notionPageUUID)
            let requested: SkillRuntimeExposure? = (retirement != nil || denied) ? .off : row.desiredExposure

            guard let requested else {
                if let previous {
                    warnings.append("unreviewed_preserved:\(row.displayName):\(row.notionPageUUID)")
                    if requireReviewedPublishedRows { errors.append("published_row_unreviewed:\(row.displayName):\(row.notionPageUUID)") }
                    entries.append(.init(notionPageUUID: row.notionPageUUID, displayName: row.displayName,
                                         slug: row.slug, desiredExposure: nil, publishedExposure: previous,
                                         lifecycleOverrideReason: nil, approvalID: oldEntry?.approvalID,
                                         notionLastEditedTime: row.notionLastEditedTime, url: row.url))
                }
                continue
            }
            if requested == .off {
                if previous != nil && previous != .off {
                    changes.append("remove:\(row.displayName):\(retirement ?? (denied ? "emergency_denylist" : "explicit_off"))")
                }
                continue
            }

            let kind = transition(from: previous, to: requested)
            var approvalID = oldEntry?.approvalID
            if kind == .expansion || kind == .surfaceSwitch {
                guard let approval = approvals.first(where: { $0.authorizes(uuid: row.notionPageUUID, previous: previous, requested: requested) }) else {
                    errors.append("approval_required:\(row.displayName):\(previous?.rawValue ?? "Unreviewed")->\(requested.rawValue)")
                    continue
                }
                approvalID = approval.id
            }
            if previous != requested { changes.append("exposure:\(row.displayName):\(previous?.rawValue ?? "Unreviewed")->\(requested.rawValue)") }
            entries.append(.init(notionPageUUID: row.notionPageUUID, displayName: row.displayName,
                                 slug: row.slug, desiredExposure: row.desiredExposure,
                                 publishedExposure: requested,
                                 lifecycleOverrideReason: retirement ?? (denied ? "emergency_denylist" : nil),
                                 approvalID: approvalID, notionLastEditedTime: row.notionLastEditedTime, url: row.url))
        }

        let slugGroups = Dictionary(grouping: entries.filter { !$0.slug.isEmpty }) { $0.slug.lowercased() }
        for (slug, rows) in slugGroups where rows.count > 1 { errors.append("duplicate_slug:\(slug)") }
        let routingGroups = Dictionary(grouping: entries.filter { $0.publishedExposure == .routing }) { $0.displayName.lowercased() }
        for (name, rows) in routingGroups where rows.count > 1 { errors.append("duplicate_routing_label:\(name)") }

        guard errors.isEmpty else {
            return .init(candidate: nil, errors: errors.sorted(), warnings: warnings.sorted(), changes: changes.sorted())
        }
        return .init(candidate: .init(snapshotID: snapshot.snapshotID, compilerVersion: compilerVersion,
                                      compiledAt: now, entries: entries),
                     errors: [], warnings: warnings.sorted(), changes: changes.sorted())
    }
}

public struct SkillRuntimeExposureGate: Sendable {
    public static let degradedGraceInterval: TimeInterval = 24 * 3600
    public let generation: SkillRuntimeGeneration
    public let emergencyDenylist: Set<String>
    public let freshnessRenewedAt: Date?

    public init(generation: SkillRuntimeGeneration, emergencyDenylist: Set<String> = [],
                freshnessRenewedAt: Date? = nil) {
        self.generation = generation
        self.emergencyDenylist = Set(emergencyDenylist.map(SkillExposureIdentity.normalize))
        self.freshnessRenewedAt = freshnessRenewedAt
    }

    public var freshnessReferenceDate: Date {
        max(generation.compiledAt, freshnessRenewedAt ?? generation.compiledAt)
    }

    public func isDegraded(now: Date = Date()) -> Bool {
        now.timeIntervalSince(freshnessReferenceDate) > Self.degradedGraceInterval
    }

    public func allows(pageID: String, surface: SkillExposureSurface, now: Date = Date()) -> Bool {
        let id = SkillExposureIdentity.normalize(pageID)
        guard !emergencyDenylist.contains(id), let entry = generation.entry(pageID: id) else { return false }
        if isDegraded(now: now) {
            switch surface {
            case .exactFetch, .bodyCache: return true
            case .routing, .command, .specialist: return false
            }
        }
        switch surface {
        case .exactFetch, .bodyCache: return true
        case .routing: return entry.publishedExposure == .routing
        case .command: return entry.publishedExposure == .command
        case .specialist: return entry.publishedExposure != .off
        }
    }
}

public extension SkillExposureBaselineEntry {
    @MainActor
    static func fromSkillsManager(_ manager: SkillsManager) -> [SkillExposureBaselineEntry] {
        manager.skills.compactMap { skill in
            guard skill.enabled, !skill.source.isFile, SkillExposureIdentity.isValid(skill.notionPageId) else { return nil }
            let exposure: SkillRuntimeExposure = skill.inCommandPalette ? .command : (skill.routingDiscoverable ? .routing : .standard)
            return .init(notionPageUUID: skill.notionPageId, displayName: skill.name, exposure: exposure)
        }
    }
}

/// Governed orphan drop for skills deleted in Notion but still present in
/// Bridge local + published Runtime Exposure registries.
///
/// Default reconcile still hard-fails `orphan_local_skill` /
/// `orphan_published_skill`. Operators must name UUIDs after a SKILLS
/// lifecycle decision. A generic sweep never admits HOLD identities.
public enum SkillExposureOrphanPurge {
    /// `outreach-dispatch` — HOLD until SKILLS Keepr restore-vs-retire
    /// (fleet skill sync audit 2026-09-04). Never auto-purge.
    public static let outreachDispatchHoldPageID =
        SkillExposureIdentity.normalize("bcebfc86-3998-4bff-838e-97f15f8ec593")

    public static let holdPageIDs: Set<String> = [outreachDispatchHoldPageID]

    /// Named orphans from the 2026-09-04 fleet receipt
    /// (`97caa4c8-488b-40bd-8234-750b01111f5c`). HOLD is restore-vs-retire.
    public static let fleetOrphans20260904: [(slug: String, pageID: String, hold: Bool)] = [
        ("block-planning", "e7dddd02-c340-4515-80eb-f6a6947d3313", false),
        ("blocks-router", "caeec784-edf8-4219-bf2a-fc91cac1709d", false),
        ("discourse", "23337454-5b9d-46ac-8ec6-e59ce084d094", false),
        ("outreach-dispatch", "bcebfc86-3998-4bff-838e-97f15f8ec593", true),
        ("post-production", "3c813864-1c3a-49a4-9c07-618912184b66", false),
        ("production", "33ecbb58-889e-8195-a374-c84fe4c347fa", false),
    ]

    public struct Classification: Sendable, Equatable {
        public let admitted: [String]
        public let held: [String]
        public let invalid: [String]
    }

    public struct Outcome: Sendable, Equatable {
        public let purgedLocal: [String]
        public let purgedPublished: [String]
        public let held: [String]
        public let notFound: [String]
        public let invalid: [String]
    }

    /// Split requested IDs into admitted / HOLD / invalid. Dedupes.
    public static func classify(_ pageIDs: [String]) -> Classification {
        var admitted: [String] = []
        var held: [String] = []
        var invalid: [String] = []
        var seen = Set<String>()
        for raw in pageIDs {
            guard SkillExposureIdentity.isValid(raw) else {
                invalid.append(raw)
                continue
            }
            let id = SkillExposureIdentity.normalize(raw)
            if seen.contains(id) { continue }
            seen.insert(id)
            if holdPageIDs.contains(id) {
                held.append(id)
            } else {
                admitted.append(id)
            }
        }
        return .init(admitted: admitted, held: held, invalid: invalid)
    }

    /// Generic orphan sweep: admit only valid non-HOLD UUIDs.
    public static func admittedForSweep(_ pageIDs: [String]) -> [String] {
        classify(pageIDs).admitted
    }
}
