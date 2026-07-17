// CalendarRegistrySyncComposition.swift — disabled internal assembly boundary

import Foundation

public enum CalendarRegistrySyncFeatureState: Sendable, Equatable {
    case disabled(reason: String)
    case enabledForPrivateSmoke
}

public enum CalendarRegistrySyncCompositionError: Error, LocalizedError, Equatable {
    case disabled
    case missingBindings([String])

    public var errorDescription: String? {
        switch self {
        case .disabled:
            return "Calendar–Registry Sync is disabled; no public tool or production activation exists"
        case .missingBindings(let keys):
            return "schedule registry is missing required bindings: \(keys.joined(separator: ", "))"
        }
    }
}

public enum CalendarRegistrySyncComposition {
    public static let enableEnvironmentKey = "BRIDGE_INTERNAL_CALENDAR_REGISTRY_SYNC"

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
        journalURL: URL = BridgePaths.applicationSupport(.registry)
            .appendingPathComponent("calendar-registry-transactions.json")
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
        return CalendarRegistrySyncEngine(
            registry: NotionTimeInstanceRegistryStore(entity: entity, gateway: registryGateway),
            calendar: CalendarStoringSyncProvider(store: calendarStore),
            transactions: try JSONCalendarRegistryTransactionStore(url: journalURL)
        )
    }
}
