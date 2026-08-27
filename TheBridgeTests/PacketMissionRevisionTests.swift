import Foundation
import TheBridgeLib

func runPacketMissionRevisionTests() async {
    print("\n📜 PacketMissionRevision (PJT-2770 · governed transaction / partial_ambiguous)")

    func sampleMission(
        objective: String = "Ship the floor",
        blockedByIds: [String] = []
    ) -> PacketMissionRevision.Mission {
        PacketMissionRevision.Mission(
            name: "PKT-1234",
            title: "Integration",
            objective: objective,
            sourceOfTruth: "hub",
            executionClass: "REVIEW-FIRST",
            projectIds: ["proj-1"],
            skillIds: ["skill-1"],
            blockedByIds: blockedByIds,
            bodyCanonical: "## Objective\nShip the floor"
        )
    }

    await test("Mission revision: idempotent apply writes nothing") {
        let mission = sampleMission()
        let current = PacketMissionRevision.State.hashed(packetId: "pkt-1", mission: mission, revision: 3)
        let result = PacketMissionRevision.apply(.init(
            current: current, proposed: mission,
            expectedHash: current.hash, expectedRevision: 3
        ))
        try expect(result.outcome == .applied)
        try expect(result.reason == "idempotent")
        try expect(!result.appliedWrites)
        try expect(result.state.revision == 3)
        try expect(result.state.hash == current.hash)
    }

    await test("Mission revision: stale hash returns partial_ambiguous and keeps current state") {
        let mission = sampleMission()
        let current = PacketMissionRevision.State.hashed(packetId: "pkt-1", mission: mission, revision: 3)
        var proposed = mission
        proposed.objective = "Different"
        let result = PacketMissionRevision.apply(.init(
            current: current, proposed: proposed,
            expectedHash: "stale", expectedRevision: 3
        ))
        try expect(result.outcome == .partialAmbiguous)
        try expect(!result.appliedWrites)
        try expect(result.state == current)
    }

    await test("Mission revision: self blockedBy is blocked") {
        let mission = sampleMission()
        let current = PacketMissionRevision.State.hashed(packetId: "pkt-1", mission: mission, revision: 1)
        var proposed = mission
        proposed.blockedByIds = ["pkt-1"]
        let result = PacketMissionRevision.apply(.init(
            current: current, proposed: proposed,
            expectedHash: current.hash, expectedRevision: 1,
            reciprocalBlockingKnown: true, reciprocalBlockingConsistent: true
        ))
        try expect(result.outcome == .blocked)
        try expect(!result.appliedWrites)
        try expect(result.reason.contains("self"))
    }

    await test("Mission revision: unknown reciprocal Blocking is partial_ambiguous") {
        let mission = sampleMission()
        let current = PacketMissionRevision.State.hashed(packetId: "pkt-1", mission: mission, revision: 1)
        var proposed = mission
        proposed.blockedByIds = ["pkt-2"]
        let result = PacketMissionRevision.apply(.init(
            current: current, proposed: proposed,
            expectedHash: current.hash, expectedRevision: 1,
            reciprocalBlockingKnown: false, reciprocalBlockingConsistent: false
        ))
        try expect(result.outcome == .partialAmbiguous)
        try expect(!result.appliedWrites)
        try expect(result.reason.contains("reciprocal"))
    }

    await test("Mission revision: inconsistent reciprocal Blocking is blocked") {
        let mission = sampleMission()
        let current = PacketMissionRevision.State.hashed(packetId: "pkt-1", mission: mission, revision: 1)
        var proposed = mission
        proposed.blockedByIds = ["pkt-2"]
        let result = PacketMissionRevision.apply(.init(
            current: current, proposed: proposed,
            expectedHash: current.hash, expectedRevision: 1,
            reciprocalBlockingKnown: true, reciprocalBlockingConsistent: false
        ))
        try expect(result.outcome == .blocked)
        try expect(!result.appliedWrites)
    }

    await test("Mission revision: objective change applies as one revision+hash write") {
        let mission = sampleMission()
        let current = PacketMissionRevision.State.hashed(packetId: "pkt-1", mission: mission, revision: 4)
        var proposed = mission
        proposed.objective = "Close PJT-2770"
        let result = PacketMissionRevision.apply(.init(
            current: current, proposed: proposed,
            expectedHash: current.hash, expectedRevision: 4
        ))
        try expect(result.outcome == .applied)
        try expect(result.appliedWrites)
        try expect(result.state.revision == 5)
        try expect(result.state.hash == PacketMissionRevision.hash(proposed))
        try expect(result.state.hash != current.hash)
        try expect(result.state.mission.objective == "Close PJT-2770")
    }
}
