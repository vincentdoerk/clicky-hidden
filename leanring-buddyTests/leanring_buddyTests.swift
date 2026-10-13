//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
@testable import leanring_buddy

struct leanring_buddyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func speechSentenceSegmenterSplitsStreamedSentencesAndStripsPointTags() async throws {
        let segmenter = SpeechSentenceSegmenter()

        // Emulate streaming chunks arriving from Ollama
        let chunk1 = "klick oben rechts auf das zahnrad. "
        let sentences1 = segmenter.appendAccumulatedResponseText(chunk1)
        #expect(sentences1 == ["klick oben rechts auf das zahnrad."])

        let chunk2 = chunk1 + "dann öffnen sich die einstellungen. [POINT:500,200:zahnrad]"
        let sentences2 = segmenter.appendAccumulatedResponseText(chunk2)
        let flushedSentences = segmenter.flushRemainingSentences()

        let combinedEmittedSentences = sentences2 + flushedSentences
        #expect(combinedEmittedSentences == ["dann öffnen sich die einstellungen."])
    }

    @Test func speechSentenceSegmenterPreservesGermanAbbreviationsWithoutFalseSplitting() async throws {
        let textWithAbbreviation = "klicke z.b. auf die datei und warte ca. 5 sekunden. danach ist alles fertig."
        let sentences = SpeechSentenceSegmenter.splitCompleteTextIntoSentences(textWithAbbreviation)

        #expect(sentences.count == 2)
        #expect(sentences.first == "klicke z.b. auf die datei und warte ca. 5 sekunden.")
        #expect(sentences.last == "danach ist alles fertig.")
    }

    @Test func mlxAudioServerManagerResolvesExecutablePath() async throws {
        let resolvedPath = MLXAudioServerManager.resolvedExecutablePath
        #expect(resolvedPath != nil)
    }

    @Test @MainActor func companionManagerProvidesSupportedQwen3Voices() async throws {
        let companionManager = CompanionManager()
        #expect(companionManager.availableVoices.contains("Serena"))
        #expect(companionManager.availableVoices.contains("Ryan"))
        #expect(companionManager.availableVoices.contains("Aiden"))
    }

    @Test @MainActor func pointingCoordinatesParseCorrectly() async throws {
        let responseWithPoint = "klicke hier auf den stop button. [POINT:120,45:stop button]"
        let parseResult = CompanionManager.parsePointingCoordinates(from: responseWithPoint)
        #expect(parseResult.spokenText == "klicke hier auf den stop button.")
        #expect(parseResult.coordinate?.x == 120)
        #expect(parseResult.coordinate?.y == 45)
        #expect(parseResult.elementLabel == "stop button")
    }

    @Test @MainActor func companionManagerSpeechRateMultiplierUpdatesAndPersists() async throws {
        let companionManager = CompanionManager()
        companionManager.setSpeechRateMultiplier(1.25)
        #expect(companionManager.speechRateMultiplier == 1.25)
        #expect(UserDefaults.standard.double(forKey: "selectedTTSSpeechRate") == 1.25)
        companionManager.setSpeechRateMultiplier(1.0)
    }

    @Test @MainActor func companionManagerActiveProcessDetection() async throws {
        let companionManager = CompanionManager()

        // When listening or processing, active process must be true
        companionManager.voiceState = .listening
        #expect(companionManager.hasActiveUserInteractionOrBackgroundProcess == true)

        companionManager.voiceState = .processing
        #expect(companionManager.hasActiveUserInteractionOrBackgroundProcess == true)

        companionManager.voiceState = .responding
        #expect(companionManager.hasActiveUserInteractionOrBackgroundProcess == true)

        // Pointing at element must also mark active process as true
        companionManager.voiceState = .idle
        companionManager.detectedElementScreenLocation = CGPoint(x: 150, y: 300)
        #expect(companionManager.hasActiveUserInteractionOrBackgroundProcess == true)

        // Clearing detected location while voice state is listening must NOT revert to idle
        companionManager.voiceState = .listening
        companionManager.clearDetectedElementLocation()
        #expect(companionManager.detectedElementScreenLocation == nil)
        #expect(companionManager.voiceState == .listening)
    }
}
