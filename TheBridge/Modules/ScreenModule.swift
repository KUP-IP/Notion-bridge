// ScreenModule.swift – V3-SCREEN-001 Screen Capture & OCR Tools
// TheBridge · Modules
//
// Two Open-tier tools: screen_capture and screen_ocr.
// Uses ScreenCaptureKit for capture and Vision for OCR. screen_capture writes
// one image artifact and performs best-effort cleanup of prior capture files.
// PKT-354: Pull-forward of Phase 4 ScreenModule capture/OCR tools.
//
// Frameworks:
//   - ScreenCaptureKit: SCScreenshotManager.captureImage for screenshots
//   - Vision: VNRecognizeTextRequest for OCR
//   - ImageIO: CGImageDestination for PNG/JPEG encoding (Sendable-safe)
//   - CoreGraphics: CGPreflightScreenCaptureAccess for TCC detection
//
// Capture files: <configuredDir>/b-{ISOWeek}.{ISOWeekday}-{NN}.{ext}
//   (default ~/Desktop, fallback /tmp). Sequence is shared with recordings.
// Cleanup (#256): on each screen_capture, delete prior local-day `b-*` files.
// Same-day 01…NN are kept (no 1-hour wipe). Legacy epoch names are left on disk.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import MCP
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

// MARK: - ScreenModule

/// Provides screen capture and OCR tools using ScreenCaptureKit + Vision.
public enum ScreenModule {

    public static let moduleName = "screen"

    /// Sendable projection of the ScreenCaptureKit window identity used by
    /// the app-target resolver. Keeping selection logic independent of
    /// `SCWindow` makes the ambiguity/failure contract hermetically testable.
    public struct WindowCandidate: Sendable, Equatable {
        public let windowId: Int
        public let bundleId: String?
        public let appName: String?

        public init(windowId: Int, bundleId: String?, appName: String?) {
            self.windowId = windowId
            self.bundleId = bundleId
            self.appName = appName
        }
    }

    public enum WindowSelection: Sendable, Equatable {
        case selected(Int)
        case missingIdentity
        case windowIdNotFound(Int)
        case appNotFound(query: String, available: [WindowCandidate])
        case ambiguous(query: String, matches: [WindowCandidate])
    }

    /// Resolve one capturable window without guessing. An explicit window id
    /// always wins; otherwise bundle id is preferred over application name.
    public static func resolveWindowTarget(
        windowId: Int?,
        bundleId: String?,
        appName: String?,
        candidates: [WindowCandidate]
    ) -> WindowSelection {
        if let windowId {
            return candidates.contains(where: { $0.windowId == windowId })
                ? .selected(windowId)
                : .windowIdNotFound(windowId)
        }

        let normalizedBundleId = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAppName = appName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches: [WindowCandidate]
        let query: String
        if let normalizedBundleId, !normalizedBundleId.isEmpty {
            query = "bundleId=\(normalizedBundleId)"
            matches = candidates.filter { $0.bundleId == normalizedBundleId }
        } else if let normalizedAppName, !normalizedAppName.isEmpty {
            query = "appName=\(normalizedAppName)"
            matches = candidates.filter {
                $0.appName?.caseInsensitiveCompare(normalizedAppName) == .orderedSame
            }
        } else {
            return .missingIdentity
        }

        switch matches.count {
        case 0: return .appNotFound(query: query, available: candidates)
        case 1: return .selected(matches[0].windowId)
        default: return .ambiguous(query: query, matches: matches)
        }
    }

    // MARK: - Pure response helpers

    private static func frontmostGuardFailure(required: String, actual: String?) -> Value? {
        if actual == required { return nil }
        return .object([
            "error": .string("frontmost_mismatch"),
            "message": .string("Required frontmost app '\(required)' is not active (frontmost: '\(actual ?? "unknown")'). Capture aborted. Bring the app forward (e.g. bridge_focus_settings) and retry."),
            "requiredBundleId": .string(required),
            "frontmostBundleId": actual.map(Value.string) ?? .null
        ])
    }

    // MARK: - Registration

    /// Register all ScreenModule tools with explicit runtime dependencies.
    package static func register(on router: ToolRouter, runtime: ScreenModuleRuntime) async {

        // MARK: 1. screen_capture – Open (writes capture artifact)
        await router.register(ToolRegistration(
            name: "screen_capture",
            module: moduleName,
            tier: .open,
            description: "Screenshot a display, window, region, or all displays as PNG/JPG. Static image only; for motion use screen_record_start.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "target": .object([
                        "type": .string("string"),
                        "description": .string("Capture target: 'display', 'window', 'region', or 'all_displays' (default: 'display')"),
                        "enum": .array([.string("display"), .string("window"), .string("region"), .string("all_displays")])
                    ]),
                    "windowId": .object([
                        "type": .string("integer"),
                        "description": .string("Exact window ID to capture. Takes precedence over bundleId/appName when target is 'window'.")
                    ]),
                    "bundleId": .object([
                        "type": .string("string"),
                        "description": .string("Owning application bundle identifier for target='window' when windowId is omitted. Errors when zero or multiple capturable windows match.")
                    ]),
                    "appName": .object([
                        "type": .string("string"),
                        "description": .string("Owning application name for target='window' when windowId and bundleId are omitted. Case-insensitive exact match; errors when zero or multiple windows match.")
                    ]),
                    "region": .object([
                        "type": .string("object"),
                        "description": .string("Region to capture: {x, y, w, h} in screen coordinates (required when target is 'region')"),
                        "properties": .object([
                            "x": .object(["type": .string("integer")]),
                            "y": .object(["type": .string("integer")]),
                            "w": .object(["type": .string("integer")]),
                            "h": .object(["type": .string("integer")])
                        ])
                    ]),
                    "format": .object([
                        "type": .string("string"),
                        "description": .string("Image format: 'png' or 'jpg' (default: 'png'). JPEG uses 0.8 quality."),
                        "enum": .array([.string("png"), .string("jpg")])
                    ]),
                    "displayIndex": .object([
                        "type": .string("integer"),
                        "description": .string("Display index to capture (default: 0 = main display). Use to target a specific monitor. Ignored when target is 'window' or 'all_displays'.")
                    ]),
                    "requireFrontmostBundleId": .object([
                        "type": .string("string"),
                        "description": .string("Optional guard: only capture if this app bundle id is currently frontmost (e.g. 'com.keepr.TheBridge'). Returns error='frontmost_mismatch' and skips the capture otherwise. Pair with bridge_focus_settings to assert The Bridge is in front before capturing it.")
                    ])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let args: [String: Value] = {
                    if case .object(let a) = arguments { return a }
                    return [:]
                }()

                let target: String = {
                    if case .string(let t) = args["target"] { return t }
                    return "display"
                }()
                let windowId: Int? = {
                    if case .int(let w) = args["windowId"] { return w }
                    return nil
                }()
                let bundleId: String? = {
                    if case .string(let value) = args["bundleId"] { return value }
                    return nil
                }()
                let appName: String? = {
                    if case .string(let value) = args["appName"] { return value }
                    return nil
                }()
                let region: ScreenCaptureRegion? = {
                    if case .object(let value) = args["region"],
                       case .int(let x) = value["x"],
                       case .int(let y) = value["y"],
                       case .int(let width) = value["w"],
                       case .int(let height) = value["h"] {
                        return ScreenCaptureRegion(x: x, y: y, width: width, height: height)
                    }
                    return nil
                }()
                let format: String = {
                    if case .string(let f) = args["format"] { return f }
                    return "png"
                }()
                let displayIndex: Int? = {
                    if case .int(let d) = args["displayIndex"] { return d }
                    return nil
                }()
                let requireFrontmost: String? = {
                    if case .string(let b) = args["requireFrontmostBundleId"] { return b }
                    return nil
                }()

                // FB-AUTOMATION: frontmost-app guard (opt-in). Short-circuit
                // before cleanup or capture if the required app is not in front.
                if let required = requireFrontmost, !required.isEmpty {
                    let actual = await runtime.frontmostBundleId()
                    if let guardFailure = frontmostGuardFailure(required: required, actual: actual) {
                        return guardFailure
                    }
                }

                runtime.cleanupCaptureFiles()

                let request = ScreenCaptureRequest(
                    target: target,
                    windowId: windowId,
                    bundleId: bundleId,
                    appName: appName,
                    region: region,
                    displayIndex: displayIndex
                )

                let image: CGImage
                do {
                    image = try await runtime.captureImage(request)
                } catch let error as ScreenModuleError {
                    return error.toResponse()
                } catch {
                    return ScreenModuleError.captureFailed(
                        "Screen capture failed: \(error.localizedDescription)"
                    ).toResponse()
                }

                let artifact: ScreenCaptureArtifact
                do {
                    artifact = try runtime.persistCaptureArtifact(image, format)
                } catch let error as ScreenModuleError {
                    return error.toResponse()
                } catch {
                    return ScreenModuleError.captureFailed(
                        "Failed to persist capture artifact: \(error.localizedDescription)"
                    ).toResponse()
                }

                let displayInfo = await runtime.displayMetadata()
                let displayInfoArray: [Value] = displayInfo.map { display in
                    .object([
                        "index": .int(display.index),
                        "width": .int(display.width),
                        "height": .int(display.height),
                        "isMain": .bool(display.isMain)
                    ])
                }

                var response: [String: Value] = [
                    "filePath": .string(artifact.filePath),
                    "width": .int(artifact.width),
                    "height": .int(artifact.height),
                    "bytes": .int(artifact.bytes),
                    "format": .string(artifact.format),
                    "displayCount": .int(displayInfoArray.count),
                    "displays": .array(displayInfoArray)
                ]
                if artifact.isFallback {
                    response["warning"] = .string(
                        "Configured output directory is invalid or not writable — fell back to /tmp"
                    )
                }
                return .object(response)
            }
        ))

        // MARK: 2. screen_ocr – Open (read-only)
        await router.register(ToolRegistration(
            name: "screen_ocr",
            module: moduleName,
            tier: .open,
            description: "Run Vision OCR on a live display/window/region and return recognized text with confidences + bounding boxes. Pair with screen_capture if you also need the PNG.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "target": .object([
                        "type": .string("string"),
                        "description": .string("Capture target: 'display', 'window', 'region', or 'all_displays' (default: 'display')"),
                        "enum": .array([.string("display"), .string("window"), .string("region"), .string("all_displays")])
                    ]),
                    "windowId": .object([
                        "type": .string("integer"),
                        "description": .string("Exact window ID to capture. Takes precedence over bundleId/appName when target is 'window'.")
                    ]),
                    "bundleId": .object([
                        "type": .string("string"),
                        "description": .string("Owning application bundle identifier for target='window' when windowId is omitted. Errors when zero or multiple capturable windows match.")
                    ]),
                    "appName": .object([
                        "type": .string("string"),
                        "description": .string("Owning application name for target='window' when windowId and bundleId are omitted. Case-insensitive exact match; errors when zero or multiple windows match.")
                    ]),
                    "region": .object([
                        "type": .string("object"),
                        "description": .string("Region to capture: {x, y, w, h} in screen coordinates (required when target is 'region')"),
                        "properties": .object([
                            "x": .object(["type": .string("integer")]),
                            "y": .object(["type": .string("integer")]),
                            "w": .object(["type": .string("integer")]),
                            "h": .object(["type": .string("integer")])
                        ])
                    ]),
                    "language": .object([
                        "type": .string("string"),
                        "description": .string("OCR recognition language (default: 'en'). Supports ISO 639-1 codes.")
                    ]),
                    "displayIndex": .object([
                        "type": .string("integer"),
                        "description": .string("Display index for capture (default: 0 = main display). Use to target a specific monitor. Ignored when target is 'window' or 'all_displays'.")
                    ])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let args: [String: Value] = {
                    if case .object(let a) = arguments { return a }
                    return [:]
                }()

                let target: String = {
                    if case .string(let t) = args["target"] { return t }
                    return "display"
                }()
                let windowId: Int? = {
                    if case .int(let w) = args["windowId"] { return w }
                    return nil
                }()
                let bundleId: String? = {
                    if case .string(let value) = args["bundleId"] { return value }
                    return nil
                }()
                let appName: String? = {
                    if case .string(let value) = args["appName"] { return value }
                    return nil
                }()
                let region: ScreenCaptureRegion? = {
                    if case .object(let value) = args["region"],
                       case .int(let x) = value["x"],
                       case .int(let y) = value["y"],
                       case .int(let width) = value["w"],
                       case .int(let height) = value["h"] {
                        return ScreenCaptureRegion(x: x, y: y, width: width, height: height)
                    }
                    return nil
                }()
                let language: String = {
                    if case .string(let l) = args["language"] { return l }
                    return "en"
                }()
                let displayIndex: Int? = {
                    if case .int(let d) = args["displayIndex"] { return d }
                    return nil
                }()

                let request = ScreenCaptureRequest(
                    target: target,
                    windowId: windowId,
                    bundleId: bundleId,
                    appName: appName,
                    region: region,
                    displayIndex: displayIndex
                )

                let image: CGImage
                do {
                    image = try await runtime.captureImage(request)
                } catch let error as ScreenModuleError {
                    return error.toResponse()
                } catch {
                    return ScreenModuleError.captureFailed(
                        "Screen capture failed: \(error.localizedDescription)"
                    ).toResponse()
                }

                let observations: [ScreenOCRObservation]
                do {
                    observations = try runtime.recognizeText(image, language)
                } catch {
                    return .object([
                        "error": .string("ocr_failed"),
                        "message": .string(
                            "Vision text recognition failed: \(error.localizedDescription)"
                        )
                    ])
                }

                guard !observations.isEmpty else {
                    return .object([
                        "text": .string(""),
                        "confidence": .double(0.0),
                        "bounds": .array([])
                    ])
                }

                var fullText = ""
                var totalConfidence: Float = 0
                var bounds: [Value] = []

                for observation in observations {
                    guard let candidate = observation.candidate else { continue }
                    fullText += candidate.text + "\n"
                    totalConfidence += candidate.confidence

                    let box = observation.boundingBox
                    bounds.append(.object([
                        "text": .string(candidate.text),
                        "confidence": .double(Double(candidate.confidence)),
                        "rect": .object([
                            "x": .double(box.origin.x),
                            "y": .double(box.origin.y),
                            "width": .double(box.size.width),
                            "height": .double(box.size.height)
                        ])
                    ]))
                }

                let averageConfidence = Double(totalConfidence) / Double(observations.count)
                return .object([
                    "text": .string(
                        fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                    ),
                    "confidence": .double(
                        (averageConfidence * 1000).rounded() / 1000
                    ),
                    "bounds": .array(bounds)
                ])
            }
        ))
    }
}

// MARK: - Errors

/// Structured error types for ScreenModule — all return JSON responses, never crash.
package enum ScreenModuleError: Error, Sendable, Equatable {
    case screenRecordingDenied
    case noDisplays
    case windowNotFound(Int)
    case windowNotFoundForApp(query: String, available: [ScreenModule.WindowCandidate])
    case ambiguousWindowsForApp(query: String, matches: [ScreenModule.WindowCandidate])
    case missingParameter(String)
    case encodingFailed(String)
    case captureFailed(String)

    func toResponse() -> Value {
        switch self {
        case .screenRecordingDenied:
            return .object([
                "error": .string("screen_recording_denied"),
                "message": .string("Screen Recording permission not granted. Open System Settings > Privacy & Security > Screen Recording and enable The Bridge.")
            ])
        case .noDisplays:
            return .object([
                "error": .string("no_displays"),
                "message": .string("No capturable displays found.")
            ])
        case .windowNotFound(let id):
            return .object([
                "error": .string("window_not_found"),
                "message": .string("Window ID \(id) not found in capturable windows.")
            ])
        case .windowNotFoundForApp(let query, let available):
            return .object([
                "error": .string("window_not_found_for_app"),
                "message": .string("No capturable window matched \(query). Available: \(windowList(available))."),
                "availableWindows": .array(available.map(windowValue)),
            ])
        case .ambiguousWindowsForApp(let query, let matches):
            return .object([
                "error": .string("ambiguous_window_for_app"),
                "message": .string("Multiple capturable windows matched \(query); pass windowId to choose one. Matches: \(windowList(matches))."),
                "matchingWindows": .array(matches.map(windowValue)),
            ])
        case .missingParameter(let msg):
            return .object([
                "error": .string("invalid_parameters"),
                "message": .string(msg)
            ])
        case .encodingFailed(let format):
            return .object([
                "error": .string("encoding_failed"),
                "message": .string("Failed to encode image as \(format).")
            ])
        case .captureFailed(let msg):
            return .object([
                "error": .string("capture_failed"),
                "message": .string(msg)
            ])
        }
    }

    private func windowValue(_ candidate: ScreenModule.WindowCandidate) -> Value {
        .object([
            "windowId": .int(candidate.windowId),
            "appName": candidate.appName.map(Value.string) ?? .null,
            "bundleId": candidate.bundleId.map(Value.string) ?? .null,
        ])
    }

    private func windowList(_ candidates: [ScreenModule.WindowCandidate]) -> String {
        guard !candidates.isEmpty else { return "none" }
        return candidates.map { candidate in
            "\(candidate.windowId):\(candidate.appName ?? "unknown") [\(candidate.bundleId ?? "unknown")]"
        }.joined(separator: ", ")
    }
}

// MARK: - Screen Runtime Dependencies

package struct ScreenCaptureRegion: Sendable, Equatable {
    package let x: Int
    package let y: Int
    package let width: Int
    package let height: Int

    package init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

package struct ScreenCaptureRequest: Sendable, Equatable {
    package let target: String
    package let windowId: Int?
    package let bundleId: String?
    package let appName: String?
    package let region: ScreenCaptureRegion?
    package let displayIndex: Int?

    package init(
        target: String,
        windowId: Int?,
        bundleId: String?,
        appName: String?,
        region: ScreenCaptureRegion?,
        displayIndex: Int?
    ) {
        self.target = target
        self.windowId = windowId
        self.bundleId = bundleId
        self.appName = appName
        self.region = region
        self.displayIndex = displayIndex
    }
}

package struct ScreenCaptureArtifact: Sendable, Equatable {
    package let filePath: String
    package let width: Int
    package let height: Int
    package let bytes: Int
    package let format: String
    package let isFallback: Bool

    package init(
        filePath: String,
        width: Int,
        height: Int,
        bytes: Int,
        format: String,
        isFallback: Bool
    ) {
        self.filePath = filePath
        self.width = width
        self.height = height
        self.bytes = bytes
        self.format = format
        self.isFallback = isFallback
    }
}

package struct ScreenDisplayInfo: Sendable, Equatable {
    package let index: Int
    package let width: Int
    package let height: Int
    package let isMain: Bool

    package init(index: Int, width: Int, height: Int, isMain: Bool) {
        self.index = index
        self.width = width
        self.height = height
        self.isMain = isMain
    }
}

package struct ScreenOCRCandidate: Sendable, Equatable {
    package let text: String
    package let confidence: Float

    package init(text: String, confidence: Float) {
        self.text = text
        self.confidence = confidence
    }
}

package struct ScreenOCRObservation: Sendable, Equatable {
    package let candidate: ScreenOCRCandidate?
    package let boundingBox: CGRect

    package init(candidate: ScreenOCRCandidate?, boundingBox: CGRect) {
        self.candidate = candidate
        self.boundingBox = boundingBox
    }
}

/// Explicit runtime dependencies for Screen handlers.
///
/// Production composition supplies the internal `.live` value. Tests must
/// supply every dependency explicitly; there is no default-live registration
/// path and no mutable global override.
package struct ScreenModuleRuntime: Sendable {
    package let frontmostBundleId: @MainActor @Sendable () -> String?
    package let cleanupCaptureFiles: @Sendable () -> Void
    package let captureImage: @MainActor @Sendable (ScreenCaptureRequest) async throws -> CGImage
    package let persistCaptureArtifact: @Sendable (CGImage, String) throws -> ScreenCaptureArtifact
    package let displayMetadata: @MainActor @Sendable () async -> [ScreenDisplayInfo]
    package let recognizeText: @Sendable (CGImage, String) throws -> [ScreenOCRObservation]

    package init(
        frontmostBundleId: @escaping @MainActor @Sendable () -> String?,
        cleanupCaptureFiles: @escaping @Sendable () -> Void,
        captureImage: @escaping @MainActor @Sendable (ScreenCaptureRequest) async throws -> CGImage,
        persistCaptureArtifact: @escaping @Sendable (CGImage, String) throws -> ScreenCaptureArtifact,
        displayMetadata: @escaping @MainActor @Sendable () async -> [ScreenDisplayInfo],
        recognizeText: @escaping @Sendable (CGImage, String) throws -> [ScreenOCRObservation]
    ) {
        self.frontmostBundleId = frontmostBundleId
        self.cleanupCaptureFiles = cleanupCaptureFiles
        self.captureImage = captureImage
        self.persistCaptureArtifact = persistCaptureArtifact
        self.displayMetadata = displayMetadata
        self.recognizeText = recognizeText
    }
}

extension ScreenModuleRuntime {
    /// Production-only composition. `internal` keeps the live factory hidden
    /// from the separate test target; only the explicitly gated probe below can
    /// route through it.
    internal static let live = ScreenModuleRuntime(
        frontmostBundleId: { ScreenModuleLive.frontmostBundleId() },
        cleanupCaptureFiles: { ScreenModuleLive.cleanupCaptureFiles() },
        captureImage: { request in try await ScreenModuleLive.captureImage(request) },
        persistCaptureArtifact: { image, format in
            try ScreenModuleLive.persistCaptureArtifact(image, format: format)
        },
        displayMetadata: { await ScreenModuleLive.displayMetadata() },
        recognizeText: { image, language in
            try ScreenModuleLive.recognizeText(image, language: language)
        }
    )
}

extension ScreenModule {
    /// Resolve a 0-based display index. Empty display list or out-of-range → nil (fail closed).
    public static func resolveDisplayIndex(_ requested: Int?, displayCount: Int) -> Int? {
        guard displayCount > 0 else { return nil }
        let index = requested ?? 0
        guard index >= 0, index < displayCount else { return nil }
        return index
    }

    /// Explicit opt-in bridge for the non-canonical live OCR probe. Canonical
    /// tests cannot accidentally register live dependencies because this path
    /// refuses to run unless the dedicated environment switch is present.
    package static func registerLiveProbe(on router: ToolRouter) async -> Bool {
        guard ProcessInfo.processInfo.environment["BRIDGE_SCREEN_LIVE_PROBE"] == "1" else {
            return false
        }
        await register(on: router, runtime: .live)
        return true
    }
}

/// Live macOS implementation. Handler registration and response assembly do
/// not call these frameworks or side effects directly.
private enum ScreenModuleLive {
    @MainActor
    static func frontmostBundleId() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    static func cleanupCaptureFiles() {
        let resolved = ConfigManager.shared.resolvedScreenOutputDir()
        // End-of-day local retention for b-W.D-NN.*; never wipes today's sequence.
        ScreenArtifactNaming.cleanup(in: resolved.path)
    }

    private static func getShareableContent() async throws -> SCShareableContent {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenModuleError.screenRecordingDenied
        }
        return try await SCKBoundary.fetchShareableContent()
    }

    @MainActor
    static func captureImage(_ request: ScreenCaptureRequest) async throws -> CGImage {
        let content = try await getShareableContent()

        switch request.target {
        case "window":
            let candidates = content.windows.map { window in
                ScreenModule.WindowCandidate(
                    windowId: Int(window.windowID),
                    bundleId: window.owningApplication?.bundleIdentifier,
                    appName: window.owningApplication?.applicationName
                )
            }
            let windowId: Int
            switch ScreenModule.resolveWindowTarget(
                windowId: request.windowId,
                bundleId: request.bundleId,
                appName: request.appName,
                candidates: candidates
            ) {
            case .selected(let selected):
                windowId = selected
            case .missingIdentity:
                throw ScreenModuleError.missingParameter(
                    "windowId, bundleId, or appName required for window target"
                )
            case .windowIdNotFound(let id):
                throw ScreenModuleError.windowNotFound(id)
            case .appNotFound(let query, let available):
                throw ScreenModuleError.windowNotFoundForApp(query: query, available: available)
            case .ambiguous(let query, let matches):
                throw ScreenModuleError.ambiguousWindowsForApp(query: query, matches: matches)
            }
            guard let window = content.windows.first(where: { $0.windowID == CGWindowID(windowId) }) else {
                throw ScreenModuleError.windowNotFound(windowId)
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width) * 2
            config.height = Int(window.frame.height) * 2
            config.scalesToFit = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        case "region":
            guard let region = request.region else {
                throw ScreenModuleError.missingParameter("region {x,y,w,h} required for region target")
            }
            guard !content.displays.isEmpty else {
                throw ScreenModuleError.noDisplays
            }
            guard let index = ScreenModule.resolveDisplayIndex(request.displayIndex, displayCount: content.displays.count) else {
                let available = content.displays.enumerated()
                    .map { "\($0.offset): \($0.element.width)x\($0.element.height)" }
                    .joined(separator: ", ")
                throw ScreenModuleError.missingParameter(
                    "displayIndex \(request.displayIndex ?? 0) out of range. Available: [\(available)]"
                )
            }
            let display = content.displays[index]
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(
                x: region.x,
                y: region.y,
                width: region.width,
                height: region.height
            )
            config.width = region.width
            config.height = region.height
            config.scalesToFit = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        case "all_displays":
            guard content.displays.count > 1 else {
                throw ScreenModuleError.missingParameter(
                    "all_displays requires 2+ displays; found \(content.displays.count)"
                )
            }
            var images: [CGImage] = []
            for display in content.displays {
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = display.width * 2
                config.height = display.height * 2
                config.scalesToFit = false
                images.append(
                    try await SCScreenshotManager.captureImage(
                        contentFilter: filter,
                        configuration: config
                    )
                )
            }
            let totalWidth = images.reduce(0) { $0 + $1.width }
            let maxHeight = images.map(\.height).max() ?? 0
            guard let context = CGContext(
                data: nil,
                width: totalWidth,
                height: maxHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            ) else {
                throw ScreenModuleError.captureFailed(
                    "Failed to create composite CGContext (\(totalWidth)x\(maxHeight))"
                )
            }
            var xOffset = 0
            for image in images {
                context.draw(
                    image,
                    in: CGRect(
                        x: xOffset,
                        y: maxHeight - image.height,
                        width: image.width,
                        height: image.height
                    )
                )
                xOffset += image.width
            }
            guard let composite = context.makeImage() else {
                throw ScreenModuleError.captureFailed("Failed to finalize composite image")
            }
            return composite

        default:
            guard !content.displays.isEmpty else {
                throw ScreenModuleError.noDisplays
            }
            guard let index = ScreenModule.resolveDisplayIndex(request.displayIndex, displayCount: content.displays.count) else {
                let available = content.displays.enumerated()
                    .map { "\($0.offset): \($0.element.width)x\($0.element.height)" }
                    .joined(separator: ", ")
                throw ScreenModuleError.missingParameter(
                    "displayIndex \(request.displayIndex ?? 0) out of range. Available: [\(available)]"
                )
            }
            let display = content.displays[index]
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width * 2
            config.height = display.height * 2
            config.scalesToFit = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
    }

    static func persistCaptureArtifact(_ image: CGImage, format: String) throws -> ScreenCaptureArtifact {
        let fileExtension = format == "jpg" ? "jpg" : "png"
        let resolved = ConfigManager.shared.resolvedScreenOutputDir()
        let filePath = ScreenArtifactNaming.allocatePath(
            directory: resolved.path,
            ext: fileExtension
        )

        do {
            try writeImage(image, format: format, to: filePath)
        } catch let error as ScreenModuleError {
            try? FileManager.default.removeItem(atPath: filePath)
            throw error
        } catch {
            try? FileManager.default.removeItem(atPath: filePath)
            throw ScreenModuleError.captureFailed(
                "Failed to write image to \(filePath): \(error.localizedDescription)"
            )
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: filePath)[.size] as? Int) ?? 0
        return ScreenCaptureArtifact(
            filePath: filePath,
            width: image.width,
            height: image.height,
            bytes: fileSize,
            format: format,
            isFallback: resolved.isFallback
        )
    }

    @MainActor
    static func displayMetadata() async -> [ScreenDisplayInfo] {
        guard let content = try? await SCKBoundary.fetchShareableContent() else {
            return []
        }
        return content.displays.enumerated().map { index, display in
            ScreenDisplayInfo(
                index: index,
                width: display.width,
                height: display.height,
                isMain: index == 0
            )
        }
    }

    static func recognizeText(_ image: CGImage, language: String) throws -> [ScreenOCRObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [language]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        return (request.results ?? []).map { observation in
            let candidate = observation.topCandidates(1).first.map {
                ScreenOCRCandidate(text: $0.string, confidence: $0.confidence)
            }
            return ScreenOCRObservation(
                candidate: candidate,
                boundingBox: observation.boundingBox
            )
        }
    }

    private static func writeImage(_ image: CGImage, format: String, to path: String) throws {
        let url = URL(fileURLWithPath: path) as CFURL
        let utType: CFString = format == "jpg"
            ? UTType.jpeg.identifier as CFString
            : UTType.png.identifier as CFString

        guard let destination = CGImageDestinationCreateWithURL(url, utType, 1, nil) else {
            throw ScreenModuleError.encodingFailed(format)
        }

        let options: [CFString: Any] = format == "jpg"
            ? [kCGImageDestinationLossyCompressionQuality: 0.8]
            : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ScreenModuleError.encodingFailed(format)
        }
    }
}
