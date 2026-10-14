//
//  OrukeetTranscriptionProvider.swift
//  leanring-buddy
//
//  Local on-device transcription provider powered by Orukeet (Parakeet TDT v3).
//

import AVFoundation
import Foundation

struct OrukeetResponsePayload: Decodable {
    let lang: String?
    let text: String
}

struct OrukeetTranscriptionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class OrukeetTranscriptionProvider: BuddyTranscriptionProvider, @unchecked Sendable {
    let displayName = "Orukeet (Local)"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool {
        return OrukeetServerManager.shared.isConfigured
    }

    var unavailableExplanation: String? {
        if !isConfigured {
            return "Orukeet model files or sherpa-onnx binary not found."
        }
        return nil
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        let serverReady = await OrukeetServerManager.shared.ensureServerRunning()
        guard serverReady else {
            throw OrukeetTranscriptionError(message: "Failed to connect to or start Orukeet server on port \(OrukeetServerManager.shared.port).")
        }

        return OrukeetTranscriptionSession(
            port: OrukeetServerManager.shared.port,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

final class OrukeetTranscriptionSession: BuddyStreamingTranscriptionSession, @unchecked Sendable {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 8.0
    private static let targetSampleRate: Double = 16_000.0

    private let port: Int
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let audioFloat32Converter = BuddyFloat32AudioConverter(targetSampleRate: targetSampleRate)
    private let syncQueue = DispatchQueue(label: "com.learningbuddy.orukeet.session")

    private var bufferedFloat32Data = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var activeWebSocketTask: URLSessionWebSocketTask?

    init(
        port: Int,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.port = port
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        syncQueue.sync {
            guard !hasRequestedFinalTranscript && !isCancelled else { return }
            guard let floatData = audioFloat32Converter.convertToFloat32Data(from: audioBuffer) else { return }
            bufferedFloat32Data.append(floatData)
        }
    }

    func requestFinalTranscript() {
        let (audioSnapshot, isEmpty): (Data?, Bool) = syncQueue.sync {
            guard !hasRequestedFinalTranscript && !isCancelled else { return (nil, false) }
            hasRequestedFinalTranscript = true

            guard !bufferedFloat32Data.isEmpty else {
                return (nil, true)
            }
            return (bufferedFloat32Data, false)
        }

        if isEmpty {
            deliverFinalTranscriptIfNeeded("")
            return
        }

        guard let audioSnapshot else { return }

        Task {
            await sendAudioForTranscription(audioSnapshot)
        }
    }

    func cancel() {
        let taskToCancel = syncQueue.sync { () -> URLSessionWebSocketTask? in
            isCancelled = true
            let task = activeWebSocketTask
            activeWebSocketTask = nil
            return task
        }
        taskToCancel?.cancel(with: .normalClosure, reason: nil)
    }

    static func buildHeader(sampleRate: UInt32, byteLength: UInt32) -> Data {
        var header = Data()
        var sr = sampleRate.littleEndian
        var bl = byteLength.littleEndian
        header.append(Data(bytes: &sr, count: 4))
        header.append(Data(bytes: &bl, count: 4))
        return header
    }

    private var isSessionCancelled: Bool {
        syncQueue.sync { isCancelled }
    }

    private func sendAudioForTranscription(_ audioData: Data) async {
        guard let url = URL(string: "ws://127.0.0.1:\(port)") else {
            onError(OrukeetTranscriptionError(message: "Invalid WebSocket URL"))
            return
        }

        let session = URLSession(configuration: .default)
        let wsTask = session.webSocketTask(with: url)

        let cancelled = syncQueue.sync { () -> Bool in
            if isCancelled { return true }
            self.activeWebSocketTask = wsTask
            return false
        }

        guard !cancelled else {
            wsTask.cancel(with: .normalClosure, reason: nil)
            return
        }

        wsTask.resume()

        let header = Self.buildHeader(sampleRate: UInt32(Self.targetSampleRate), byteLength: UInt32(audioData.count))
        let payload = header + audioData

        // Stream payload in chunks of up to 10240 bytes
        let chunkSize = 10240
        var offset = 0
        while offset < payload.count {
            guard !isSessionCancelled else { return }
            let currentChunkSize = min(chunkSize, payload.count - offset)
            let chunk = payload.subdata(in: offset..<(offset + currentChunkSize))
            do {
                try await wsTask.send(.data(chunk))
            } catch {
                guard !isSessionCancelled else { return }
                onError(error)
                return
            }
            offset += currentChunkSize
        }

        guard !isSessionCancelled else { return }

        // Await decoded result
        do {
            let message = try await wsTask.receive()
            var rawText = ""
            switch message {
            case .string(let text):
                rawText = text
            case .data(let data):
                rawText = String(data: data, encoding: .utf8) ?? ""
            @unknown default:
                break
            }

            let transcript: String
            if let data = rawText.data(using: .utf8),
               let payload = try? JSONDecoder().decode(OrukeetResponsePayload.self, from: data) {
                transcript = payload.text
            } else {
                transcript = rawText
            }

            let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            print("🎙️ Orukeet transcript: \"\(cleaned)\"")

            // Send done & close
            _ = try? await wsTask.send(.string("Done"))
            wsTask.cancel(with: .normalClosure, reason: nil)

            deliverFinalTranscriptIfNeeded(cleaned)
        } catch {
            guard !isSessionCancelled else { return }
            onError(error)
        }
    }

    private func deliverFinalTranscriptIfNeeded(_ text: String) {
        let shouldDeliver = syncQueue.sync { () -> Bool in
            guard !hasDeliveredFinalTranscript else { return false }
            hasDeliveredFinalTranscript = true
            return true
        }
        if shouldDeliver {
            onFinalTranscriptReady(text)
        }
    }
}
