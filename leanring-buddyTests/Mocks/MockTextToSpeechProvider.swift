//
//  MockTextToSpeechProvider.swift
//  leanring-buddyTests
//
//  Mock implementation of TextToSpeechProvider logging spoken sentences and session state.
//

import Foundation
@testable import leanring_buddy

@MainActor
final class MockTextToSpeechProvider: TextToSpeechProvider {
    var displayName: String = "MockTTSProvider"
    var isPlaying: Bool = false
    var hasCurrentSessionStartedAudio: Bool = false

    var spokenTexts: [String] = []
    var enqueuedSentences: [String] = []

    var prepareCallCount: Int = 0
    var shutdownCallCount: Int = 0
    var stopPlaybackCallCount: Int = 0
    var finishSpeechSessionCallCount: Int = 0

    var selectedVoiceName: String = "default"
    var selectedModelName: String = "default"
    var selectedLanguageCode: String = "de"
    var selectedSpeechRateMultiplier: Double = 1.0

    private var onFirstAudioStartedCallback: (() -> Void)?
    private var onPlaybackFinishedCallback: (() -> Void)?

    func prepare() {
        prepareCallCount += 1
    }

    func shutdown() {
        shutdownCallCount += 1
    }

    func beginSpeechSession(
        onFirstAudioStarted: @escaping () -> Void,
        onPlaybackFinished: (() -> Void)?
    ) {
        isPlaying = true
        hasCurrentSessionStartedAudio = false
        onFirstAudioStartedCallback = onFirstAudioStarted
        onPlaybackFinishedCallback = onPlaybackFinished
    }

    func enqueueSentenceForSpeech(_ sentenceText: String) {
        enqueuedSentences.append(sentenceText)
        spokenTexts.append(sentenceText)

        if !hasCurrentSessionStartedAudio {
            hasCurrentSessionStartedAudio = true
            onFirstAudioStartedCallback?()
        }
    }

    func finishSpeechSession() {
        finishSpeechSessionCallCount += 1
        isPlaying = false
        onPlaybackFinishedCallback?()
    }

    func stopPlayback() {
        stopPlaybackCallCount += 1
        isPlaying = false
        hasCurrentSessionStartedAudio = false
        enqueuedSentences.removeAll()
        onPlaybackFinishedCallback?()
    }

    func setVoiceName(_ voiceName: String) {
        selectedVoiceName = voiceName
    }

    func setModelName(_ modelName: String) {
        selectedModelName = modelName
    }

    func setLanguageCode(_ languageCode: String) {
        selectedLanguageCode = languageCode
    }

    func setSpeechRateMultiplier(_ rateMultiplier: Double) {
        selectedSpeechRateMultiplier = rateMultiplier
    }
}
