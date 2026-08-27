// LaunchReadiness.swift — PKT-1305
// TheBridge · Modules · StandingOrders
//
// Provider-neutral execution-preflight contract. Distinct from PKT-1065C
// intent-sensitive capability probes (declared capability) and from transport
// reachability: those axes must not be conflated with live launch readiness.
//
// Every named check returns exactly one of:
//   PASS              — prerequisite proven ready with evidence
//   BLOCKED           — prerequisite deterministically unavailable/invalid
//   TRANSPORT_UNKNOWN — the evidence path itself is unavailable; product
//                       readiness cannot be concluded (never a false BLOCKED)
//
// `safeToLaunch` is true only when every required check is PASS.
// Probes are injectable seams so fixtures can be hermetic; no live credential
// mutation, no new MCP product surface.

import Foundation

// MARK: - Verdict

public enum LaunchReadinessVerdict: String, Codable, Sendable, Equatable {
    case pass = "PASS"
    case blocked = "BLOCKED"
    case transportUnknown = "TRANSPORT_UNKNOWN"
}

// MARK: - Check + report

public struct LaunchReadinessCheck: Sendable, Equatable, Codable {
    public let name: String
    public let required: Bool
    public let verdict: LaunchReadinessVerdict
    public let evidence: String

    public init(name: String, required: Bool, verdict: LaunchReadinessVerdict, evidence: String) {
        self.name = name
        self.required = required
        self.verdict = verdict
        self.evidence = evidence
    }
}

public struct LaunchReadinessReport: Sendable, Equatable {
    public let checkedAt: Date
    public let checks: [LaunchReadinessCheck]

    public var safeToLaunch: Bool {
        checks.filter(\.required).allSatisfy { $0.verdict == .pass }
    }

    public init(checkedAt: Date, checks: [LaunchReadinessCheck]) {
        self.checkedAt = checkedAt
        self.checks = checks
    }
}

// MARK: - Observation seam

/// One observation of a named prerequisite. The evaluator never infers
/// BLOCKED from a transport failure — that mapping is forbidden.
public enum LaunchReadinessObservation: Sendable, Equatable {
    case ready(evidence: String)
    case unavailable(evidence: String)
    case transportUnknown(evidence: String)

    public var verdict: LaunchReadinessVerdict {
        switch self {
        case .ready: return .pass
        case .unavailable: return .blocked
        case .transportUnknown: return .transportUnknown
        }
    }

    public var evidence: String {
        switch self {
        case .ready(let evidence), .unavailable(let evidence), .transportUnknown(let evidence):
            return evidence
        }
    }
}

public protocol LaunchReadinessSeam: Sendable {
    func observe() async -> LaunchReadinessObservation
}

public protocol LaunchReadinessProbe: Sendable {
    var name: String { get }
    var required: Bool { get }
    func probe() async -> LaunchReadinessCheck
}

public struct NamedLaunchReadinessProbe: LaunchReadinessProbe {
    public let name: String
    public let required: Bool
    private let seam: LaunchReadinessSeam

    public init(name: String, required: Bool = true, seam: LaunchReadinessSeam) {
        self.name = name
        self.required = required
        self.seam = seam
    }

    public func probe() async -> LaunchReadinessCheck {
        let observation = await seam.observe()
        return LaunchReadinessCheck(
            name: name,
            required: required,
            verdict: observation.verdict,
            evidence: observation.evidence
        )
    }
}

// MARK: - Contract evaluator

public enum LaunchReadinessContract {
    public static let commandAuthCheck = "command.auth"
    public static let registryConsumerCheck = "registry.consumer"
    public static let runtimeBrowserCheck = "runtime.browser"
    public static let storageWriteCheck = "storage.write"
    public static let implementationCoverageCheck = "implementation.coverage"

    /// Canonical five-check launch set. Callers inject seams; the names and
    /// required-ness are part of the v4.1 contract.
    public static func standardProbes(
        commandAuth: LaunchReadinessSeam,
        registryConsumer: LaunchReadinessSeam,
        runtimeBrowser: LaunchReadinessSeam,
        storageWrite: LaunchReadinessSeam,
        implementationCoverage: LaunchReadinessSeam
    ) -> [LaunchReadinessProbe] {
        [
            NamedLaunchReadinessProbe(name: commandAuthCheck, seam: commandAuth),
            NamedLaunchReadinessProbe(name: registryConsumerCheck, seam: registryConsumer),
            NamedLaunchReadinessProbe(name: runtimeBrowserCheck, seam: runtimeBrowser),
            NamedLaunchReadinessProbe(name: storageWriteCheck, seam: storageWrite),
            NamedLaunchReadinessProbe(name: implementationCoverageCheck, seam: implementationCoverage),
        ]
    }

    public static func evaluate(
        probes: [LaunchReadinessProbe],
        now: Date = Date()
    ) async -> LaunchReadinessReport {
        var checks: [LaunchReadinessCheck] = []
        checks.reserveCapacity(probes.count)
        for probe in probes {
            checks.append(await probe.probe())
        }
        return LaunchReadinessReport(checkedAt: now, checks: checks)
    }
}

// MARK: - Fixture / injectable seams (hermetic; no live credentials)

/// Deterministic seam used by tests and by Packet Runner fixtures when a live
/// provider is unavailable. Never mutates credentials or accounts.
public struct FixedLaunchReadinessSeam: LaunchReadinessSeam {
    private let observation: LaunchReadinessObservation

    public init(_ observation: LaunchReadinessObservation) {
        self.observation = observation
    }

    public func observe() async -> LaunchReadinessObservation { observation }
}

/// Command/tool availability + authentication readiness.
/// Unauthenticated or missing tool → BLOCKED. Evidence-path failure → TRANSPORT_UNKNOWN.
public struct CommandAuthReadinessSeam: LaunchReadinessSeam {
    public enum AuthState: Sendable, Equatable {
        case authenticated(tool: String)
        case unauthenticated(tool: String)
        case missing(tool: String)
        case evidenceUnavailable(reason: String)
    }

    private let state: AuthState

    public init(_ state: AuthState) {
        self.state = state
    }

    public func observe() async -> LaunchReadinessObservation {
        switch state {
        case .authenticated(let tool):
            return .ready(evidence: "tool \(tool) present and authenticated")
        case .unauthenticated(let tool):
            return .unavailable(evidence: "tool \(tool) present but unauthenticated")
        case .missing(let tool):
            return .unavailable(evidence: "tool \(tool) not registered")
        case .evidenceUnavailable(let reason):
            return .transportUnknown(evidence: reason)
        }
    }
}

/// Registry consumer-contract readiness. Wraps the existing read-only
/// `PacketRegistryPreflight` evaluator. Schema-read failure is TRANSPORT_UNKNOWN,
/// not product BLOCKED.
public struct RegistryConsumerReadinessSeam: LaunchReadinessSeam {
    public enum Input: Sendable {
        case evidenceUnavailable(reason: String)
        case snapshot(config: RegistryConfig, schema: DataSourceSchema)
    }

    private let input: Input

    public init(_ input: Input) {
        self.input = input
    }

    public func observe() async -> LaunchReadinessObservation {
        switch input {
        case .evidenceUnavailable(let reason):
            return .transportUnknown(evidence: reason)
        case .snapshot(let config, let schema):
            let report = PacketRegistryPreflight.evaluate(config: config, schema: schema)
            if report.passes {
                return .ready(evidence:
                    "\(report.contractVersion) PASS classified=\(report.classifiedColumnCount) live=\(report.liveColumnCount)")
            }
            let codes = report.defects.map(\.code).joined(separator: ",")
            return .unavailable(evidence: "\(report.contractVersion) DRIFT codes=\(codes)")
        }
    }
}

/// Browser/runtime availability through a pluggable seam.
public struct RuntimeAvailabilitySeam: LaunchReadinessSeam {
    public enum State: Sendable, Equatable {
        case available(runtime: String)
        case missing(runtime: String)
        case evidenceUnavailable(reason: String)
    }

    private let state: State

    public init(_ state: State) {
        self.state = state
    }

    public func observe() async -> LaunchReadinessObservation {
        switch state {
        case .available(let runtime):
            return .ready(evidence: "runtime \(runtime) reachable")
        case .missing(let runtime):
            return .unavailable(evidence: "runtime \(runtime) missing")
        case .evidenceUnavailable(let reason):
            return .transportUnknown(evidence: reason)
        }
    }
}

/// Storage/writeability readiness through a pluggable seam.
public struct StorageWriteabilitySeam: LaunchReadinessSeam {
    public enum State: Sendable, Equatable {
        case writable(path: String)
        case unavailable(path: String, reason: String)
        case evidenceUnavailable(reason: String)
    }

    private let state: State

    public init(_ state: State) {
        self.state = state
    }

    public func observe() async -> LaunchReadinessObservation {
        switch state {
        case .writable(let path):
            return .ready(evidence: "path \(path) writable")
        case .unavailable(let path, let reason):
            return .unavailable(evidence: "path \(path) not writable: \(reason)")
        case .evidenceUnavailable(let reason):
            return .transportUnknown(evidence: reason)
        }
    }
}

/// Implementation-coverage evidence bound to an inspectable artifact, code
/// path, workflow, or SHA. Missing proof is BLOCKED. Unreadable locator is
/// TRANSPORT_UNKNOWN.
public struct ImplementationCoverageSeam: LaunchReadinessSeam {
    public enum State: Sendable, Equatable {
        case proven(locator: String)
        case missing(expected: String)
        case evidenceUnavailable(reason: String)
    }

    private let state: State

    public init(_ state: State) {
        self.state = state
    }

    public func observe() async -> LaunchReadinessObservation {
        switch state {
        case .proven(let locator):
            return .ready(evidence: "coverage proven at \(locator)")
        case .missing(let expected):
            return .unavailable(evidence: "coverage proof missing: \(expected)")
        case .evidenceUnavailable(let reason):
            return .transportUnknown(evidence: reason)
        }
    }
}
