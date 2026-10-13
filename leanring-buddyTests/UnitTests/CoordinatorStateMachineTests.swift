//
//  CoordinatorStateMachineTests.swift
//  leanring-buddyTests
//
//  Unit tests for CompanionCoordinator state machine lifecycle,
//  barge-in interruption, and pointing coordinate parsing.
//

import CoreGraphics
import Foundation
import Testing
@testable import leanring_buddy

struct CoordinatorStateMachineTests {

    @Test @MainActor func initialStateIsIdleWhenPermissionsGranted() async throws {
        let mockPermissions = MockPermissionsManager(allGranted: true)
        let coordinator = CompanionCoordinator(permissionsManager: mockPermissions)
        #expect(coordinator.voiceState == .idle)
        #expect(coordinator.allPermissionsGranted == true)
        #expect(coordinator.hasAccessibilityPermission == true)
        #expect(coordinator.hasScreenRecordingPermission == true)
        #expect(coordinator.hasMicrophonePermission == true)
        #expect(coordinator.hasScreenContentPermission == true)
    }

    @Test @MainActor func initialStateReflectsMissingPermissions() async throws {
        let mockPermissions = MockPermissionsManager(allGranted: false)
        let coordinator = CompanionCoordinator(permissionsManager: mockPermissions)
        #expect(coordinator.voiceState == .idle)
        #expect(coordinator.allPermissionsGranted == false)
        #expect(coordinator.hasAccessibilityPermission == false)
    }

    @Test @MainActor func bargeInCancelsCurrentResponseAndStartsListening() async throws {
        let coordinator = CompanionCoordinator(permissionsManager: MockPermissionsManager(allGranted: true))
        coordinator.simulateStartListening()
        #expect(coordinator.voiceState == .listening)

        coordinator.simulateStartResponding()
        #expect(coordinator.voiceState == .responding)

        // Neues Diktat unterbricht laufende Antwort (Barge-in)
        coordinator.simulateStartListening()
        #expect(coordinator.voiceState == .listening)
    }

    @Test @MainActor func bargeInStopsActiveSpeechSynthesisPlayback() async throws {
        let mockTTS = MockTextToSpeechProvider()
        let coordinator = CompanionCoordinator(
            permissionsManager: MockPermissionsManager(allGranted: true),
            textToSpeechProvider: mockTTS
        )

        coordinator.simulateStartResponding()
        mockTTS.isPlaying = true
        #expect(coordinator.voiceState == .responding)

        // Start listening should stop TTS playback immediately
        coordinator.simulateStartListening()
        #expect(coordinator.voiceState == .listening)
        #expect(mockTTS.stopPlaybackCallCount > 0)
    }

    @Test @MainActor func fullStateMachineTransitionLifecycle() async throws {
        let coordinator = CompanionCoordinator(permissionsManager: MockPermissionsManager(allGranted: true))
        #expect(coordinator.voiceState == .idle)

        coordinator.simulateStartListening()
        #expect(coordinator.voiceState == .listening)

        coordinator.simulateStartProcessing(stepText: "Audio transkribieren...")
        #expect(coordinator.voiceState == .processing)
        #expect(coordinator.processingStepText == "Audio transkribieren...")

        coordinator.simulateStartResponding()
        #expect(coordinator.voiceState == .responding)
        #expect(coordinator.processingStepText.isEmpty)

        coordinator.simulateTransition(to: .idle)
        #expect(coordinator.voiceState == .idle)
        #expect(coordinator.processingStepText.isEmpty)
    }

    @Test @MainActor func activeProcessDetectionReflectsStateTransitions() async throws {
        let coordinator = CompanionCoordinator(permissionsManager: MockPermissionsManager(allGranted: true))
        #expect(coordinator.hasActiveUserInteractionOrBackgroundProcess == false)

        coordinator.simulateStartListening()
        #expect(coordinator.hasActiveUserInteractionOrBackgroundProcess == true)

        coordinator.simulateStartProcessing()
        #expect(coordinator.hasActiveUserInteractionOrBackgroundProcess == true)

        coordinator.simulateStartResponding()
        #expect(coordinator.hasActiveUserInteractionOrBackgroundProcess == true)

        coordinator.simulateTransition(to: .idle)
        #expect(coordinator.hasActiveUserInteractionOrBackgroundProcess == false)
    }

    // MARK: - Pointing Coordinate Tag Parsing Tests

    @Test func pointingCoordinateParsingWithFullTagAndScreen() async throws {
        let response = "Hier ist das Terminal drüben auf dem zweiten Monitor. [POINT:450,300:120,40:terminal:screen2]"
        let parseResult = CompanionCoordinator.parsePointingCoordinates(from: response)

        #expect(parseResult.spokenText == "Hier ist das Terminal drüben auf dem zweiten Monitor.")
        #expect(parseResult.coordinate?.x == 450)
        #expect(parseResult.coordinate?.y == 300)
        #expect(parseResult.size?.width == 120)
        #expect(parseResult.size?.height == 40)
        #expect(parseResult.elementLabel == "terminal")
        #expect(parseResult.screenNumber == 2)
    }

    @Test func pointingCoordinateParsingWithStandardTag() async throws {
        let response = "Hier ist das GitLab Logo oben links. [POINT:250,102:115,36:gitlab docs logo]"
        let parseResult = CompanionCoordinator.parsePointingCoordinates(from: response)

        #expect(parseResult.spokenText == "Hier ist das GitLab Logo oben links.")
        #expect(parseResult.coordinate?.x == 250)
        #expect(parseResult.coordinate?.y == 102)
        #expect(parseResult.size?.width == 115)
        #expect(parseResult.size?.height == 36)
        #expect(parseResult.elementLabel == "gitlab docs logo")
        #expect(parseResult.screenNumber == nil)
    }

    @Test func pointingCoordinateParsingWithSimpleTag() async throws {
        let response = "Hier ist der Apple Button. [POINT:12,12:apple-menü]"
        let parseResult = CompanionCoordinator.parsePointingCoordinates(from: response)

        #expect(parseResult.spokenText == "Hier ist der Apple Button.")
        #expect(parseResult.coordinate?.x == 12)
        #expect(parseResult.coordinate?.y == 12)
        #expect(parseResult.size == nil)
        #expect(parseResult.elementLabel == "apple-menü")
    }

    @Test func pointingCoordinateParsingWithNoneTag() async throws {
        let response = "HTML ist die Auszeichnungssprache für Webseiten. [POINT:none]"
        let parseResult = CompanionCoordinator.parsePointingCoordinates(from: response)

        #expect(parseResult.spokenText == "HTML ist die Auszeichnungssprache für Webseiten.")
        #expect(parseResult.coordinate == nil)
        #expect(parseResult.size == nil)
        #expect(parseResult.elementLabel == "none")
    }

    @Test func pointingCoordinateParsingWithoutTagReturnsOriginalText() async throws {
        let plainResponse = "Guten Tag, wie kann ich dir heute auf deinem Mac helfen?"
        let parseResult = CompanionCoordinator.parsePointingCoordinates(from: plainResponse)

        #expect(parseResult.spokenText == plainResponse)
        #expect(parseResult.coordinate == nil)
        #expect(parseResult.size == nil)
        #expect(parseResult.elementLabel == nil)
        #expect(parseResult.screenNumber == nil)
    }

    @Test func candidateKeywordsExtractionBuildsExpectedList() async throws {
        let keywords = CompanionCoordinator.buildCandidateKeywords(label: "GitLab Logo")
        #expect(keywords.contains("GitLab Logo"))
        #expect(keywords.contains("GitLab"))
        #expect(keywords.contains("Logo"))

        let emptyKeywords = CompanionCoordinator.buildCandidateKeywords(label: "none")
        #expect(emptyKeywords.isEmpty)
    }

    @Test @MainActor func permissionsManagerDirectScreenContentGrantWithoutDowncast() async throws {
        let mockPermissions = MockPermissionsManager(allGranted: false)
        let coordinator = CompanionCoordinator(permissionsManager: mockPermissions)

        #expect(!coordinator.hasScreenContentPermission)
        mockPermissions.markScreenContentPermissionGranted()
        coordinator.refreshAllPermissions()

        #expect(coordinator.hasScreenContentPermission)
        #expect(mockPermissions.markScreenContentPermissionGrantedCallCount == 1)
    }
}
