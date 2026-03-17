// ScreenModule.swift – V3-SCREEN-001 Screen Capture & OCR Tools
// NotionBridge · Modules
//
// Two read-only tools: screen_capture (Open), screen_ocr (Open).
// Uses ScreenCaptureKit for capture, Vision framework for OCR.
// Both classified as Open tier (read-only, zero side effects).
// PKT-354: Pull-forward of Phase 4 ScreenModule — read tools only.
//
// Frameworks:
//   - ScreenCaptureKit: SCScreenshotManager.captureImage for screenshots
//   - Vision: VNRecognizeTextRequest for OCR
//   - ImageIO: CGImageDestination for PNG/JPEG encoding (Sendable-safe)
//   - CoreGraphics: CGPreflightScreenCaptureAccess for TCC detection
//
// Capture files: /tmp/nb-screen-<timestamp>.<ext>
// Cleanup: On each screen_capture call, delete files >1hr old, cap at 20.

import Foundation
import MCP
import ScreenCaptureKit
import CoreGraphics
import Vision
import ImageIO
import UniformTypeIdentifiers

// MARK: - ScreenModule

/// Provides screen capture and OCR tools using ScreenCaptureKit + Vision.
public enum ScreenModule {

    public static let moduleName = "screen"

    // MARK: - Cleanup

    /// Best-effort cleanup of old capture files.
    /// Deletes nb-screen-* files older than 1 hour, then caps at 20 remaining.
    /// Failures are logged but never block the capture operation.
    private static func cleanupCaptureFiles() {
        let tmpDir = "/tmp"
        let prefix = "nb-screen-"
        let oneHourAgo = Date().addingTimeInterval(-3600)
        let fm = FileManager.default

        do {
            let allFiles = try fm.contentsOfDirectory(atPath: tmpDir)
            let captureFiles = allFiles.filter { $0.hasPrefix(prefix) }

            // Phase 1: Delete files older than 1 hour
            for name in captureFiles {
                let path = "\(tmpDir)/\(name)"
                if let attrs = try? fm.attributesOfItem(atPath: path),
                   let modified = attrs[.modificationDate] as? Date,
                   modified < oneHourAgo {
                    try? fm.removeItem(atPath: path)
                }
            }

            // Phase 2: Cap at 20 files (delete oldest first)
            let remaining = try fm.contentsOfDirectory(atPath: tmpDir)
                .filter { $0.hasPrefix(prefix) }
                .compactMap { name -> (path: String, date: Date)? in
                    let path = "\(tmpDir)/\(name)"
                    guard let attrs = try? fm.attributesOfItem(atPath: path),
                          let modified = attrs[.modificationDate] as? Date else { return nil }
                    return (path: path, date: modified)
                }
                .sorted { $0.date < $1.date }

            if remaining.count > 20 {
                for file in remaining.prefix(remaining.count - 20) {
                    try? fm.removeItem(atPath: file.path)
                }
            }
        } catch {
            // Best-effort — never block capture
        }
    }

    // MARK: - Capture Helpers

    /// Verify Screen Recording TCC grant and fetch shareable content.
    /// Uses CGPreflightScreenCaptureAccess() only — never CGRequestScreenCaptureAccess()
    /// (which opens a modal dialog, inappropriate at tool-call time).
    private static func getShareableContent() async throws -> SCShareableContent {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenModuleError.screenRecordingDenied
        }
        return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// Capture a CGImage based on target parameters.
    private static func captureImage(
        target: String,
        windowId: Int?,
        region: (x: Int, y: Int, w: Int, h: Int)?
    ) async throws -> CGImage {
        let content = try await getShareableContent()

        switch target {
        case "window":
            guard let wid = windowId else {
                throw ScreenModuleError.missingParameter("windowId required for window target")
            }
            guard let window = content.windows.first(where: { $0.windowID == CGWindowID(wid) }) else {
                throw ScreenModuleError.windowNotFound(wid)
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.scalesToFit = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        case "region":
            guard let r = region else {
                throw ScreenModuleError.missingParameter("region {x,y,w,h} required for region target")
            }
            guard let display = content.displays.first else {
                throw ScreenModuleError.noDisplays
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: r.x, y: r.y, width: r.w, height: r.h)
            config.width = r.w
            config.height = r.h
            config.scalesToFit = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        default: // "display"
            guard let display = content.displays.first else {
                throw ScreenModuleError.noDisplays
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.scalesToFit = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
    }

    /// Encode a CGImage to disk as PNG or JPEG using ImageIO (Sendable-safe, no AppKit).
    private static func writeImage(_ cgImage: CGImage, format: String, to path: String) throws {
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
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ScreenModuleError.encodingFailed(format)
        }
    }

    // MARK: - Registration

    /// Register all ScreenModule tools on the given router.
    public static func register(on router: ToolRouter) async {

        // MARK: 1. screen_capture – Open (read-only)
        await router.register(ToolRegistration(
            name: "screen_capture",
            module: moduleName,
            tier: .open,
            description: "Capture a screenshot of the display, a specific window, or a region. Returns the file path, dimensions, and file size. Uses ScreenCaptureKit (requires Screen Recording permission).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "target": .object([
                        "type": .string("string"),
                        "description": .string("Capture target: 'display', 'window', or 'region' (default: 'display')"),
                        "enum": .array([.string("display"), .string("window"), .string("region")])
                    ]),
                    "windowId": .object([
                        "type": .string("integer"),
                        "description": .string("Window ID to capture (required when target is 'window')")
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
                let region: (x: Int, y: Int, w: Int, h: Int)? = {
                    if case .object(let r) = args["region"],
                       case .int(let x) = r["x"],
                       case .int(let y) = r["y"],
                       case .int(let w) = r["w"],
                       case .int(let h) = r["h"] {
                        return (x: x, y: y, w: w, h: h)
                    }
                    return nil
                }()
                let format: String = {
                    if case .string(let f) = args["format"] { return f }
                    return "png"
                }()

                // Cleanup old capture files (best-effort, never blocks)
                cleanupCaptureFiles()

                // Capture
                let cgImage: CGImage
                do {
                    cgImage = try await captureImage(target: target, windowId: windowId, region: region)
                } catch let error as ScreenModuleError {
                    return error.toResponse()
                } catch {
                    return ScreenModuleError.captureFailed("Screen capture failed: \(error.localizedDescription)").toResponse()
                }

                // Encode to file
                let ext = format == "jpg" ? "jpg" : "png"
                let timestamp = Int(Date().timeIntervalSince1970 * 1000)
                let filePath = "/tmp/nb-screen-\(timestamp).\(ext)"

                do {
                    try writeImage(cgImage, format: format, to: filePath)
                } catch let error as ScreenModuleError {
                    return error.toResponse()
                } catch {
                    return ScreenModuleError.captureFailed("Failed to write image to \(filePath): \(error.localizedDescription)").toResponse()
                }

                let fileSize = (try? FileManager.default.attributesOfItem(atPath: filePath)[.size] as? Int) ?? 0

                return .object([
                    "filePath": .string(filePath),
                    "width": .int(cgImage.width),
                    "height": .int(cgImage.height),
                    "bytes": .int(fileSize),
                    "format": .string(format)
                ])
            }
        ))

        // MARK: 2. screen_ocr – Open (read-only)
        await router.register(ToolRegistration(
            name: "screen_ocr",
            module: moduleName,
            tier: .open,
            description: "Capture the screen and extract text via OCR (Vision framework). Returns recognized text with confidence scores and bounding boxes. Uses ScreenCaptureKit for capture + VNRecognizeTextRequest for text recognition.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "target": .object([
                        "type": .string("string"),
                        "description": .string("Capture target: 'display', 'window', or 'region' (default: 'display')"),
                        "enum": .array([.string("display"), .string("window"), .string("region")])
                    ]),
                    "windowId": .object([
                        "type": .string("integer"),
                        "description": .string("Window ID to capture (required when target is 'window')")
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
                let region: (x: Int, y: Int, w: Int, h: Int)? = {
                    if case .object(let r) = args["region"],
                       case .int(let x) = r["x"],
                       case .int(let y) = r["y"],
                       case .int(let w) = r["w"],
                       case .int(let h) = r["h"] {
                        return (x: x, y: y, w: w, h: h)
                    }
                    return nil
                }()
                let language: String = {
                    if case .string(let l) = args["language"] { return l }
                    return "en"
                }()

                // Capture screen
                let cgImage: CGImage
                do {
                    cgImage = try await captureImage(target: target, windowId: windowId, region: region)
                } catch let error as ScreenModuleError {
                    return error.toResponse()
                } catch {
                    return ScreenModuleError.captureFailed("Screen capture failed: \(error.localizedDescription)").toResponse()
                }

                // Run Vision OCR
                do {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = [language]
                    request.usesLanguageCorrection = true

                    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                    try handler.perform([request])

                    guard let observations = request.results, !observations.isEmpty else {
                        // Empty result is valid (blank screen, no visible text) — not an error
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
                        guard let candidate = observation.topCandidates(1).first else { continue }
                        fullText += candidate.string + "\n"
                        totalConfidence += candidate.confidence

                        let box = observation.boundingBox
                        bounds.append(.object([
                            "text": .string(candidate.string),
                            "confidence": .double(Double(candidate.confidence)),
                            "rect": .object([
                                "x": .double(box.origin.x),
                                "y": .double(box.origin.y),
                                "width": .double(box.size.width),
                                "height": .double(box.size.height)
                            ])
                        ]))
                    }

                    let avgConfidence = Double(totalConfidence) / Double(observations.count)

                    return .object([
                        "text": .string(fullText.trimmingCharacters(in: .whitespacesAndNewlines)),
                        "confidence": .double((avgConfidence * 1000).rounded() / 1000),
                        "bounds": .array(bounds)
                    ])
                } catch {
                    return .object([
                        "error": .string("ocr_failed"),
                        "message": .string("Vision text recognition failed: \(error.localizedDescription)")
                    ])
                }
            }
        ))
    }
}

// MARK: - Errors

/// Structured error types for ScreenModule — all return JSON responses, never crash.
private enum ScreenModuleError: Error {
    case screenRecordingDenied
    case noDisplays
    case windowNotFound(Int)
    case missingParameter(String)
    case encodingFailed(String)
    case captureFailed(String)

    func toResponse() -> Value {
        switch self {
        case .screenRecordingDenied:
            return .object([
                "error": .string("screen_recording_denied"),
                "message": .string("Screen Recording permission not granted. Open System Settings > Privacy & Security > Screen Recording and enable NotionBridge.")
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
}
