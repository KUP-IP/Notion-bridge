// DoctrineSyncModule.swift — Bridge Evolution Contract W1
// TheBridge · Modules · StandingOrders
//
// Request-tier writer for the compiled doctrine-core artifact consumed by
// bridge_initialize v2. This is intentionally the only writer for
// doctrine-core.md in the app surface.

import Foundation
import MCP

public struct DoctrineSyncReport: Codable, Sendable, Equatable {
    public let ok: Bool
    public let doctrineVersion: String
    public let doctrineCorePath: String
    public let tier0Path: String
    public let syncedAt: Date
    public let source: String
}

public struct DoctrineSync: Sendable {
    private struct Metadata: Codable {
        var syncedAt: Date
        var doctrineVersion: String
        var source: String
        var doctrineCoreHash: String
    }

    private let standingOrdersDir: URL
    private let now: @Sendable () -> Date

    public init(
        standingOrdersDir: URL = BridgePaths.applicationSupport(.standingOrders),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.standingOrdersDir = standingOrdersDir
        self.now = now
    }

    public func sync(markdown: String?, doctrineVersion: String? = nil) throws -> DoctrineSyncReport {
        try FileManager.default.createDirectory(at: standingOrdersDir, withIntermediateDirectories: true)
        let snapshot = try StandingOrdersStore.shared.read()
        let trimmedMarkdown = markdown?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usesProvidedMarkdown = trimmedMarkdown?.isEmpty == false
        let sourceMarkdown = usesProvidedMarkdown ? (markdown ?? "") : snapshot.markdown
        let resolvedVersion = doctrineVersion
            ?? StandingOrdersStore.parseDoctrineVersion(from: sourceMarkdown)
            ?? StandingOrdersStore.shared.initializationReport().doctrineVersion

        let doctrineCoreURL = standingOrdersDir.appendingPathComponent(
            ConstitutionStore.doctrineCoreName,
            isDirectory: false
        )
        let tier0URL = standingOrdersDir.appendingPathComponent(
            ConstitutionStore.tier0Name,
            isDirectory: false
        )
        try sourceMarkdown.write(to: doctrineCoreURL, atomically: true, encoding: .utf8)
        if !FileManager.default.fileExists(atPath: tier0URL.path) {
            try Self.tier0Markdown.write(to: tier0URL, atomically: true, encoding: .utf8)
        }

        let syncedAt = now()
        let metadata = Metadata(
            syncedAt: syncedAt,
            doctrineVersion: resolvedVersion,
            source: usesProvidedMarkdown ? "tool.markdown" : "standing-orders/orders.md",
            doctrineCoreHash: StandingOrdersStore.sha256Hex(sourceMarkdown)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(
            to: standingOrdersDir.appendingPathComponent("doctrine-sync.json", isDirectory: false),
            options: .atomic
        )

        return DoctrineSyncReport(
            ok: true,
            doctrineVersion: resolvedVersion,
            doctrineCorePath: doctrineCoreURL.path,
            tier0Path: tier0URL.path,
            syncedAt: syncedAt,
            source: metadata.source
        )
    }

    private static let tier0Markdown = """
    # Tier-0 Constitution

    Protect user sovereignty, local-first execution, truthful state reporting,
    least privilege, and explicit confirmation for irreversible actions.
    """
}

public enum DoctrineSyncModule {
    public static let moduleName = StandingOrdersModule.moduleName
    public static let toolName = "doctrine_sync"

    public static func register(on router: ToolRouter) async {
        await router.register(ToolRegistration(
            name: toolName,
            module: moduleName,
            tier: .request,
            neverAutoApprove: true,
            description: "Refresh the local doctrine-core.md artifact used by bridge_initialize v2. "
                + "This is the single request-tier writer for the doctrine core; without it, "
                + "bridge_initialize returns an interim Quickload capsule.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "markdown": .object([
                        "type": .string("string"),
                        "description": .string("Optional compiled doctrine core markdown. When omitted, the current orders.md body is used.")
                    ]),
                    "doctrineVersion": .object([
                        "type": .string("string"),
                        "description": .string("Optional doctrine version override, e.g. v7.0.2.")
                    ])
                ]),
                "required": .array([])
            ]),
            metadata: ToolMetadata(
                title: "Doctrine Sync",
                whenToUse: [
                    "After editing the authoritative standing-orders doctrine and needing bridge_initialize to return a fresh doctrine core."
                ],
                whenNotToUse: [
                    "Reading initialization state only (use bridge_initialize).",
                    "Editing supplemental standing orders (use standing_orders_save)."
                ],
                relatedTools: ["bridge_initialize", "standing_orders_read"]
            ),
            handler: { arguments in
                let markdown: String? = {
                    guard case .object(let dict) = arguments,
                          case .string(let raw)? = dict["markdown"] else { return nil }
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : raw
                }()
                let version: String? = {
                    guard case .object(let dict) = arguments,
                          case .string(let raw)? = dict["doctrineVersion"] else { return nil }
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }()
                let report = try DoctrineSync().sync(markdown: markdown, doctrineVersion: version)
                return report.value
            }
        ))
    }
}

private extension DoctrineSyncReport {
    var value: Value {
        .object([
            "ok": .bool(ok),
            "tool": .string(DoctrineSyncModule.toolName),
            "doctrineVersion": .string(doctrineVersion),
            "doctrineCorePath": .string(doctrineCorePath),
            "tier0Path": .string(tier0Path),
            "syncedAt": .string(ISO8601DateFormatter().string(from: syncedAt)),
            "source": .string(source),
        ])
    }
}
