// ConstitutionStore.swift — Bridge Evolution Contract W1
// TheBridge · Modules · StandingOrders
//
// Builds the v2 bridge_initialize constitution bundle from the live kernel
// stores. The bundle is read-only evidence: it never edits doctrine, standing
// orders, or commands.

import Foundation

public enum ConstitutionFreshness: String, Codable, Sendable, Equatable {
    case fresh
    case stale
    case interim
}

public struct ConstitutionStandingOrder: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let scope: StandingOrderScope
    public let updatedAt: Date
    public let body: String

    public init(id: String, title: String, scope: StandingOrderScope, updatedAt: Date, body: String) {
        self.id = id
        self.title = title
        self.scope = scope
        self.updatedAt = updatedAt
        self.body = body
    }
}

public struct ConstitutionCommandIndexEntry: Codable, Sendable, Equatable {
    public let slug: String
    public let name: String
    public let keySlot: Int?
    public let icon: String

    public init(slug: String, name: String, keySlot: Int?, icon: String) {
        self.slug = slug
        self.name = name
        self.keySlot = keySlot
        self.icon = icon
    }
}

public struct ConstitutionBundle: Codable, Sendable, Equatable {
    public let tier0: String
    public let doctrineCore: String
    public let doctrineFreshness: ConstitutionFreshness
    public let doctrineVersion: String
    public let orders: [ConstitutionStandingOrder]
    public let commandsIndex: [ConstitutionCommandIndexEntry]
    public let routingRoster: String

    public init(
        tier0: String,
        doctrineCore: String,
        doctrineFreshness: ConstitutionFreshness,
        doctrineVersion: String,
        orders: [ConstitutionStandingOrder],
        commandsIndex: [ConstitutionCommandIndexEntry],
        routingRoster: String
    ) {
        self.tier0 = tier0
        self.doctrineCore = doctrineCore
        self.doctrineFreshness = doctrineFreshness
        self.doctrineVersion = doctrineVersion
        self.orders = orders
        self.commandsIndex = commandsIndex
        self.routingRoster = routingRoster
    }
}

public struct ConstitutionStore: Sendable {
    public static let doctrineCoreName = "doctrine-core.md"
    public static let tier0Name = "tier0.md"
    public static let staleAfter: TimeInterval = 60 * 60 * 24 * 7

    private let standingOrdersDir: URL
    private let now: @Sendable () -> Date

    public init(
        standingOrdersDir: URL = BridgePaths.applicationSupport(.standingOrders),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.standingOrdersDir = standingOrdersDir
        self.now = now
    }

    public func assemble(
        supplementalStore: StandingOrdersRecordStore = .shared,
        commandStore: CommandStore = .shared
    ) async throws -> ConstitutionBundle {
        try StandingOrdersStore.shared.ensureInitializationContract()
        let report = StandingOrdersStore.shared.initializationReport()
        let liveMarkdown = (try? StandingOrdersStore.shared.read().markdown) ?? ""
        let doctrineVersion = StandingOrdersStore.parseDoctrineVersion(from: liveMarkdown)
            ?? report.doctrineVersion

        let tier0 = readMarkdown(named: Self.tier0Name)
            ?? Self.interimTier0
        let doctrineCoreResult = readDoctrineCore()

        let summaries = await supplementalStore.list(includeArchived: false)
        var orders: [ConstitutionStandingOrder] = []
        for summary in summaries where !BridgeInitializeService.isIgnoredOrder(
            title: summary.title,
            archived: summary.archived
        ) {
            guard let record = await supplementalStore.read(id: summary.id) else { continue }
            orders.append(ConstitutionStandingOrder(
                id: record.id,
                title: record.title,
                scope: record.scope,
                updatedAt: record.updatedAt,
                body: record.body
            ))
        }

        let commands = try commandStore.list().map { command in
            ConstitutionCommandIndexEntry(
                slug: command.slug,
                name: command.name,
                keySlot: command.keySlot,
                icon: Self.iconDescription(command.icon)
            )
        }

        return ConstitutionBundle(
            tier0: tier0,
            doctrineCore: doctrineCoreResult.markdown,
            doctrineFreshness: doctrineCoreResult.freshness,
            doctrineVersion: doctrineVersion,
            orders: orders,
            commandsIndex: commands,
            routingRoster: SkillsModule.buildRoutingInstructions()
        )
    }

    private func readDoctrineCore() -> (markdown: String, freshness: ConstitutionFreshness) {
        let url = standingOrdersDir.appendingPathComponent(Self.doctrineCoreName, isDirectory: false)
        guard let markdown = try? String(contentsOf: url, encoding: .utf8),
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return (Self.interimDoctrineCore, .interim)
        }
        let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { $0[.modificationDate] as? Date }
        guard let modifiedAt else { return (markdown, .stale) }
        return (markdown, now().timeIntervalSince(modifiedAt) > Self.staleAfter ? .stale : .fresh)
    }

    private func readMarkdown(named fileName: String) -> String? {
        let supportURL = standingOrdersDir.appendingPathComponent(fileName, isDirectory: false)
        if let support = try? String(contentsOf: supportURL, encoding: .utf8),
           !support.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return support
        }
        guard let resource = Bundle.module.url(
            forResource: fileName.replacingOccurrences(of: ".md", with: ""),
            withExtension: "md",
            subdirectory: "standing-orders"
        ) else {
            return nil
        }
        return try? String(contentsOf: resource, encoding: .utf8)
    }

    private static func iconDescription(_ icon: CommandStore.Icon) -> String {
        switch icon {
        case .emoji(let value): return value
        case .symbol(let value): return "symbol:\(value)"
        }
    }

    private static let interimTier0 = """
    # Tier-0 Constitution

    Tier-0 is the durable root: protect user sovereignty, local-first execution,
    truthful state reporting, and approval-gated destructive action.
    """

    private static let interimDoctrineCore = """
    # Quickload Doctrine Core

    Quickload interim capsule: call bridge_initialize first, treat live source
    state as authoritative, route from the active routing roster, preserve
    user-authored standing orders and commands, and surface uncertainty instead
    of inventing completion.
    """
}
