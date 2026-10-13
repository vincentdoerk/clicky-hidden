//
//  TextToSpeechProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for text-to-speech backends. Speech is organized
//  in sessions: a session is started when a new response begins, sentences
//  are enqueued one by one as they arrive from the streaming LLM, and the
//  session is finished when the response is complete. Backends play the
//  sentences back-to-back in order, so speech can start after the first
//  sentence instead of waiting for the whole response.
//

import Foundation

@MainActor
protocol TextToSpeechProvider: AnyObject {
    var displayName: String { get }

    /// True while any sentence of the current session is still waiting for
    /// synthesis or is audibly playing.
    var isPlaying: Bool { get }

    /// True once the first audio of the current session has started playing.
    var hasCurrentSessionStartedAudio: Bool { get }

    /// Called once on app start. Backends that need a local server or model
    /// warm-up start it here in the background.
    func prepare()

    /// Called on app termination. Backends release any processes they own.
    func shutdown()

    /// Starts a new speech session, stopping any currently playing speech.
    /// `onFirstAudioStarted` is called once, when the first sentence becomes audible.
    /// `onPlaybackFinished` is called once, when all enqueued sentences have finished playing (or on stop).
    func beginSpeechSession(
        onFirstAudioStarted: @escaping () -> Void,
        onPlaybackFinished: (() -> Void)?
    )

    /// Adds one sentence to the current session. Sentences are spoken in the
    /// order they are enqueued.
    func enqueueSentenceForSpeech(_ sentenceText: String)

    /// Signals that no more sentences will be enqueued for the current session.
    func finishSpeechSession()

    /// Stops all speech immediately and discards queued sentences.
    func stopPlayback()

    /// Updates the voice timbre used for subsequent speech sessions.
    func setVoiceName(_ voiceName: String)

    /// Updates the model identifier or repo used for speech synthesis.
    func setModelName(_ modelName: String)

    /// Updates the spoken language code (e.g. "German", "en").
    func setLanguageCode(_ languageCode: String)

    /// Updates the speech playback rate multiplier (1.0 = normal speed).
    func setSpeechRateMultiplier(_ rateMultiplier: Double)
}

extension TextToSpeechProvider {
    func setVoiceName(_ voiceName: String) {}
    func setModelName(_ modelName: String) {}
    func setLanguageCode(_ languageCode: String) {}
    func setSpeechRateMultiplier(_ rateMultiplier: Double) {}

    func beginSpeechSession(onFirstAudioStarted: @escaping () -> Void) {
        beginSpeechSession(onFirstAudioStarted: onFirstAudioStarted, onPlaybackFinished: nil)
    }

    /// Convenience for speaking an already complete text: splits it into
    /// sentences and speaks them as a single session.
    func speakCompleteText(
        _ completeText: String,
        onFirstAudioStarted: @escaping () -> Void = {},
        onPlaybackFinished: (() -> Void)? = nil
    ) {
        beginSpeechSession(onFirstAudioStarted: onFirstAudioStarted, onPlaybackFinished: onPlaybackFinished)
        for sentenceText in SpeechSentenceSegmenter.splitCompleteTextIntoSentences(completeText) {
            enqueueSentenceForSpeech(sentenceText)
        }
        finishSpeechSession()
    }
}

enum TextToSpeechProviderFactory {
    private enum PreferredProvider: String {
        case qwen3MLXAudio = "qwen3"
        case appleSpeech = "apple"
    }

    @MainActor
    static func makeDefaultProvider() -> any TextToSpeechProvider {
        let provider = resolveProvider()
        print("🔊 Text-to-speech: using \(provider.displayName)")
        return provider
    }

    @MainActor
    private static func resolveProvider() -> any TextToSpeechProvider {
        let preferredProviderRawValue = AppBundleConfiguration
            .stringValue(forKey: "TextToSpeechProvider")?
            .lowercased()
        let preferredProvider = preferredProviderRawValue.flatMap(PreferredProvider.init(rawValue:))

        let appleTTSClient = AppleTTSClient()

        if preferredProvider == .appleSpeech {
            return appleTTSClient
        }

        // Qwen3-TTS is the default. Apple TTS stays available as a fallback
        // inside the Qwen3 client for when the local server is not ready.
        return MLXAudioQwenTTSClient(fallbackTextToSpeechProvider: appleTTSClient)
    }
}
