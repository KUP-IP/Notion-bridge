// VoiceMemoSpeechAnalyzer.swift — Apple SpeechAnalyzer (opt-in, default off)
// TheBridge · Modules · VoiceMemo
//
// Sits between Apple tsrp extraction and Parakeet on the transcription ladder.
// Does not download language assets automatically (skip when not installed).

import AVFoundation
import Foundation
import Speech

public enum VoiceMemoSpeechAnalyzer {

    /// Injectable hook for tests. Returns nil when SpeechAnalyzer is unavailable.
    public nonisolated(unsafe) static var transcribeFile: @Sendable (URL) async throws -> String? = { url in
        try await Live.transcribe(url)
    }

    private enum Live {
        static func transcribe(_ url: URL) async throws -> String? {
            let transcriber = SpeechTranscriber(locale: Locale.current, preset: .transcription)
            let status = await AssetInventory.status(forModules: [transcriber])
            guard status == .installed else { return nil }

            let audioFile = try AVAudioFile(forReading: url)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let consume = Task { () -> String in
                var parts: [String] = []
                for try await result in transcriber.results {
                    if result.isFinal {
                        parts.append(String(result.text.characters))
                    }
                }
                return parts.joined(separator: " ")
            }
            do {
                _ = try await analyzer.analyzeSequence(from: audioFile)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                let text = try await consume.value
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            } catch {
                consume.cancel()
                return nil
            }
        }
    }
}
