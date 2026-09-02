// ScreenModuleTests.swift — deterministic Screen handler contracts
// TheBridge · Tests
//
// Canonical tests use explicit package-scoped runtime dependencies. They never
// touch live TCC, ScreenCaptureKit, Vision, AppKit, capture directories, or
// image persistence. Live integration and performance verification are separate.

import CoreGraphics
import Foundation
import MCP
import TheBridgeLib

private enum ScreenFixtureError: Error, LocalizedError, Sendable {
    case unexpectedCall(String)
    case persistenceFailure
    case ocrFailure

    var errorDescription: String? {
        switch self {
        case .unexpectedCall(let name):
            return "Unexpected Screen runtime call: \(name)"
        case .persistenceFailure:
            return "fixture persistence failure"
        case .ocrFailure:
            return "fixture OCR failure"
        }
    }
}

private final class ScreenRuntimeSpy: @unchecked Sendable {
    struct Snapshot: Sendable {
        let frontmostCalls: Int
        let cleanupCalls: Int
        let captureCalls: Int
        let persistCalls: Int
        let metadataCalls: Int
        let ocrCalls: Int
        let callOrder: [String]
        let lastCaptureRequest: ScreenCaptureRequest?
        let lastPersistFormat: String?
        let lastOCRLanguage: String?
    }

    private let lock = NSLock()
    private var frontmostCalls = 0
    private var cleanupCalls = 0
    private var captureCalls = 0
    private var persistCalls = 0
    private var metadataCalls = 0
    private var ocrCalls = 0
    private var callOrder: [String] = []
    private var lastCaptureRequest: ScreenCaptureRequest?
    private var lastPersistFormat: String?
    private var lastOCRLanguage: String?

    let frontmostValue: String?
    let capture: @MainActor @Sendable (ScreenCaptureRequest) async throws -> CGImage
    let persist: @Sendable (CGImage, String) throws -> ScreenCaptureArtifact
    let metadata: @MainActor @Sendable () async -> [ScreenDisplayInfo]
    let ocr: @Sendable (CGImage, String) throws -> [ScreenOCRObservation]

    init(
        frontmostValue: String? = nil,
        capture: @escaping @MainActor @Sendable (ScreenCaptureRequest) async throws -> CGImage = { _ in
            throw ScreenFixtureError.unexpectedCall("captureImage")
        },
        persist: @escaping @Sendable (CGImage, String) throws -> ScreenCaptureArtifact = { _, _ in
            throw ScreenFixtureError.unexpectedCall("persistCaptureArtifact")
        },
        metadata: @escaping @MainActor @Sendable () async -> [ScreenDisplayInfo] = {
            []
        },
        ocr: @escaping @Sendable (CGImage, String) throws -> [ScreenOCRObservation] = { _, _ in
            throw ScreenFixtureError.unexpectedCall("recognizeText")
        }
    ) {
        self.frontmostValue = frontmostValue
        self.capture = capture
        self.persist = persist
        self.metadata = metadata
        self.ocr = ocr
    }

    func runtime() -> ScreenModuleRuntime {
        ScreenModuleRuntime(
            frontmostBundleId: { [self] in
                lock.withLock {
                    frontmostCalls += 1
                    callOrder.append("frontmost")
                }
                return frontmostValue
            },
            cleanupCaptureFiles: { [self] in
                lock.withLock {
                    cleanupCalls += 1
                    callOrder.append("cleanup")
                }
            },
            captureImage: { [self] request in
                lock.withLock {
                    captureCalls += 1
                    callOrder.append("capture")
                    lastCaptureRequest = request
                }
                return try await capture(request)
            },
            persistCaptureArtifact: { [self] image, format in
                lock.withLock {
                    persistCalls += 1
                    callOrder.append("persist")
                    lastPersistFormat = format
                }
                return try persist(image, format)
            },
            displayMetadata: { [self] in
                lock.withLock {
                    metadataCalls += 1
                    callOrder.append("metadata")
                }
                return await metadata()
            },
            recognizeText: { [self] image, language in
                lock.withLock {
                    ocrCalls += 1
                    callOrder.append("ocr")
                    lastOCRLanguage = language
                }
                return try ocr(image, language)
            }
        )
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                frontmostCalls: frontmostCalls,
                cleanupCalls: cleanupCalls,
                captureCalls: captureCalls,
                persistCalls: persistCalls,
                metadataCalls: metadataCalls,
                ocrCalls: ocrCalls,
                callOrder: callOrder,
                lastCaptureRequest: lastCaptureRequest,
                lastPersistFormat: lastPersistFormat,
                lastOCRLanguage: lastOCRLanguage
            )
        }
    }
}

private func makeScreenTestImage() throws -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let image = context.makeImage() else {
        throw TestError.assertion("failed to create deterministic 1x1 image")
    }
    return image
}

private func makeScreenRouter(_ spy: ScreenRuntimeSpy) async -> ToolRouter {
    let gate = SecurityGate(approvalProvider: TestSecurityApprovalProvider())
    let router = ToolRouter(securityGate: gate, auditLog: AuditLog())
    await ScreenModule.register(on: router, runtime: spy.runtime())
    await ScreenModule.registerRecording(on: router)
    return router
}

private let screenRecordingDeniedResponse: Value = .object([
    "error": .string("screen_recording_denied"),
    "message": .string("Screen Recording permission not granted. Open System Settings > Privacy & Security > Screen Recording and enable The Bridge.")
])

// MARK: - ScreenModule Tests

func runScreenModuleTests() async {
    print("\n📸 ScreenModule Tests")

    let registrationSpy = ScreenRuntimeSpy()
    let router = await makeScreenRouter(registrationSpy)

    // --- Registration ---

    await test("ScreenModule registers 4 tools with explicit test runtime") {
        let tools = await router.registrations(forModule: "screen")
        try expect(tools.count == 4, "Expected 4 screen tools, got \(tools.count)")
    }

    await test("ScreenModule tool names are correct") {
        let tools = await router.registrations(forModule: "screen")
        let names = Set(tools.map(\.name))
        try expect(names == ["screen_capture", "screen_ocr", "screen_record_start", "screen_record_stop"])
    }

    await test("screen_capture is open tier") {
        let tool = await router.registrations(forModule: "screen")
            .first(where: { $0.name == "screen_capture" })!
        try expect(tool.tier == .open, "Expected open, got \(tool.tier.rawValue)")
    }

    await test("screen_ocr is open tier") {
        let tool = await router.registrations(forModule: "screen")
            .first(where: { $0.name == "screen_ocr" })!
        try expect(tool.tier == .open, "Expected open, got \(tool.tier.rawValue)")
    }

    await test("screen_record_start is notify tier") {
        let tool = await router.registrations(forModule: "screen")
            .first(where: { $0.name == "screen_record_start" })!
        try expect(tool.tier == .notify, "Expected notify, got \(tool.tier.rawValue)")
        guard case .object(let schema) = tool.inputSchema,
              case .object(let properties)? = schema["properties"] else {
            throw TestError.assertion("missing screen_record_start schema")
        }
        try expect(properties["displayIndex"] != nil, "displayIndex must be on screen_record_start")
        try expect(properties["windowId"] == nil, "window recording is out of scope")
        try expect(properties["appName"] == nil, "app recording is out of scope")
        try expect(properties["region"] == nil, "region recording is out of scope")
    }

    await test("resolveDisplayIndex fails closed on empty and out-of-range") {
        try expect(ScreenModule.resolveDisplayIndex(nil, displayCount: 0) == nil)
        try expect(ScreenModule.resolveDisplayIndex(0, displayCount: 0) == nil)
        try expect(ScreenModule.resolveDisplayIndex(0, displayCount: 2) == 0)
        try expect(ScreenModule.resolveDisplayIndex(1, displayCount: 2) == 1)
        try expect(ScreenModule.resolveDisplayIndex(2, displayCount: 2) == nil)
        try expect(ScreenModule.resolveDisplayIndex(-1, displayCount: 2) == nil)
        try expect(ScreenModule.resolveDisplayIndex(nil, displayCount: 2) == 0)
    }

    await test("screen_record_stop is notify tier") {
        let tool = await router.registrations(forModule: "screen")
            .first(where: { $0.name == "screen_record_stop" })!
        try expect(tool.tier == .notify, "Expected notify, got \(tool.tier.rawValue)")
    }

    await test("screen window schemas expose bundleId and appName at both registration sites") {
        let tools = await router.registrations(forModule: "screen")
        for name in ["screen_capture", "screen_ocr"] {
            guard let tool = tools.first(where: { $0.name == name }),
                  case .object(let schema) = tool.inputSchema,
                  case .object(let properties)? = schema["properties"] else {
                throw TestError.assertion("missing schema for \(name)")
            }
            try expect(properties["windowId"] != nil, "\(name) missing windowId")
            try expect(properties["bundleId"] != nil, "\(name) missing bundleId")
            try expect(properties["appName"] != nil, "\(name) missing appName")
        }
    }

    // --- Pure window resolution ---

    let windows = [
        ScreenModule.WindowCandidate(windowId: 11, bundleId: "com.example.one", appName: "Example"),
        ScreenModule.WindowCandidate(windowId: 12, bundleId: "com.example.two", appName: "Example"),
        ScreenModule.WindowCandidate(windowId: 13, bundleId: "com.example.unique", appName: "Unique App"),
    ]

    await test("screen window resolver gives windowId precedence over app identity") {
        let result = ScreenModule.resolveWindowTarget(
            windowId: 13,
            bundleId: "com.example.one",
            appName: "Example",
            candidates: windows
        )
        try expect(result == .selected(13), "windowId must win: \(result)")
    }

    await test("screen window resolver matches a unique bundleId") {
        let result = ScreenModule.resolveWindowTarget(
            windowId: nil,
            bundleId: "com.example.unique",
            appName: nil,
            candidates: windows
        )
        try expect(result == .selected(13), "unique bundle match failed: \(result)")
    }

    await test("screen window resolver matches appName case-insensitively") {
        let result = ScreenModule.resolveWindowTarget(
            windowId: nil,
            bundleId: nil,
            appName: "unique app",
            candidates: windows
        )
        try expect(result == .selected(13), "unique appName match failed: \(result)")
    }

    await test("screen window resolver reports zero matches with available windows") {
        let result = ScreenModule.resolveWindowTarget(
            windowId: nil,
            bundleId: "com.example.missing",
            appName: nil,
            candidates: windows
        )
        guard case .appNotFound(let query, let available) = result else {
            throw TestError.assertion("expected appNotFound, got \(result)")
        }
        try expect(query.contains("com.example.missing"))
        try expect(available == windows)
    }

    await test("screen window resolver errors instead of guessing across multiple matches") {
        let result = ScreenModule.resolveWindowTarget(
            windowId: nil,
            bundleId: nil,
            appName: "Example",
            candidates: windows
        )
        guard case .ambiguous(_, let matches) = result else {
            throw TestError.assertion("expected ambiguous result, got \(result)")
        }
        try expect(matches.map(\.windowId) == [11, 12])
    }

    await test("screen window resolver requires one identity") {
        let result = ScreenModule.resolveWindowTarget(
            windowId: nil,
            bundleId: nil,
            appName: nil,
            candidates: windows
        )
        try expect(result == .missingIdentity)
    }

    // --- Deterministic handler contracts ---

    await test("screen_capture serializes exact Screen Recording denial and stops before persistence") {
        let spy = ScreenRuntimeSpy(capture: { _ in throw ScreenModuleError.screenRecordingDenied })
        let testRouter = await makeScreenRouter(spy)
        let result = try await testRouter.dispatch(toolName: "screen_capture", arguments: .object([:]))
        try expect(result == screenRecordingDeniedResponse, "unexpected denial response: \(result)")

        let calls = spy.snapshot()
        try expect(calls.cleanupCalls == 1)
        try expect(calls.captureCalls == 1)
        try expect(calls.persistCalls == 0)
        try expect(calls.metadataCalls == 0)
        try expect(calls.ocrCalls == 0)
    }

    await test("screen_ocr serializes exact Screen Recording denial and never invokes OCR") {
        let spy = ScreenRuntimeSpy(capture: { _ in throw ScreenModuleError.screenRecordingDenied })
        let testRouter = await makeScreenRouter(spy)
        let result = try await testRouter.dispatch(toolName: "screen_ocr", arguments: .object([:]))
        try expect(result == screenRecordingDeniedResponse, "unexpected denial response: \(result)")

        let calls = spy.snapshot()
        try expect(calls.cleanupCalls == 0)
        try expect(calls.captureCalls == 1)
        try expect(calls.persistCalls == 0)
        try expect(calls.metadataCalls == 0)
        try expect(calls.ocrCalls == 0)
    }

    await test("screen_capture frontmost mismatch short-circuits every downstream dependency") {
        let spy = ScreenRuntimeSpy(frontmostValue: "com.example.other")
        let testRouter = await makeScreenRouter(spy)
        let required = "com.example.required"
        let result = try await testRouter.dispatch(
            toolName: "screen_capture",
            arguments: .object(["requireFrontmostBundleId": .string(required)])
        )
        let expected: Value = .object([
            "error": .string("frontmost_mismatch"),
            "message": .string("Required frontmost app 'com.example.required' is not active (frontmost: 'com.example.other'). Capture aborted. Bring the app forward (e.g. bridge_focus_settings) and retry."),
            "requiredBundleId": .string(required),
            "frontmostBundleId": .string("com.example.other")
        ])
        try expect(result == expected, "unexpected mismatch response: \(result)")

        let calls = spy.snapshot()
        try expect(calls.frontmostCalls == 1)
        try expect(calls.cleanupCalls == 0)
        try expect(calls.captureCalls == 0)
        try expect(calls.persistCalls == 0)
        try expect(calls.metadataCalls == 0)
        try expect(calls.ocrCalls == 0)
    }

    await test("screen_capture empty frontmost requirement skips lookup and reaches capture") {
        let spy = ScreenRuntimeSpy(capture: { _ in throw ScreenModuleError.screenRecordingDenied })
        let testRouter = await makeScreenRouter(spy)
        let result = try await testRouter.dispatch(
            toolName: "screen_capture",
            arguments: .object(["requireFrontmostBundleId": .string("")])
        )
        try expect(result == screenRecordingDeniedResponse)

        let calls = spy.snapshot()
        try expect(calls.frontmostCalls == 0)
        try expect(calls.cleanupCalls == 1)
        try expect(calls.captureCalls == 1)
    }

    await test("screen_capture forwards parsed target arguments to the capture dependency") {
        let spy = ScreenRuntimeSpy(capture: { _ in throw ScreenModuleError.screenRecordingDenied })
        let testRouter = await makeScreenRouter(spy)
        _ = try await testRouter.dispatch(
            toolName: "screen_capture",
            arguments: .object([
                "target": .string("region"),
                "region": .object(["x": .int(1), "y": .int(2), "w": .int(3), "h": .int(4)]),
                "displayIndex": .int(2)
            ])
        )
        let request = spy.snapshot().lastCaptureRequest
        try expect(request == ScreenCaptureRequest(
            target: "region",
            windowId: nil,
            bundleId: nil,
            appName: nil,
            region: ScreenCaptureRegion(x: 1, y: 2, width: 3, height: 4),
            displayIndex: 2
        ))
    }

    await test("screen_capture success assembles exact artifact and display response in order") {
        let image = try makeScreenTestImage()
        let artifact = ScreenCaptureArtifact(
            filePath: "/tmp/fixture-screen.jpg",
            width: 640,
            height: 480,
            bytes: 12345,
            format: "jpg",
            isFallback: false
        )
        let displays = [
            ScreenDisplayInfo(index: 0, width: 1728, height: 1117, isMain: true),
            ScreenDisplayInfo(index: 1, width: 1920, height: 1080, isMain: false)
        ]
        let spy = ScreenRuntimeSpy(
            capture: { _ in image },
            persist: { _, _ in artifact },
            metadata: { displays }
        )
        let testRouter = await makeScreenRouter(spy)
        let result = try await testRouter.dispatch(
            toolName: "screen_capture",
            arguments: .object(["format": .string("jpg")])
        )
        let expected: Value = .object([
            "filePath": .string("/tmp/fixture-screen.jpg"),
            "width": .int(640),
            "height": .int(480),
            "bytes": .int(12345),
            "format": .string("jpg"),
            "displayCount": .int(2),
            "displays": .array([
                .object(["index": .int(0), "width": .int(1728), "height": .int(1117), "isMain": .bool(true)]),
                .object(["index": .int(1), "width": .int(1920), "height": .int(1080), "isMain": .bool(false)])
            ])
        ])
        try expect(result == expected, "unexpected successful capture response: \(result)")

        let calls = spy.snapshot()
        try expect(calls.callOrder == ["cleanup", "capture", "persist", "metadata"], "unexpected call order: \(calls.callOrder)")
        try expect(calls.lastPersistFormat == "jpg")
    }

    await test("screen_capture fallback artifact emits exact warning") {
        let image = try makeScreenTestImage()
        let artifact = ScreenCaptureArtifact(
            filePath: "/tmp/nb-screen-fixture.png",
            width: 1,
            height: 1,
            bytes: 4,
            format: "png",
            isFallback: true
        )
        let spy = ScreenRuntimeSpy(
            capture: { _ in image },
            persist: { _, _ in artifact },
            metadata: { [] }
        )
        let testRouter = await makeScreenRouter(spy)
        let result = try await testRouter.dispatch(toolName: "screen_capture", arguments: .object([:]))
        guard case .object(let response) = result else {
            throw TestError.assertion("expected object response")
        }
        try expect(response["warning"] == .string("Configured output directory is invalid or not writable — fell back to /tmp"))
        try expect(response["displayCount"] == .int(0))
        try expect(spy.snapshot().callOrder == ["cleanup", "capture", "persist", "metadata"])
    }

    await test("screen_capture persistence failure skips display metadata") {
        let image = try makeScreenTestImage()
        let spy = ScreenRuntimeSpy(
            capture: { _ in image },
            persist: { _, _ in throw ScreenFixtureError.persistenceFailure }
        )
        let testRouter = await makeScreenRouter(spy)
        let result = try await testRouter.dispatch(toolName: "screen_capture", arguments: .object([:]))
        let expected: Value = .object([
            "error": .string("capture_failed"),
            "message": .string("Failed to persist capture artifact: fixture persistence failure")
        ])
        try expect(result == expected, "unexpected persistence failure response: \(result)")

        let calls = spy.snapshot()
        try expect(calls.callOrder == ["cleanup", "capture", "persist"])
        try expect(calls.metadataCalls == 0)
    }

    await test("screen_capture from detached task returns through fake capture without live SCK") {
        let spy = ScreenRuntimeSpy(capture: { _ in throw ScreenModuleError.screenRecordingDenied })
        let testRouter = await makeScreenRouter(spy)
        let result = await Task.detached {
            try? await testRouter.dispatch(toolName: "screen_capture", arguments: .object([:]))
        }.value
        try expect(result == screenRecordingDeniedResponse)
        try expect(spy.snapshot().captureCalls == 1)
    }

    await test("screen_ocr empty observations return the exact blank-screen response") {
        let image = try makeScreenTestImage()
        let spy = ScreenRuntimeSpy(
            capture: { _ in image },
            ocr: { _, _ in [] }
        )
        let testRouter = await makeScreenRouter(spy)
        let result = try await testRouter.dispatch(toolName: "screen_ocr", arguments: .object([:]))
        let expected: Value = .object([
            "text": .string(""),
            "confidence": .double(0.0),
            "bounds": .array([])
        ])
        try expect(result == expected, "unexpected blank OCR response: \(result)")
    }

    await test("screen_ocr maps OCR failure to exact ocr_failed response") {
        let image = try makeScreenTestImage()
        let spy = ScreenRuntimeSpy(
            capture: { _ in image },
            ocr: { _, _ in throw ScreenFixtureError.ocrFailure }
        )
        let testRouter = await makeScreenRouter(spy)
        let result = try await testRouter.dispatch(toolName: "screen_ocr", arguments: .object([:]))
        let expected: Value = .object([
            "error": .string("ocr_failed"),
            "message": .string("Vision text recognition failed: fixture OCR failure")
        ])
        try expect(result == expected, "unexpected OCR error response: \(result)")
    }

    await test("screen_ocr preserves observation order, bounds, language, and rounded average") {
        let image = try makeScreenTestImage()
        let firstConfidence = Float(0.9)
        let secondConfidence = Float(0.3)
        let observations = [
            ScreenOCRObservation(
                candidate: ScreenOCRCandidate(text: "First", confidence: firstConfidence),
                boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
            ),
            ScreenOCRObservation(
                candidate: ScreenOCRCandidate(text: "Second", confidence: secondConfidence),
                boundingBox: CGRect(x: 0.5, y: 0.6, width: 0.2, height: 0.1)
            )
        ]
        let spy = ScreenRuntimeSpy(
            capture: { _ in image },
            ocr: { _, _ in observations }
        )
        let testRouter = await makeScreenRouter(spy)
        let result = try await testRouter.dispatch(
            toolName: "screen_ocr",
            arguments: .object(["language": .string("fr")])
        )
        let expected: Value = .object([
            "text": .string("First\nSecond"),
            "confidence": .double(0.6),
            "bounds": .array([
                .object([
                    "text": .string("First"),
                    "confidence": .double(Double(firstConfidence)),
                    "rect": .object([
                        "x": .double(0.1), "y": .double(0.2),
                        "width": .double(0.3), "height": .double(0.4)
                    ])
                ]),
                .object([
                    "text": .string("Second"),
                    "confidence": .double(Double(secondConfidence)),
                    "rect": .object([
                        "x": .double(0.5), "y": .double(0.6),
                        "width": .double(0.2), "height": .double(0.1)
                    ])
                ])
            ])
        ])
        try expect(result == expected, "unexpected ordered OCR response: \(result)")
        try expect(spy.snapshot().lastOCRLanguage == "fr")
    }

    await test("screen_ocr keeps candidate-less observations in confidence denominator") {
        let image = try makeScreenTestImage()
        let confidence = Float(0.9)
        let spy = ScreenRuntimeSpy(
            capture: { _ in image },
            ocr: { _, _ in
                [
                    ScreenOCRObservation(
                        candidate: ScreenOCRCandidate(text: "Only", confidence: confidence),
                        boundingBox: .zero
                    ),
                    ScreenOCRObservation(candidate: nil, boundingBox: .zero)
                ]
            }
        )
        let testRouter = await makeScreenRouter(spy)
        let result = try await testRouter.dispatch(toolName: "screen_ocr", arguments: .object([:]))
        guard case .object(let response) = result else {
            throw TestError.assertion("expected object response")
        }
        try expect(response["text"] == .string("Only"))
        try expect(response["confidence"] == .double(0.45), "candidate-less observation must remain in denominator")
        guard case .array(let bounds)? = response["bounds"] else {
            throw TestError.assertion("expected bounds array")
        }
        try expect(bounds.count == 1, "candidate-less observation must not create a bounds row")
    }

    await test("screen_record_stop handles no active recording") {
        let result = try await router.dispatch(
            toolName: "screen_record_stop",
            arguments: .object([:])
        )
        guard case .object(let response) = result,
              case .string(let error)? = response["error"] else {
            throw TestError.assertion("expected nonempty recording error")
        }
        try expect(!error.isEmpty)
    }

    await test("Screen registration has no known direct live-call tokens") {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent("TheBridge/Modules/ScreenModule.swift"),
            encoding: .utf8
        )
        guard let runtimeMarker = source.range(of: "// MARK: - Screen Runtime Dependencies") else {
            throw TestError.assertion("missing Screen runtime boundary marker")
        }
        let handlerSource = String(source[..<runtimeMarker.lowerBound])
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let liveSource = String(source[runtimeMarker.lowerBound...])
        let forbidden = [
            "CGPreflightScreenCaptureAccess(",
            "SCScreenshotManager.captureImage",
            "VNRecognizeTextRequest(",
            "NSWorkspace.shared",
            "CGImageDestinationCreateWithURL(",
            "FileManager.default"
        ]
        for token in forbidden {
            try expect(!handlerSource.contains(token), "handler source must not call live dependency: \(token)")
        }
        try expect(handlerSource.contains("package static func register(on router: ToolRouter, runtime: ScreenModuleRuntime)"))
        try expect(!handlerSource.contains("public static func register(on router: ToolRouter) async"))
        try expect(liveSource.contains("internal static let live"))
        try expect(!liveSource.contains("package static let live"))
        try expect(liveSource.contains("package static func registerLiveProbe"))

        let testsDirectory = repository.appendingPathComponent("TheBridgeTests")
        let probeURL = testsDirectory.appendingPathComponent("ScreenLiveProbeTests.swift")
        let probeTests = try String(contentsOf: probeURL, encoding: .utf8)
        let liveProbeCall = ["ScreenModule", ".registerLiveProbe(on:"].joined()
        let canonicalSources = try FileManager.default.contentsOfDirectory(
            at: testsDirectory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.pathExtension == "swift" && $0.lastPathComponent != probeURL.lastPathComponent
        }
        let offenders = try canonicalSources.compactMap { url -> String? in
            let contents = try String(contentsOf: url, encoding: .utf8)
            return contents.contains(liveProbeCall) ? url.lastPathComponent : nil
        }
        try expect(offenders.isEmpty,
                   "canonical tests must not invoke the live probe bridge: \(offenders)")
        try expect(probeTests.contains(liveProbeCall),
                   "dedicated live probe must be the only test route into live Screen dependencies")
    }

    await test("ScreenModule.moduleName is 'screen'") {
        try expect(ScreenModule.moduleName == "screen")
    }
}
