//
//  MockTranscriptionProvider.swift
//  leanring-buddyTests
//
//  Mock implementation of BuddyTranscriptionProvider and BuddyStreamingTranscriptionSession.
//

import AVFoundation
import Foundation
@testable import leanring_buddy

final class MockStreamingTranscriptionSession: BuddyStreamingTranscriptionSession {
    var finalTranscriptFallbackDelaySeconds: TimeInterval = 0.5
    var recordedAudioBuffers: [AVAudioPCMBuffer] = []
    var isCancelled: Bool = false
    var hasRequestedFinalTranscript: Bool = false

    var simulatedFinalTranscript: String = "Test Transkript"
    var onTranscriptUpdate: ((String) -> Void)?
    var onFinalTranscriptReady: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        recordedAudioBuffers.append(audioBuffer)
    }

    func requestFinalTranscript() {
        hasRequestedFinalTranscript = true
        onFinalTranscriptReady?(simulatedFinalTranscript)
    }

    func cancel() {
        isCancelled = true
    }

    func simulatePartialTranscript(_ partialTranscript: String) {
        onTranscriptUpdate?(partialTranscript)
    }
}

final class MockTranscriptionProvider: BuddyTranscriptionProvider {
    var displayName: String = "MockTranscriptionProvider"
    var requiresSpeechRecognitionPermission: Bool = false
    var isConfigured: Bool = true
    var unavailableExplanation: String? = nil

    var simulatedFinalTranscript: String = "Test Transkript"
    var shouldThrowOnStartSession: Bool = false
    var simulatedSessionError: Error? = nil

    var startSessionCallCount: Int = 0
    var recordedKeyterms: [[String]] = []
    var latestSession: MockStreamingTranscriptionSession?

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        startSessionCallCount += 1
        recordedKeyterms.append(keyterms)

        if shouldThrowOnStartSession {
            let errorToThrow = simulatedSessionError ?? NSError(
                domain: "MockTranscriptionProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Simulated transcription start error"]
            )
            onError(errorToThrow)
            throw errorToThrow
        }

        let session = MockStreamingTranscriptionSession()
        session.simulatedFinalTranscript = simulatedFinalTranscript
        session.onTranscriptUpdate = onTranscriptUpdate
        session.onFinalTranscriptReady = onFinalTranscriptReady
        session.onError = onError
        latestSession = session
        return session
    }
}
