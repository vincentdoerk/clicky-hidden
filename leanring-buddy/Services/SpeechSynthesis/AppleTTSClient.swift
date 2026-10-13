//
//  AppleTTSClient.swift
//  leanring-buddy
//
//  Native on-device Text-to-Speech client using Apple's AVSpeechSynthesizer.
//  Zero latency, zero network traffic, 100% offline.
//

import AVFoundation
import Foundation

@MainActor
final class AppleTTSClient: NSObject, AVSpeechSynthesizerDelegate, TextToSpeechProvider {
    private let speechSynthesizer: AVSpeechSynthesizer
    private var isCurrentlySpeaking: Bool = false
    private var onFirstAudioStartedForCurrentSession: (() -> Void)?
    private var onPlaybackFinishedForCurrentSession: (() -> Void)?
    private(set) var hasCurrentSessionStartedAudio: Bool = false

    let displayName = "Apple Speech Synthesis"

    override init() {
        self.speechSynthesizer = AVSpeechSynthesizer()
        super.init()
        self.speechSynthesizer.delegate = self
    }

    /// Whether text-to-speech audio is currently being spoken or queued.
    var isPlaying: Bool {
        return isCurrentlySpeaking || speechSynthesizer.isSpeaking
    }

    func prepare() {
        // No background server needed for Apple Speech framework.
    }

    func shutdown() {
        stopPlayback()
    }

    func beginSpeechSession(
        onFirstAudioStarted: @escaping () -> Void,
        onPlaybackFinished: (() -> Void)? = nil
    ) {
        stopPlayback()
        self.onFirstAudioStartedForCurrentSession = onFirstAudioStarted
        self.onPlaybackFinishedForCurrentSession = onPlaybackFinished
        self.hasCurrentSessionStartedAudio = false
    }

    private var speechRateMultiplier: Double = {
        let persistedRate = UserDefaults.standard.double(forKey: "selectedTTSSpeechRate")
        return persistedRate > 0.1 ? persistedRate : 1.0
    }()

    func setSpeechRateMultiplier(_ newRateMultiplier: Double) {
        self.speechRateMultiplier = newRateMultiplier
    }

    func enqueueSentenceForSpeech(_ sentenceText: String) {
        let trimmedText = sentenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let speechUtterance = AVSpeechUtterance(string: trimmedText)
        speechUtterance.voice = selectBestSpeechVoice()
        speechUtterance.rate = min(1.0, max(0.1, AVSpeechUtteranceDefaultSpeechRate * Float(speechRateMultiplier)))
        speechUtterance.pitchMultiplier = 1.0
        speechUtterance.volume = 1.0

        isCurrentlySpeaking = true
        speechSynthesizer.speak(speechUtterance)
        print("🔊 Apple TTS: queued utterance (\(trimmedText.count) characters) with voice: \(speechUtterance.voice?.name ?? "default")")
    }

    func finishSpeechSession() {
        // AVSpeechSynthesizer processes all queued utterances until done.
    }

    /// Speaks the given text using the best available local system voice.
    /// Cancellation-safe and returns immediately once speech begins.
    func speakText(_ textToSpeak: String) async throws {
        let trimmedText = textToSpeak.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        // Stop any currently running speech playback before starting new utterance
        stopPlayback()

        try Task.checkCancellation()

        let speechUtterance = AVSpeechUtterance(string: trimmedText)
        speechUtterance.voice = selectBestSpeechVoice()
        speechUtterance.rate = min(1.0, max(0.1, AVSpeechUtteranceDefaultSpeechRate * Float(speechRateMultiplier)))
        speechUtterance.pitchMultiplier = 1.0
        speechUtterance.volume = 1.0

        isCurrentlySpeaking = true
        speechSynthesizer.speak(speechUtterance)
        print("🔊 Apple TTS: speaking \(trimmedText.count) characters with voice: \(speechUtterance.voice?.name ?? "default")")
    }

    /// Stops any in-progress speech playback immediately.
    func stopPlayback() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        isCurrentlySpeaking = false
        onFirstAudioStartedForCurrentSession = nil
        hasCurrentSessionStartedAudio = false
        let finishCallback = onPlaybackFinishedForCurrentSession
        onPlaybackFinishedForCurrentSession = nil
        finishCallback?()
    }

    // MARK: - Voice Selection

    /// Selects the best natural-sounding voice for the preferred locale or German/English fallback.
    private func selectBestSpeechVoice() -> AVSpeechSynthesisVoice? {
        let allAvailableVoices = AVSpeechSynthesisVoice.speechVoices()

        // Prioritize preferred languages (e.g. ["de-DE", "en-US"])
        var candidateLanguages: [String] = []
        for preferredLanguage in Locale.preferredLanguages {
            let languagePrefix = String(preferredLanguage.prefix(2)).lowercased()
            if !candidateLanguages.contains(languagePrefix) {
                candidateLanguages.append(languagePrefix)
            }
        }
        if !candidateLanguages.contains("de") {
            candidateLanguages.append("de")
        }
        if !candidateLanguages.contains("en") {
            candidateLanguages.append("en")
        }

        // 1. Check for Premium (rawValue == 2) or Siri natural voices in candidate languages
        for candidateLanguage in candidateLanguages {
            if let premiumVoice = allAvailableVoices.first(where: { availableVoice in
                availableVoice.language.lowercased().starts(with: candidateLanguage) &&
                (availableVoice.quality.rawValue == 2 || availableVoice.identifier.lowercased().contains("siri"))
            }) {
                print("🔊 Apple TTS: selected premium/Siri voice: \(premiumVoice.name) (\(premiumVoice.identifier))")
                return premiumVoice
            }
        }

        // 2. Check for Enhanced voices in candidate languages
        for candidateLanguage in candidateLanguages {
            if let enhancedVoice = allAvailableVoices.first(where: { availableVoice in
                availableVoice.language.lowercased().starts(with: candidateLanguage) &&
                availableVoice.quality == .enhanced
            }) {
                print("🔊 Apple TTS: selected enhanced voice: \(enhancedVoice.name) (\(enhancedVoice.identifier))")
                return enhancedVoice
            }
        }

        // 3. Fallback to any voice matching German
        if let germanVoice = allAvailableVoices.first(where: { availableVoice in
            availableVoice.language.lowercased().starts(with: "de")
        }) {
            print("🔊 Apple TTS: selected German voice: \(germanVoice.name) (\(germanVoice.identifier))")
            return germanVoice
        }

        // 4. Default en-US fallback
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isCurrentlySpeaking = true
            if !self.hasCurrentSessionStartedAudio {
                self.hasCurrentSessionStartedAudio = true
                self.onFirstAudioStartedForCurrentSession?()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isCurrentlySpeaking = synthesizer.isSpeaking
            if !synthesizer.isSpeaking {
                let finishCallback = self.onPlaybackFinishedForCurrentSession
                self.onPlaybackFinishedForCurrentSession = nil
                finishCallback?()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isCurrentlySpeaking = synthesizer.isSpeaking
            if !synthesizer.isSpeaking {
                let finishCallback = self.onPlaybackFinishedForCurrentSession
                self.onPlaybackFinishedForCurrentSession = nil
                finishCallback?()
            }
        }
    }
}
