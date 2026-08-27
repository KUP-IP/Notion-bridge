// PacketMissionRevision.swift — PJT-2770 DoD 4
// TheBridge · Modules · Registry
//
// Governed packet mission/dependency revision. Apply is one transaction:
// either the next revision+hash is produced, or the call returns
// `partial_ambiguous` / `blocked` and writes nothing.
//
// Hash membership follows A0: operator-owned mission fields only. Controller
// mutable fields (Status, Packet Output, timestamps, tokens, …) are excluded.

import Foundation

public enum PacketMissionRevision {
    public static let contractVersion = "packet-mission-revision-v1"

    public enum Outcome: String, Sendable, Equatable {
        case applied
        case partialAmbiguous = "partial_ambiguous"
        case blocked
    }

    public struct Mission: Sendable, Equatable {
        public var name: String
        public var title: String
        public var objective: String
        public var sourceOfTruth: String
        public var executionClass: String
        public var projectIds: [String]
        public var skillIds: [String]
        public var blockedByIds: [String]
        public var bodyCanonical: String

        public init(
            name: String,
            title: String,
            objective: String,
            sourceOfTruth: String,
            executionClass: String,
            projectIds: [String],
            skillIds: [String],
            blockedByIds: [String],
            bodyCanonical: String
        ) {
            self.name = name
            self.title = title
            self.objective = objective
            self.sourceOfTruth = sourceOfTruth
            self.executionClass = executionClass
            self.projectIds = projectIds
            self.skillIds = skillIds
            self.blockedByIds = blockedByIds
            self.bodyCanonical = bodyCanonical
        }
    }

    public struct State: Sendable, Equatable {
        public var packetId: String
        public var mission: Mission
        public var revision: Int
        public var hash: String

        public init(packetId: String, mission: Mission, revision: Int, hash: String) {
            self.packetId = packetId
            self.mission = mission
            self.revision = revision
            self.hash = hash
        }

        public static func hashed(packetId: String, mission: Mission, revision: Int) -> State {
            State(packetId: packetId, mission: mission, revision: revision, hash: PacketMissionRevision.hash(mission))
        }
    }

    public struct Request: Sendable {
        public var current: State
        public var proposed: Mission
        public var expectedHash: String
        public var expectedRevision: Int
        /// False when Blocked-by changed but the reciprocal Blocking graph
        /// cannot be read in the same transaction.
        public var reciprocalBlockingKnown: Bool
        public var reciprocalBlockingConsistent: Bool

        public init(
            current: State,
            proposed: Mission,
            expectedHash: String,
            expectedRevision: Int,
            reciprocalBlockingKnown: Bool = true,
            reciprocalBlockingConsistent: Bool = true
        ) {
            self.current = current
            self.proposed = proposed
            self.expectedHash = expectedHash
            self.expectedRevision = expectedRevision
            self.reciprocalBlockingKnown = reciprocalBlockingKnown
            self.reciprocalBlockingConsistent = reciprocalBlockingConsistent
        }
    }

    public struct Result: Sendable, Equatable {
        public var outcome: Outcome
        public var reason: String
        public var state: State
        public var appliedWrites: Bool

        public init(outcome: Outcome, reason: String, state: State, appliedWrites: Bool) {
            self.outcome = outcome
            self.reason = reason
            self.state = state
            self.appliedWrites = appliedWrites
        }
    }

    public static func hash(_ mission: Mission) -> String {
        CalendarRegistryDigest.sha256(canonicalJSON(mission))
    }

    public static func apply(_ request: Request) -> Result {
        if request.expectedHash != request.current.hash {
            return Result(
                outcome: .partialAmbiguous,
                reason: "expectedHash does not match current.hash",
                state: request.current,
                appliedWrites: false
            )
        }
        if request.expectedRevision != request.current.revision {
            return Result(
                outcome: .partialAmbiguous,
                reason: "expectedRevision does not match current.revision",
                state: request.current,
                appliedWrites: false
            )
        }
        if request.proposed.blockedByIds.contains(request.current.packetId) {
            return Result(
                outcome: .blocked,
                reason: "blockedBy contains self",
                state: request.current,
                appliedWrites: false
            )
        }
        let blockedByChanged = normalized(request.proposed.blockedByIds)
            != normalized(request.current.mission.blockedByIds)
        if blockedByChanged && !request.reciprocalBlockingKnown {
            return Result(
                outcome: .partialAmbiguous,
                reason: "blockedBy changed but reciprocal Blocking graph is unknown",
                state: request.current,
                appliedWrites: false
            )
        }
        if blockedByChanged && !request.reciprocalBlockingConsistent {
            return Result(
                outcome: .blocked,
                reason: "blockedBy change is not reciprocal with Blocking",
                state: request.current,
                appliedWrites: false
            )
        }

        let proposed = normalized(request.proposed)
        if proposed == normalized(request.current.mission) {
            return Result(
                outcome: .applied,
                reason: "idempotent",
                state: request.current,
                appliedWrites: false
            )
        }

        let next = State(
            packetId: request.current.packetId,
            mission: proposed,
            revision: request.current.revision + 1,
            hash: hash(proposed)
        )
        return Result(
            outcome: .applied,
            reason: "mission revised",
            state: next,
            appliedWrites: true
        )
    }

    private static func normalized(_ ids: [String]) -> [String] {
        Array(Set(ids.filter { !$0.isEmpty })).sorted()
    }

    private static func normalized(_ mission: Mission) -> Mission {
        Mission(
            name: mission.name,
            title: mission.title,
            objective: mission.objective,
            sourceOfTruth: mission.sourceOfTruth,
            executionClass: mission.executionClass,
            projectIds: normalized(mission.projectIds),
            skillIds: normalized(mission.skillIds),
            blockedByIds: normalized(mission.blockedByIds),
            bodyCanonical: mission.bodyCanonical
        )
    }

    private static func canonicalJSON(_ mission: Mission) -> String {
        let object: [String: Any] = [
            "bodyCanonical": mission.bodyCanonical,
            "blockedByIds": normalized(mission.blockedByIds),
            "executionClass": mission.executionClass,
            "name": mission.name,
            "objective": mission.objective,
            "projectIds": normalized(mission.projectIds),
            "skillIds": normalized(mission.skillIds),
            "sourceOfTruth": mission.sourceOfTruth,
            "title": mission.title,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
