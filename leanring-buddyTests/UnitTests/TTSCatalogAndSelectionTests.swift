//
//  TTSCatalogAndSelectionTests.swift
//  leanring-buddyTests
//
//  Unit tests for TTSModelCatalog, model switching fallbacks,
//  voice selection, and speech rate persistence.
//

import Foundation
import Testing
@testable import leanring_buddy

@Suite("TTSCatalogAndSelection Tests")
struct TTSCatalogAndSelectionTests {

    // MARK: - Catalog Model Verification Tests

    @Test func defaultTTSModelIsQwen3_06B() async throws {
        #expect(TTSModelCatalog.defaultModelId == "qwen3-0.6b")

        let defaultModel = TTSModelCatalog.model(withId: TTSModelCatalog.defaultModelId)
        #expect(defaultModel.id == "qwen3-0.6b")
        #expect(defaultModel.shortName == "Qwen3 0.6B")
        #expect(defaultModel.isLocalMLX == true)
        #expect(defaultModel.defaultLanguageCode == "German")
        #expect(defaultModel.defaultVoice == "Serena")
        #expect(defaultModel.availableVoices.contains("Serena"))
        #expect(defaultModel.availableVoices.contains("Ryan"))
        #expect(defaultModel.availableVoices.contains("Aiden"))
    }

    @Test func catalogContainsAllExpectedModels() async throws {
        let allModels = TTSModelCatalog.allModels
        let modelIds = allModels.map(\.id)

        #expect(modelIds.contains("qwen3-0.6b"))
        #expect(modelIds.contains("qwen3-1.7b"))
        #expect(modelIds.contains("kokoro-82m"))
        #expect(modelIds.contains("apple-speech"))
        #expect(allModels.count == 4)
    }

    @Test func unknownModelIdFallsBackToDefaultModel() async throws {
        let fallbackModel = TTSModelCatalog.model(withId: "non-existent-tts-model-xyz")
        #expect(fallbackModel.id == "qwen3-0.6b")
    }

    @Test func kokoro82MHasDistinctLanguageAndVoiceDefaults() async throws {
        let kokoroModel = TTSModelCatalog.model(withId: "kokoro-82m")
        #expect(kokoroModel.defaultLanguageCode == "en")
        #expect(kokoroModel.defaultVoice == "af_heart")
        #expect(kokoroModel.availableVoices.contains("af_heart"))
        #expect(kokoroModel.availableVoices.contains("am_adam"))
        // Kokoro does not support German in current configuration
        let supportsGerman = kokoroModel.supportedLanguages.contains { $0.code == "German" }
        #expect(!supportsGerman)
    }

    @Test func appleSpeechConfiguredAsSystemTTS() async throws {
        let appleSpeechModel = TTSModelCatalog.model(withId: "apple-speech")
        #expect(appleSpeechModel.isLocalMLX == false)
        #expect(appleSpeechModel.modelRepo == nil)
        #expect(appleSpeechModel.defaultVoice == "System")
        #expect(appleSpeechModel.availableVoices == ["System"])
    }

    // MARK: - Model Switching Fallback Tests

    @Test @MainActor func modelSwitchToKokoroFallsBackToDefaultLanguageAndVoice() async throws {
        let mockStorage = MockSettingsStorage()
        let mockTTS = MockTextToSpeechProvider()
        let coordinator = CompanionCoordinator(
            permissionsManager: MockPermissionsManager(allGranted: true),
            textToSpeechProvider: mockTTS,
            settingsStorage: mockStorage
        )

        // Initial state is Qwen3 0.6B with German and Serena
        #expect(coordinator.selectedTTSModelId == "qwen3-0.6b")
        #expect(coordinator.selectedTTSLanguageCode == "German")
        #expect(coordinator.selectedVoice == "Serena")

        // Switch to Kokoro-82M (which does not support German nor Serena)
        coordinator.setSelectedTTSModel("kokoro-82m")

        #expect(coordinator.selectedTTSModelId == "kokoro-82m")
        #expect(coordinator.selectedTTSLanguageCode == "en")
        #expect(coordinator.selectedVoice == "af_heart")

        // Verify updates propagated to SettingsStorage
        #expect(mockStorage.string(forKey: "selectedTTSModelId") == "kokoro-82m")
        #expect(mockStorage.string(forKey: "selectedTTSLanguageCode") == "en")
        #expect(mockStorage.string(forKey: "selectedTTSVoice") == "af_heart")

        // Verify updates propagated to TTS Provider
        #expect(mockTTS.selectedModelName == "mlx-community/Kokoro-82M-bf16")
        #expect(mockTTS.selectedLanguageCode == "en")
        #expect(mockTTS.selectedVoiceName == "af_heart")
    }

    @Test @MainActor func modelSwitchToAppleSpeechFallsBackToSystemVoice() async throws {
        let mockStorage = MockSettingsStorage()
        let mockTTS = MockTextToSpeechProvider()
        let coordinator = CompanionCoordinator(
            permissionsManager: MockPermissionsManager(allGranted: true),
            textToSpeechProvider: mockTTS,
            settingsStorage: mockStorage
        )

        coordinator.setSelectedTTSModel("apple-speech")

        #expect(coordinator.selectedTTSModelId == "apple-speech")
        #expect(coordinator.selectedVoice == "System")
        #expect(mockStorage.string(forKey: "selectedTTSVoice") == "System")
        #expect(mockTTS.selectedVoiceName == "System")
    }

    @Test @MainActor func modelSwitchBetweenQwenModelsPreservesSupportedVoice() async throws {
        let mockStorage = MockSettingsStorage()
        let mockTTS = MockTextToSpeechProvider()
        let coordinator = CompanionCoordinator(
            permissionsManager: MockPermissionsManager(allGranted: true),
            textToSpeechProvider: mockTTS,
            settingsStorage: mockStorage
        )

        // Select Ryan on Qwen 0.6B
        coordinator.setSelectedVoice("Ryan")
        #expect(coordinator.selectedVoice == "Ryan")

        // Switch to Qwen 1.7B which also supports Ryan
        coordinator.setSelectedTTSModel("qwen3-1.7b")

        #expect(coordinator.selectedTTSModelId == "qwen3-1.7b")
        #expect(coordinator.selectedVoice == "Ryan")
        #expect(mockStorage.string(forKey: "selectedTTSVoice") == "Ryan")
    }

    // MARK: - Speech Rate Multiplier & Settings Persistence Tests

    @Test @MainActor func speechRateMultiplierPersistsInSettingsStorage() async throws {
        let mockStorage = MockSettingsStorage()
        let mockTTS = MockTextToSpeechProvider()
        let coordinator = CompanionCoordinator(
            permissionsManager: MockPermissionsManager(allGranted: true),
            textToSpeechProvider: mockTTS,
            settingsStorage: mockStorage
        )

        // Verify initial speech rate is 1.0
        #expect(coordinator.speechRateMultiplier == 1.0)

        // Update speech rate to 1.25x
        coordinator.setSpeechRateMultiplier(1.25)

        #expect(coordinator.speechRateMultiplier == 1.25)
        #expect(mockStorage.double(forKey: "selectedTTSSpeechRate") == 1.25)
        #expect(mockTTS.selectedSpeechRateMultiplier == 1.25)
    }

    @Test @MainActor func coordinatorRestoresPersistedSettingsOnInitialization() async throws {
        let mockStorage = MockSettingsStorage()
        mockStorage.set("qwen3-1.7b", forKey: "selectedTTSModelId")
        mockStorage.set("French", forKey: "selectedTTSLanguageCode")
        mockStorage.set("Vivian", forKey: "selectedTTSVoice")
        mockStorage.set(1.5, forKey: "selectedTTSSpeechRate")

        let mockTTS = MockTextToSpeechProvider()
        let coordinator = CompanionCoordinator(
            permissionsManager: MockPermissionsManager(allGranted: true),
            textToSpeechProvider: mockTTS,
            settingsStorage: mockStorage
        )

        #expect(coordinator.selectedTTSModelId == "qwen3-1.7b")
        #expect(coordinator.selectedTTSLanguageCode == "French")
        #expect(coordinator.selectedVoice == "Vivian")
        #expect(coordinator.speechRateMultiplier == 1.5)
        #expect(mockTTS.selectedSpeechRateMultiplier == 1.5)
    }

    @Test @MainActor func voiceAndLanguageUpdatesPersistToSettingsStorage() async throws {
        let mockStorage = MockSettingsStorage()
        let mockTTS = MockTextToSpeechProvider()
        let coordinator = CompanionCoordinator(
            permissionsManager: MockPermissionsManager(allGranted: true),
            textToSpeechProvider: mockTTS,
            settingsStorage: mockStorage
        )

        coordinator.setSelectedVoice("Aiden")
        #expect(coordinator.selectedVoice == "Aiden")
        #expect(mockStorage.string(forKey: "selectedTTSVoice") == "Aiden")
        #expect(mockTTS.selectedVoiceName == "Aiden")

        coordinator.setSelectedTTSLanguage("English")
        #expect(coordinator.selectedTTSLanguageCode == "English")
        #expect(mockStorage.string(forKey: "selectedTTSLanguageCode") == "English")
        #expect(mockTTS.selectedLanguageCode == "English")
    }
}
