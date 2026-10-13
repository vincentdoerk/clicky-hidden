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

    /// Selects the best natural-sounding voice for the current locale or English fallback.
    private func selectBestSpeechVoice() -> AVSpeechSynthesisVoice? {
        let currentLanguageCode = Locale.current.language.languageCode?.identifier ?? "en"
        let allAvailableVoices = AVSpeechSynthesisVoice.speechVoices()

        // 1. Look for an enhanced or premium voice matching the current locale language
        if let enhancedVoiceForCurrentLocale = allAvailableVoices.first(where: { availableVoice in
            availableVoice.language.starts(with: currentLanguageCode) &&
            availableVoice.quality == .enhanced
        }) {
            return enhancedVoiceForCurrentLocale
        }

        // 2. Look for any voice matching current locale language
        if let defaultVoiceForCurrentLocale = AVSpeechSynthesisVoice(language: Locale.current.identifier) ??
                                              AVSpeechSynthesisVoice(language: currentLanguageCode) {
            return defaultVoiceForCurrentLocale
        }

        // 3. Fallback: look for an enhanced English voice (e.g. Siri / Samantha)
        if let enhancedEnglishVoice = allAvailableVoices.first(where: { availableVoice in
            availableVoice.language.starts(with: "en") &&
            availableVoice.quality == .enhanced
        }) {
            return enhancedEnglishVoice
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
