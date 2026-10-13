//
//  WhisperCPPTranscriptionProvider.swift
//  leanring-buddy
//
//  Local on-device transcription provider backed by whisper.cpp and large-v3-turbo model.
//  Runs 100% locally with high precision for German and multilingual audio.
//

import AVFoundation
import Foundation

struct WhisperCPPTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class WhisperCPPTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Whisper C++"
    let requiresSpeechRecognitionPermission = false

    /// Resolved path to whisper-cli executable.
    private static var whisperCLIPath: String? {
        let candidatePaths = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli"
        ]
        return candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Resolved path to the downloaded large-v3-turbo model file.
    private static var modelFilePath: String? {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let candidateModelURLs = [
            homeDirectory.appendingPathComponent("Library/Application Support/Clicky/models/ggml-large-v3-turbo.bin"),
            URL(fileURLWithPath: "models/ggml-large-v3-turbo.bin")
        ]
        return candidateModelURLs.first { FileManager.default.fileExists(atPath: $0.path) }?.path
    }

    var isConfigured: Bool {
        return Self.whisperCLIPath != nil && Self.modelFilePath != nil
    }

    var unavailableExplanation: String? {
        if Self.whisperCLIPath == nil {
            return "whisper-cli is not installed. Run 'brew install whisper-cpp'."
        }
        if Self.modelFilePath == nil {
            return "Whisper Large-V3-Turbo model not found in ~/Library/Application Support/Clicky/models/ggml-large-v3-turbo.bin."
        }
        return nil
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard let cliPath = Self.whisperCLIPath, let modelPath = Self.modelFilePath else {
            throw WhisperCPPTranscriptionProviderError(
                message: unavailableExplanation ?? "Whisper C++ is not configured."
            )
        }

        return WhisperCPPTranscriptionSession(
            whisperCLIPath: cliPath,
            modelFilePath: modelPath,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

private final class WhisperCPPTranscriptionSession: BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 10.0

    private static let targetSampleRate: Double = 16_000.0

    private let whisperCLIPath: String
    private let modelFilePath: String
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let audioPCM16Converter = BuddyPCM16AudioConverter(
        targetSampleRate: targetSampleRate
    )
    private let synchronizationQueue = DispatchQueue(label: "com.learningbuddy.whispercpp.transcription")

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var executionProcess: Process?

    init(
        whisperCLIPath: String,
        modelFilePath: String,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.whisperCLIPath = whisperCLIPath
        self.modelFilePath = modelFilePath
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        synchronizationQueue.sync {
            guard !hasRequestedFinalTranscript && !isCancelled else { return }
            guard let convertedPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer) else { return }
            bufferedPCM16AudioData.append(convertedPCM16Data)
        }
    }

    func requestFinalTranscript() {
        synchronizationQueue.sync {
            guard !hasRequestedFinalTranscript && !isCancelled else { return }
            hasRequestedFinalTranscript = true

            guard !bufferedPCM16AudioData.isEmpty else {
                deliverFinalTranscriptIfNeeded("")
                return
            }

            let audioDataSnapshot = bufferedPCM16AudioData
            Task {
                await performWhisperTranscription(withPCM16AudioData: audioDataSnapshot)
            }
        }
    }

    func cancel() {
        synchronizationQueue.sync {
            isCancelled = true
            executionProcess?.terminate()
            executionProcess = nil
        }
    }

    private func performWhisperTranscription(withPCM16AudioData pcm16AudioData: Data) async {
        // Build 16kHz mono WAV file
        let wavData = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: pcm16AudioData,
            sampleRate: Int(Self.targetSampleRate)
        )

        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
        let temporaryWavFileURL = temporaryDirectoryURL.appendingPathComponent("whisper_\(UUID().uuidString).wav")

        do {
            try wavData.write(to: temporaryWavFileURL)
        } catch {
            onError(error)
            return
        }

        defer {
            try? FileManager.default.removeItem(at: temporaryWavFileURL)
        }

        guard !isCancelled else { return }

        // Execute whisper-cli
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperCLIPath)
        process.arguments = [
            "-m", modelFilePath,
            "-f", temporaryWavFileURL.path,
            "-l", "auto",
            "-nt",
            "-np"
        ]

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        self.executionProcess = process

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            guard !isCancelled else { return }
            onError(error)
            return
        }

        guard !isCancelled else { return }

        let outputData = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        let rawTranscriptText = String(data: outputData, encoding: .utf8) ?? ""

        // Clean up output: remove special brackets like [BLANK_AUDIO] or timestamp markers
        let cleanedTranscript = rawTranscriptText
            .replacingOccurrences(of: "\\[_BEG_\\]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\[_TT_\\d+\\]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\[BLANK_AUDIO\\]", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        print("🎙️ Whisper C++ transcript: \"\(cleanedTranscript)\"")
        deliverFinalTranscriptIfNeeded(cleanedTranscript)
    }

    private func deliverFinalTranscriptIfNeeded(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }
}
