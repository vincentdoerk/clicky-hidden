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
final class AppleTTSClient: NSObject, AVSpeechSynthesizerDelegate {
    private let speechSynthesizer: AVSpeechSynthesizer
    private var isCurrentlySpeaking: Bool = false

    override init() {
        self.speechSynthesizer = AVSpeechSynthesizer()
        super.init()
        self.speechSynthesizer.delegate = self
    }

    /// Whether text-to-speech audio is currently being spoken.
    var isPlaying: Bool {
        return isCurrentlySpeaking || speechSynthesizer.isSpeaking
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
        speechUtterance.rate = AVSpeechUtteranceDefaultSpeechRate
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
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isCurrentlySpeaking = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isCurrentlySpeaking = false
        }
    }
}
