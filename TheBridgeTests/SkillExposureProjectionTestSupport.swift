// SkillExposureProjectionTestSupport.swift — hermetic Runtime Exposure projection fixtures
// TheBridge · Tests

import Foundation
import MCP
@_spi(Testing) import TheBridgeLib

@Sendable
func isolatedRegistryProvider(
    suiteName: String,
    storageKey: String = BridgeDefaults.skills,
    exposureGate: SkillRuntimeExposureGate? = nil
) -> RegistrySkillsCommandProvider {
    RegistrySkillsCommandProvider(
        suiteName: suiteName,
        storageKey: storageKey,
        exposureGate: exposureGate
    )
}

func mergedRoutingSkillsForTesting(
    exposureGate: SkillRuntimeExposureGate?
) async -> [Value] {
    await SkillsModule.mergedRoutingSkills(exposureGate: exposureGate)
}

func testExposureGate(
    _ entries: [(pageID: String, exposure: SkillRuntimeExposure)],
    compiledAt: Date = Date()
) -> SkillRuntimeExposureGate {
    let manifest = entries.enumerated().map { index, item in
        SkillPublishedManifestEntry(
            notionPageUUID: item.pageID,
            displayName: "Fixture \(index)",
            slug: "fixture-\(index)-\(SkillExposureIdentity.normalize(item.pageID))",
            desiredExposure: item.exposure,
            publishedExposure: item.exposure,
            lifecycleOverrideReason: nil,
            approvalID: "test-fixture",
            notionLastEditedTime: "test",
            url: ""
        )
    }
    return SkillRuntimeExposureGate(
        generation: SkillRuntimeGeneration(
            snapshotID: "test-fixture",
            compilerVersion: "test",
            compiledAt: compiledAt,
            entries: manifest
        )
    )
}
