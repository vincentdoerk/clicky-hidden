//
//  CoreProtocolsTests.swift
//  leanring-buddyTests
//
//  Unit tests verifying core protocols, settings storage, and test mock infrastructure.
//

import Foundation
import Testing
@testable import leanring_buddy

struct CoreProtocolsTests {

    @Test func mockSettingsStorageStoresAndRetrievesValues() async throws {
        let storage = MockSettingsStorage()
        storage.set("test-model", forKey: "selectedModel")
        #expect(storage.string(forKey: "selectedModel") == "test-model")

        storage.set(1.25, forKey: "speed")
        #expect(storage.double(forKey: "speed") == 1.25)

        storage.set(true, forKey: "isEnabled")
        #expect(storage.bool(forKey: "isEnabled") == true)

        storage.set(nil, forKey: "selectedModel")
        #expect(storage.string(forKey: "selectedModel") == nil)
    }

    @Test func userDefaultsSettingsStorageStoresAndRetrievesValues() async throws {
        let testSuiteName = "com.clicky.tests.settingsStorage.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: testSuiteName)!
        defer {
            testDefaults.removePersistentDomain(forName: testSuiteName)
        }

        let storage: SettingsStoring = UserDefaultsSettingsStorage(defaults: testDefaults)
        storage.set("qwen2.5-vl", forKey: "preferredVisionModel")
        #expect(storage.string(forKey: "preferredVisionModel") == "qwen2.5-vl")

        storage.set(1.5, forKey: "playbackRate")
        #expect(storage.double(forKey: "playbackRate") == 1.5)

        storage.set(true, forKey: "hasFinishedOnboarding")
        #expect(storage.bool(forKey: "hasFinishedOnboarding") == true)
    }

    @Test func mockPermissionsManagerReportsGrantedState() async throws {
        let permissions = MockPermissionsManager()
        permissions.allPermissionsGranted = true
        #expect(permissions.allPermissionsGranted)

        var didTriggerChange = false
        permissions.startPolling {
            didTriggerChange = true
        }
        #expect(permissions.isPolling)

        permissions.simulatePermissionChange()
        #expect(didTriggerChange)

        permissions.stopPolling()
        #expect(!permissions.isPolling)
    }

    @Test func mockVisionChatServiceStreamsChunksAndProvidesModels() async throws {
        let visionService = MockVisionChatService()
        visionService.availableModels = ["mock-model-a", "mock-model-b"]
        let models = try await visionService.fetchAvailableModels()
        #expect(models == ["mock-model-a", "mock-model-b"])

        visionService.streamedResponseChunks = ["chunk-1", "chunk-2"]
        let stream = try await visionService.streamChat(
            prompt: "Test prompt",
            screenCaptures: [],
            history: []
        )

        var receivedChunks: [String] = []
        for try await chunk in stream {
            receivedChunks.append(chunk)
        }
        #expect(receivedChunks == ["chunk-1", "chunk-2"])
        #expect(visionService.recordedPrompts == ["Test prompt"])
    }

    @Test func mockScreenCaptureUtilityReturnsCaptures() async throws {
        let captureUtility: ScreenCapturing = MockScreenCaptureUtility()
        let captures = try await captureUtility.captureScreens()

        #expect(!captures.isEmpty)
        #expect(captures.first?.label == "Mock Display 1")
    }

    @Test @MainActor func mockTextToSpeechProviderTracksSpokenSentences() async throws {
        let ttsProvider = MockTextToSpeechProvider()
        ttsProvider.prepare()
        #expect(ttsProvider.prepareCallCount == 1)

        var didStartAudio = false
        var didFinishPlayback = false

        ttsProvider.beginSpeechSession(
            onFirstAudioStarted: { didStartAudio = true },
            onPlaybackFinished: { didFinishPlayback = true }
        )
        #expect(ttsProvider.isPlaying)

        ttsProvider.enqueueSentenceForSpeech("Erster Satz.")
        #expect(didStartAudio)
        #expect(ttsProvider.spokenTexts == ["Erster Satz."])

        ttsProvider.enqueueSentenceForSpeech("Zweiter Satz.")
        #expect(ttsProvider.spokenTexts == ["Erster Satz.", "Zweiter Satz."])

        ttsProvider.finishSpeechSession()
        #expect(!ttsProvider.isPlaying)
        #expect(didFinishPlayback)
    }

    @Test func mockTranscriptionProviderStreamsAndDeliversFinalTranscript() async throws {
        let transcriptionProvider = MockTranscriptionProvider()
        transcriptionProvider.simulatedFinalTranscript = "Fertiges Transkript"

        var finalTranscriptReceived: String?
        let session = try await transcriptionProvider.startStreamingSession(
            keyterms: ["Clicky"],
            onTranscriptUpdate: { _ in },
            onFinalTranscriptReady: { transcript in
                finalTranscriptReceived = transcript
            },
            onError: { _ in }
        )

        session.requestFinalTranscript()
        #expect(finalTranscriptReceived == "Fertiges Transkript")
    }
}
