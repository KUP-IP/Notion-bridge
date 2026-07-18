// CalendarRegistrySyncComposition.swift — disabled internal assembly boundary

import Foundation

public enum CalendarRegistrySyncFeatureState: Sendable, Equatable {
    case disabled(reason: String)
    case enabledForPrivateSmoke
}

public enum CalendarRegistrySyncCompositionError: Error, LocalizedError, Equatable {
    case disabled
    case missingBindings([String])
    case missingAllowedCalendars
    case unsupportedCoordinatorLocation(String)

    public var errorDescription: String? {
        switch self {
        case .disabled:
            return "Calendar–Registry Sync is disabled; no public tool or production activation exists"
        case .missingBindings(let keys):
            return "schedule registry is missing required bindings: \(keys.joined(separator: ", "))"
        case .missingAllowedCalendars:
            return "an explicit private-smoke calendar allowlist is required"
        case .unsupportedCoordinatorLocation(let path):
            return "calendar-registry coordinator must use a verified local filesystem: \(path)"
        }
    }
}

public enum CalendarRegistrySyncComposition {
    public static let enableEnvironmentKey = "BRIDGE_INTERNAL_CALENDAR_REGISTRY_SYNC"
    public static let allowedCalendarsEnvironmentKey = "BRIDGE_INTERNAL_CALENDAR_REGISTRY_ALLOWED_CALENDARS"
    public static let canonicalCoordinatorDirectory = BridgePaths.applicationSupport(.registry)
        .appendingPathComponent("calendar-registry-coordinator", isDirectory: true)
    public static let canonicalLedgerURL = canonicalCoordinatorDirectory
        .appendingPathComponent("transactions.sqlite3")

    public static func featureState(environment: [String: String]) -> CalendarRegistrySyncFeatureState {
        environment[enableEnvironmentKey] == "1"
            ? .enabledForPrivateSmoke
            : .disabled(reason: "set only for an isolated private smoke fixture")
    }

    public static func build(
        entity: RegistryEntity,
        registryGateway: any RegistryNotionGateway,
        calendarStore: any CalendarStoring,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowedCalendarIds: Set<String>? = nil
    ) throws -> CalendarRegistrySyncEngine {
        guard featureState(environment: environment) == .enabledForPrivateSmoke else {
            throw CalendarRegistrySyncCompositionError.disabled
        }
        let missing = CalendarRegistrySyncEngine.requiredScheduleCanonicalFields
            .filter { entity.property($0)?.isBound != true }
            .sorted()
        guard missing.isEmpty else {
            throw CalendarRegistrySyncCompositionError.missingBindings(missing)
        }
        let parsed = Set((environment[allowedCalendarsEnvironmentKey] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        let allowlist = allowedCalendarIds ?? parsed
        guard !allowlist.isEmpty else {
            throw CalendarRegistrySyncCompositionError.missingAllowedCalendars
        }
        let parent: URL
        do {
            parent = try CalendarRegistryCoordinatorTrust.prepareDirectory(
                canonicalCoordinatorDirectory
            ).url
        } catch {
            throw CalendarRegistrySyncCompositionError.unsupportedCoordinatorLocation(
                "\(canonicalCoordinatorDirectory.path): \(error.localizedDescription)"
            )
        }
        let standardizedLedger = parent.appendingPathComponent("transactions.sqlite3")
        let lockRoot = parent.appendingPathComponent("locks", isDirectory: true)
        return CalendarRegistrySyncEngine(
            registry: NotionTimeInstanceRegistryStore(entity: entity, gateway: registryGateway),
            calendar: CalendarStoringSyncProvider(
                store: calendarStore,
                allowlistedCalendarIds: allowlist
            ),
            transactions: try SQLiteCalendarRegistryTransactionStore(url: standardizedLedger),
            processLocks: try FileCalendarRegistryProcessLockCoordinator(rootURL: lockRoot)
        )
    }
}
