// CommandStore.swift — public command API backed by durable local custody.
//
// Schema v2 separates application-owned product defaults from revisioned
// operator state. `CommandCustodyBackend` handles immutable identities,
// migration from the v1 index-plus-markdown layout, activation, validation,
// recovery, and body isolation. This façade deliberately preserves the
// established UI/MCP API while exposing immutable command IDs in responses.

import Foundation

public final class CommandStore: @unchecked Sendable {
    public static let shared = CommandStore()

    /// Schema-v1 CommandStore identified built-ins by their mutable display
    /// slug. This is the complete, closed mapping for the production v1
    /// palette. The values are durable identities; neither a renamed command
    /// nor a changed body can alter them.
    public static let legacyBuiltInIdentityMap: [String: String] = [
        "initiate": "bridge.command.builtin.initiate",
        "propose": "bridge.command.builtin.propose",
        "scope-cut": "bridge.command.builtin.scope-cut",
        "validate": "bridge.command.builtin.validate",
        "execute": "bridge.command.builtin.execute",
        "review": "bridge.command.builtin.review",
        "refocus": "bridge.command.builtin.refocus",
        "open-loops": "bridge.command.builtin.open-loops",
        "close-agent": "bridge.command.builtin.close-agent",
        "hand-off": "bridge.command.builtin.hand-off",
    ]

    /// Product defaults are supplied by the application bundle. They are read
    /// as an authority layer and are never written into an operator's local
    /// custody store merely because the application is replaced.
    ///
    /// A1 metadata (`schemaVersion`, `behaviorVersion`, `requiredCapabilities`)
    /// is structured catalog evidence. Wording lives in `body` and never
    /// participates in compatibility gating.
    public struct ProductDefault: Equatable, Sendable {
        public static let currentCatalogSchemaVersion = 1
        public static let currentCatalogBehaviorVersion = 2

        public var id: String
        public var slug: String
        public var name: String
        public var icon: Icon
        public var color: NotionColor?
        public var initialKeySlot: Int?
        public var body: String
        public var schemaVersion: Int
        public var behaviorVersion: Int
        public var requiredCapabilities: [String]

        public init(
            id: String,
            slug: String,
            name: String,
            icon: Icon,
            color: NotionColor? = nil,
            initialKeySlot: Int? = nil,
            body: String,
            schemaVersion: Int = ProductDefault.currentCatalogSchemaVersion,
            behaviorVersion: Int = ProductDefault.currentCatalogBehaviorVersion,
            requiredCapabilities: [String] = []
        ) {
            self.id = id
            self.slug = slug
            self.name = name
            self.icon = icon
            self.color = color
            self.initialKeySlot = initialKeySlot
            self.body = body
            self.schemaVersion = schemaVersion
            self.behaviorVersion = behaviorVersion
            self.requiredCapabilities = requiredCapabilities
        }
    }

    /// Settings-facing update class. Compatibility-required is the only class
    /// that closes the execution gate, and only from schema/capability evidence.
    public enum UpdateClassification: String, Sendable, Equatable {
        case current
        case editorial
        case behavioral
        case compatibilityRequired
    }

    public enum ExecutionGate: Sendable, Equatable {
        case open
        case compatibilityRequired(evidence: String)
    }

    public enum ReconciliationField: String, Sendable, Equatable {
        case name
        case icon
        case color
        case body
    }

    public enum ReconciliationSource: String, Sendable, Equatable {
        case base
        case incoming
    }

    /// Explicit operator actions. There is no automatic natural-language body
    /// merge path; `copySelectedChange` copies one whole field.
    public enum ReconciliationAction: Sendable, Equatable {
        case restoreBase
        case adoptIncoming
        case copySelectedChange(source: ReconciliationSource, field: ReconciliationField)
    }

    /// Base = last-adopted product default. Local = operator override.
    /// Incoming = current application catalog entry. Unmodified commands have
    /// no local override; incoming is the effective body.
    public struct CommandReconciliation: Equatable, Sendable {
        public var commandID: String
        public var slug: String
        public var base: ProductDefault?
        public var local: Command?
        public var incoming: ProductDefault
        public var classification: UpdateClassification
        public var updateAvailable: Bool
        public var executionGate: ExecutionGate
    }

    /// Deterministic fault points used only by the custody regression suite.
    /// They model process interruption without relying on timing.
    public enum TestFaultPoint: Sendable, Equatable {
        case beforeRevisionFinalize
        case beforeActivation
    }

    private let custody: CommandCustodyBackend

    /// The default initializer remains dynamic with BridgePaths so existing
    /// temporary-home tests and the production shared instance keep their
    /// established behaviour. A fixed root is available for isolated custody
    /// fixture tests.
    public init(
        storageRoot: URL? = nil,
        productDefaults: [ProductDefault]? = nil
    ) {
        self.custody = CommandCustodyBackend(
            storageRoot: storageRoot,
            productDefaults: productDefaults
        )
    }

    // MARK: - Public model

    public struct Command: Equatable, Sendable, Codable {
        /// Stable command identity. Legacy Codable payloads that predate this
        /// field decode as an empty ID and receive custody during migration.
        public var id: String
        public var slug: String           // derived from name; immutable post-create
        public var name: String           // display name
        public var icon: Icon
        public var color: NotionColor?    // applies only when icon is .symbol
        public var keySlot: Int?          // 0…9, or nil
        public var lastUsedAt: Date?
        public var body: String           // markdown payload

        public init(
            id: String = "",
            slug: String,
            name: String,
            icon: Icon,
            color: NotionColor? = nil,
            keySlot: Int? = nil,
            lastUsedAt: Date? = nil,
            body: String
        ) {
            self.id = id
            self.slug = slug
            self.name = name
            self.icon = icon
            self.color = color
            self.keySlot = keySlot
            self.lastUsedAt = lastUsedAt
            self.body = body
        }

        private enum CodingKeys: String, CodingKey {
            case id, slug, name, icon, color, keySlot, lastUsedAt, body
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
            self.slug = try values.decode(String.self, forKey: .slug)
            self.name = try values.decode(String.self, forKey: .name)
            self.icon = try values.decode(Icon.self, forKey: .icon)
            self.color = try values.decodeIfPresent(NotionColor.self, forKey: .color)
            self.keySlot = try values.decodeIfPresent(Int.self, forKey: .keySlot)
            self.lastUsedAt = try values.decodeIfPresent(Date.self, forKey: .lastUsedAt)
            self.body = try values.decode(String.self, forKey: .body)
        }
    }

    /// Two icon kinds; first-class enum so the editor + popup can render
    /// the right glyph without sniffing strings.
    public enum Icon: Equatable, Sendable, Codable {
        case emoji(String)
        case symbol(String) // SF Symbol name

        public var displayHint: String {
            switch self {
            case .emoji(let s): return s
            case .symbol(let n): return "⌘\(n)"
            }
        }
    }

    public enum NotionColor: String, CaseIterable, Sendable, Codable {
        case gray, brown, orange, yellow, green, blue, purple, pink, red
    }

    public enum StoreError: Error, LocalizedError {
        case slugTaken(String)
        case slugNotFound(String)
        case invalidName(String)
        case slotOutOfRange(Int)
        case legacyIdentityAmbiguous(String)
        case corruptRevision(String)
        case injectedFailure(TestFaultPoint)
        case ioFailure(underlying: Error)
        case adoptedBaseMissing(String)
        case reconciliationNotApplicable(String)

        public var errorDescription: String? {
            switch self {
            case .slugTaken(let s): return "A command with slug '\(s)' already exists."
            case .slugNotFound(let s): return "No command with slug '\(s)'."
            case .invalidName(let n): return "Invalid command name: '\(n)'."
            case .slotOutOfRange(let s): return "Key slot must be 0–9 (got \(s))."
            case .legacyIdentityAmbiguous(let detail):
                return "Legacy command migration stopped safely: \(detail)"
            case .corruptRevision(let detail):
                return "Command custody revision is corrupt: \(detail)"
            case .injectedFailure(let point):
                return "Injected command custody failure at \(point)."
            case .ioFailure(let e): return "Command store I/O failed: \(e.localizedDescription)"
            case .adoptedBaseMissing(let s):
                return "No adopted product-default base is on file for '\(s)'."
            case .reconciliationNotApplicable(let s):
                return "Product-default reconciliation does not apply to '\(s)'."
            }
        }
    }

    // MARK: - Lifecycle

    public func resetForTesting() throws {
        try custody.resetForTesting()
    }

    /// First-run seed: populate the 10-slot Command Bridge palette if the
    /// store is empty. Idempotent.
    public func seedIfEmpty() throws {
        try custody.seedIfEmpty()
    }

    // MARK: - List / read

    /// All commands, sorted by lastUsedAt desc (most-recent first); names
    /// without lastUsedAt sort alphabetically at the end.
    public func list() throws -> [Command] {
        try custody.list()
    }

    public func get(slug: String) throws -> Command? {
        try custody.get(slug: slug)
    }

    /// Substring match on name. Recency-sorted (matching the popup spec).
    public func search(_ query: String) throws -> [Command] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return try list() }
        return try list().filter { $0.name.lowercased().contains(q) }
    }

    /// Returns the command currently bound to a given 0–9 slot, if any.
    public func command(forKeySlot slot: Int) throws -> Command? {
        try list().first(where: { $0.keySlot == slot })
    }

    // MARK: - Mutations

    @discardableResult
    public func create(
        name: String,
        icon: Icon,
        color: NotionColor? = nil,
        body: String,
        keySlot: Int? = nil
    ) throws -> Command {
        try custody.create(
            name: name,
            icon: icon,
            color: color,
            body: body,
            keySlot: keySlot
        )
    }

    @discardableResult
    public func update(_ command: Command) throws -> Command {
        try custody.update(command)
    }

    public func delete(slug: String) throws {
        try custody.delete(slug: slug)
    }

    /// Reassign (or clear) a command's key slot. Atomically evicts any
    /// other command currently holding the target slot.
    public func setKeySlot(slug: String, slot: Int?) throws {
        try custody.setKeySlot(slug: slug, slot: slot)
    }

    /// Stamp lastUsedAt to now. Called when the command fires from the popup.
    public func recordUse(slug: String, at when: Date = Date()) throws {
        try custody.recordUse(slug: slug, at: when)
    }

    // MARK: - Product-default reconciliation (A1)

    public func reconciliations() throws -> [CommandReconciliation] {
        try custody.reconciliations()
    }

    public func reconciliation(slug: String) throws -> CommandReconciliation? {
        try custody.reconciliation(slug: slug)
    }

    @discardableResult
    public func applyReconciliation(
        slug: String,
        action: ReconciliationAction
    ) throws -> CommandReconciliation {
        try custody.applyReconciliation(slug: slug, action: action)
    }

    public func executionGate(slug: String) throws -> ExecutionGate {
        try custody.executionGate(slug: slug)
    }

    // MARK: - Slugification

    /// Lower-case, replace whitespace runs with `-`, strip to ASCII [a-z0-9_-].
    /// v3.6·6 audit: locked to ASCII (was `CharacterSet.lowercaseLetters` =
    /// Unicode Ll). Cyrillic 'а' (U+0430) is visually identical to ASCII 'a'
    /// — accepting both would let two visually-identical command names
    /// produce different slugs, bypassing the duplicate-slug check.
    public static func slugify(_ name: String) -> String {
        let lower = name.lowercased()
        let collapsed = lower.split(whereSeparator: { $0.isWhitespace }).joined(separator: "-")
        let filtered = collapsed.unicodeScalars.filter { scalar in
            let v = scalar.value
            let isAsciiLower = v >= 0x61 && v <= 0x7A   // a-z
            let isAsciiDigit = v >= 0x30 && v <= 0x39   // 0-9
            return isAsciiLower || isAsciiDigit || scalar == "-" || scalar == "_"
        }
        return String(String.UnicodeScalarView(filtered))
    }

    /// The repository-owned default layer. B0 bodies are directional goal
    /// conditions; A0 identities and A1 metadata stay on this façade.
    public static var defaultProductCatalog: [ProductDefault] {
        CommandProductCatalog.defaults
    }

    /// A byte-for-byte representative of the pre-A0 production store: the
    /// legacy index format carried no immutable ID and kept each body in an
    /// adjacent markdown file.
    public static var currentLegacyProductionFixture: [Command] {
        defaultProductCatalog.map {
            Command(
                id: "",
                slug: $0.slug,
                name: $0.name,
                icon: $0.icon,
                color: $0.color,
                keySlot: $0.initialKeySlot,
                lastUsedAt: nil,
                body: $0.body
            )
        }
    }

    // MARK: - Custody test seams

    public func installLegacyFixtureForTesting(_ commands: [Command]) throws {
        try custody.installLegacyFixtureForTesting(commands)
    }

    public func setFaultPointForTesting(_ fault: TestFaultPoint?) {
        custody.setFaultPointForTesting(fault)
    }

    public func activeRevisionIDForTesting() throws -> String? {
        try custody.activeRevisionIDForTesting()
    }

    public func custodyRootForTesting() -> URL {
        custody.custodyRootForTesting()
    }

    public func legacyBodyDataForTesting(slug: String) throws -> Data {
        try custody.legacyBodyDataForTesting(slug: slug)
    }

    public func activeBodyDataForTesting(commandID: String) throws -> Data {
        try custody.activeBodyDataForTesting(commandID: commandID)
    }

    public func corruptActiveBodyForTesting(commandID: String) throws {
        try custody.corruptActiveBodyForTesting(commandID: commandID)
    }

    public func stateDataForTesting() throws -> Data? {
        try custody.stateDataForTesting()
    }
}

// MARK: - Sort by recency

extension Array where Element == CommandStore.Command {
    func sortedByRecency() -> [CommandStore.Command] {
        sorted { a, b in
            switch (a.lastUsedAt, b.lastUsedAt) {
            case let (.some(da), .some(db)): return da > db
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }
}
