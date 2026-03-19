// ScreenRecording.swift – PKT-356: Screen Recording Tools
// NotionBridge · Modules
//
// Extension of ScreenModule with 2 recording tools:
//   screen_record_start (notify), screen_record_stop (notify).
// Uses SCStream with SCStreamOutput delegate writing to AVAssetWriter.
// Recording state managed by actor-isolated RecordingManager.
// Files written to /tmp/nb-screen-<timestamp>.mp4 (same cleanup pattern as capture).

import MCP
import ScreenCaptureKit
import CoreMedia
import AVFoundation

// MARK: - ScreenModule Recording Extension

extension ScreenModule {

    /// Register screen recording tools on the given router.
    public static func registerRecording(on router: ToolRouter) async {

        // MARK: screen_record_start – Notify (write)
        await router.register(ToolRegistration(
            name: "screen_record_start",
            module: moduleName,
            tier: .notify,
            description: "Begin screen recording via SCStream + AVAssetWriter. Returns output file path. Safety cap default 60s (max 300s). Only one recording at a time.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "safetyCap": .object([
                        "type": .string("integer"),
                        "description": .string("Max recording duration in seconds (default: 60, max: 300). Recording auto-stops after this.")
                    ])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let args: [String: Value] = {
                    if case .object(let a) = arguments { return a }
                    return [:]
                }()

                var cap: TimeInterval = 60
                if case .int(let c) = args["safetyCap"] { cap = min(TimeInterval(c), 300) }
                else if case .double(let c) = args["safetyCap"] { cap = min(c, 300) }

                do {
                    let result = try await RecordingManager.shared.start(safetyCap: cap)
                    return .object([
                        "status":          .string("recording"),
                        "filePath":        .string(result.path),
                        "width":           .int(result.width),
                        "height":          .int(result.height),
                        "safetyCapSeconds": .int(Int(cap))
                    ])
                } catch let error as RecordingError {
                    return error.toResponse()
                } catch {
                    return .object([
                        "error":   .string("recording_start_failed"),
                        "message": .string("Failed to start recording: \(error.localizedDescription)")
                    ])
                }
            }
        ))

        // MARK: screen_record_stop – Notify (write)
        await router.register(ToolRegistration(
            name: "screen_record_stop",
            module: moduleName,
            tier: .notify,
            description: "Stop the active screen recording. Returns file path, duration in seconds, and file size in bytes.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            handler: { _ in
                do {
                    let result = try await RecordingManager.shared.stop()
                    return .object([
                        "filePath":        .string(result.path),
                        "durationSeconds": .double((result.duration * 100).rounded() / 100),
                        "bytes":           .int(Int(result.bytes))
                    ])
                } catch let error as RecordingError {
                    return error.toResponse()
                } catch {
                    return .object([
                        "error":   .string("recording_stop_failed"),
                        "message": .string("Failed to stop recording: \(error.localizedDescription)")
                    ])
                }
            }
        ))
    }
}

// MARK: - Recording Errors

/// Structured error types for screen recording operations.
private enum RecordingError: Error {
    case screenRecordingDenied
    case noDisplays
    case recordingAlreadyActive
    case noActiveRecording
    case writerSetupFailed(String)

    func toResponse() -> Value {
        switch self {
        case .screenRecordingDenied:
            return .object([
                "error":   .string("screen_recording_denied"),
                "message": .string("Screen Recording permission not granted. Open System Settings > Privacy & Security > Screen Recording and enable NotionBridge.")
            ])
        case .noDisplays:
            return .object([
                "error":   .string("no_displays"),
                "message": .string("No capturable displays found.")
            ])
        case .recordingAlreadyActive:
            return .object([
                "error":   .string("recording_already_active"),
                "message": .string("A screen recording is already in progress. Stop it first with screen_record_stop.")
            ])
        case .noActiveRecording:
            return .object([
                "error":   .string("no_active_recording"),
                "message": .string("No screen recording is currently active.")
            ])
        case .writerSetupFailed(let detail):
            return .object([
                "error":   .string("writer_setup_failed"),
                "message": .string("AVAssetWriter setup failed: \(detail)")
            ])
        }
    }
}

// MARK: - Recording Delegate

/// SCStreamOutput delegate that receives sample buffers and writes them to AVAssetWriter.
/// Thread safety: uses NSLock for the session-start flag (delegate runs on a GCD queue).
private class RecordingDelegate: NSObject, SCStreamOutput, @unchecked Sendable {
    let writerInput: AVAssetWriterInput
    let writer: AVAssetWriter
    private var sessionStarted = false
    private let lock = NSLock()

    init(writerInput: AVAssetWriterInput, writer: AVAssetWriter) {
        self.writerInput = writerInput
        self.writer = writer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        // Start AVAssetWriter session at first frame's timestamp
        lock.lock()
        if !sessionStarted {
            let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: ts)
            sessionStarted = true
        }
        lock.unlock()

        guard writerInput.isReadyForMoreMediaData else { return }
        writerInput.append(sampleBuffer)
    }
}

// MARK: - Recording Manager Actor

/// Actor-isolated manager ensuring only one recording session at a time.
/// Handles SCStream lifecycle, AVAssetWriter pipeline, and safety-cap auto-stop.
private actor RecordingManager {
    static let shared = RecordingManager()

    struct ActiveRecording {
        let stream: SCStream
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let delegate: RecordingDelegate
        let outputPath: String
        let startTime: Date
        var safetyTask: Task<Void, Never>?
    }

    private var recording: ActiveRecording?

    var isRecording: Bool { recording != nil }

    /// Start a new screen recording. Returns (filePath, width, height).
    func start(safetyCap: TimeInterval) async throws -> (path: String, width: Int, height: Int) {
        guard recording == nil else {
            throw RecordingError.recordingAlreadyActive
        }

        // Verify Screen Recording TCC
        guard CGPreflightScreenCaptureAccess() else {
            throw RecordingError.screenRecordingDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw RecordingError.noDisplays
        }

        let width = display.width
        let height = display.height

        // Output file (same /tmp/nb-screen-* pattern as captures)
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let outputPath = "/tmp/nb-screen-\(timestamp).mp4"
        let outputURL = URL(fileURLWithPath: outputPath)

        // AVAssetWriter + H.264 video input
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw RecordingError.writerSetupFailed(error.localizedDescription)
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()
        // Note: startSession(atSourceTime:) is called by RecordingDelegate on first frame

        // SCStream configuration
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)  // 30 fps
        config.queueDepth = 5
        config.showsCursor = true

        let delegate = RecordingDelegate(writerInput: input, writer: writer)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(delegate, type: .screen,
                                    sampleHandlerQueue: .global(qos: .userInitiated))

        try await stream.startCapture()

        // Safety cap: auto-stop after safetyCap seconds
        let safetyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(safetyCap))
            guard let self else { return }
            if await self.isRecording {
                _ = try? await self.stop()
                print("[ScreenModule] Recording auto-stopped after \(Int(safetyCap))s safety cap")
            }
        }

        recording = ActiveRecording(
            stream: stream, writer: writer, input: input,
            delegate: delegate, outputPath: outputPath,
            startTime: Date(), safetyTask: safetyTask
        )

        return (path: outputPath, width: width, height: height)
    }

    /// Stop the active recording. Returns (filePath, durationSeconds, bytes).
    func stop() async throws -> (path: String, duration: Double, bytes: Int64) {
        guard let rec = recording else {
            throw RecordingError.noActiveRecording
        }
        recording = nil
        rec.safetyTask?.cancel()

        // Stop capture, finalize writer
        try await rec.stream.stopCapture()
        rec.input.markAsFinished()
        await rec.writer.finishWriting()

        let duration = Date().timeIntervalSince(rec.startTime)
        let attrs = try FileManager.default.attributesOfItem(atPath: rec.outputPath)
        let bytes = (attrs[.size] as? Int64) ?? 0

        return (path: rec.outputPath, duration: duration, bytes: bytes)
    }
}
