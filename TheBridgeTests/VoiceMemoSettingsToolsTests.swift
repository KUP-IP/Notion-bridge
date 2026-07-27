// VoiceMemoSettingsToolsTests.swift — PKT-1120
// Hermetic coverage for the MCP settings pair and mode-aware UI copy.

import Foundation
import MCP
import TheBridgeLib

private final class VoiceMemoSettingsDefaultsFixture: @unchecked Sendable {
    let suiteName = "kup.solutions.the-bridge.tests.voice-settings.\(UUID().uuidString)"
    let defaults: UserDefaults

    init?() {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        self.defaults = defaults
        reset()
    }

    func reset() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

func runVoiceMemoSettingsToolsTests() async {
    print("\n🎚️ Voice Memo Settings Tool Tests")

    guard let fixture = VoiceMemoSettingsDefaultsFixture() else {
        print("  ❌ FAIL: could not create hermetic UserDefaults suite")
        return
    }
    VoiceMemoModule.settingsDefaultsOverrideForTesting = fixture.defaults
    defer {
        VoiceMemoModule.settingsDefaultsOverrideForTesting = nil
        fixture.reset()
    }

    let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
    await VoiceMemoModule.register(on: router)

    await test("voice_memo_settings tools register with exact tiers, schemas, and annotations") {
        let tools = await router.registrations(forModule: VoiceMemoModule.moduleName)
        guard let get = tools.first(where: { $0.name == "voice_memo_settings_get" }),
              let set = tools.first(where: { $0.name == "voice_memo_settings_set" }) else {
            throw TestError.assertion("settings tools missing")
        }
        try expect(get.tier == .open, "settings_get must be open")
        try expect(set.tier == .notify, "settings_set must be notify")
        guard case .object(let schema) = set.inputSchema,
              case .object(let properties)? = schema["properties"] else {
            throw TestError.assertion("settings_set schema missing")
        }
        try expect(Set(properties.keys) == Set([
            "curatorMode", "ollamaRouting", "appleTranscript", "parakeetTranscription",
        ]), "settings_set must expose exactly four optional keys")
        let getAnnotation = ToolAnnotationCatalog.annotations(for: get.name)
        let setAnnotation = ToolAnnotationCatalog.annotations(for: set.name)
        try expect(getAnnotation?.readOnlyHint == true && getAnnotation?.idempotentHint == true,
                   "settings_get annotation")
        try expect(setAnnotation?.readOnlyHint == false && setAnnotation?.idempotentHint == true,
                   "settings_set annotation")
    }

    await test("voice_memo_settings_get returns all four effective defaults") {
        fixture.reset()
        let result = try await router.dispatch(
            toolName: "voice_memo_settings_get",
            arguments: .object([:]))
        guard case .object(let snapshot) = result else {
            throw TestError.assertion("expected settings snapshot")
        }
        try expect(snapshot["curatorMode"] == .string("auto"), "default curatorMode")
        try expect(snapshot["ollamaRouting"] == .bool(false), "default ollamaRouting")
        try expect(snapshot["appleTranscript"] == .bool(true), "default appleTranscript")
        try expect(snapshot["parakeetTranscription"] == .bool(true), "default parakeetTranscription")
        try expect(snapshot.count == 4, "snapshot must contain exactly four values")
    }

    await test("voice_memo_settings_set partially updates mode and preserves ladder toggles") {
        fixture.reset()
        fixture.defaults.set(true, forKey: BridgeDefaults.voiceMemoOllamaRouting)
        fixture.defaults.set(false, forKey: BridgeDefaults.voiceMemoAppleTranscript)
        fixture.defaults.set(true, forKey: BridgeDefaults.voiceMemoParakeetTranscription)
        let result = try await router.dispatch(
            toolName: "voice_memo_settings_set",
            arguments: .object(["curatorMode": .string("local")]))
        guard case .object(let snapshot) = result else {
            throw TestError.assertion("expected post-write snapshot")
        }
        try expect(snapshot["curatorMode"] == .string("local"), "mode update")
        try expect(snapshot["ollamaRouting"] == .bool(true), "ollama unchanged")
        try expect(snapshot["appleTranscript"] == .bool(false), "apple unchanged")
        try expect(snapshot["parakeetTranscription"] == .bool(true), "parakeet unchanged")
    }

    await test("voice_memo_settings_set rejects unknown mode before writing any key") {
        fixture.reset()
        let result = try await router.dispatch(
            toolName: "voice_memo_settings_set",
            arguments: .object([
                "curatorMode": .string("bogus"),
                "ollamaRouting": .bool(true),
            ]))
        guard case .object(let response) = result,
              case .string(let error)? = response["error"],
              case .array(let valid)? = response["validValues"] else {
            throw TestError.assertion("expected structured invalid mode response")
        }
        let expected = VoiceMemoCuratorMode.allCases.map { Value.string($0.rawValue) }
        try expect(valid == expected, "valid values must derive from allCases")
        for mode in VoiceMemoCuratorMode.allCases {
            try expect(error.contains(mode.rawValue), "error must list \(mode.rawValue)")
        }
        try expect(fixture.defaults.object(forKey: BridgeDefaults.voiceMemoCuratorMode) == nil,
                   "invalid mode must not write curatorMode")
        try expect(fixture.defaults.object(forKey: BridgeDefaults.voiceMemoOllamaRouting) == nil,
                   "validation must precede all writes")
    }

    await test("voice_memo_settings_set persists a toggle and subsequent get reflects it") {
        fixture.reset()
        let setResult = try await router.dispatch(
            toolName: "voice_memo_settings_set",
            arguments: .object(["ollamaRouting": .bool(true)]))
        let getResult = try await router.dispatch(
            toolName: "voice_memo_settings_get",
            arguments: .object([:]))
        guard case .object(let setSnapshot) = setResult,
              case .object(let getSnapshot) = getResult else {
            throw TestError.assertion("expected settings snapshots")
        }
        try expect(fixture.defaults.bool(forKey: BridgeDefaults.voiceMemoOllamaRouting), "toggle persisted")
        try expect(setSnapshot == getSnapshot, "set returns the post-write get snapshot")
        try expect(getSnapshot["ollamaRouting"] == .bool(true), "subsequent get reflects write")
    }

    await test("Memory Settings Ollama annotation is correct in all five modes") {
        for mode in VoiceMemoCuratorMode.allCases {
            let annotation = MemorySettingsTab.ollamaRoutingAnnotation(mode)
            if mode == .auto {
                try expect(annotation == nil, "Auto is the only mode that reads the toggle")
            } else {
                try expect(annotation?.contains("Auto mode") == true,
                           "\(mode.rawValue) must explain toggle is inert")
                if mode == .local {
                    try expect(annotation?.contains("forces this on") == true, "Local forces on")
                } else {
                    try expect(annotation?.contains("forces Ollama routing off") == true,
                               "\(mode.rawValue) forces off")
                }
            }
        }
    }

    await test("Memory Settings Auto and Cloud help point to Cloud enhancement") {
        try expect(MemorySettingsTab.curatorModeHelp(.auto).contains("Cloud enhancement below"),
                   "Auto cloud cross-reference")
        try expect(MemorySettingsTab.curatorModeHelp(.cloud).contains("Cloud enhancement below"),
                   "Cloud cross-reference")
    }
}
