//
//  MLXAudioQwenTTSClient.swift
//  leanring-buddy
//
//  Local text-to-speech client powered by Qwen3-TTS running on Apple Silicon via mlx_audio.server.
//  Implements sentence-by-sentence streaming playback: sentences are synthesized asynchronously
//  in parallel with the streaming LLM response and played sequentially without pauses.
//  Includes automatic fallback to Apple Speech Synthesis if the local server is unavailable.
//

import AVFoundation
import Foundation

@MainActor
final class MLXAudioQwenTTSClient: NSObject, AVAudioPlayerDelegate, TextToSpeechProvider {
    let displayName = "Qwen3-TTS (MLX Audio)"

    /// Model identifier hosted on Hugging Face and loaded by mlx_audio.server.
    private var modelName: String

    /// Selected voice timbre for German speech (e.g. "Serena", "Vivian", "Aiden", "Ryan").
    private var voiceName: String

    /// Spoken language code passed to the server ("German").
    private var languageCode: String

    /// Fallback provider (Apple Speech Synthesis) used when the local server is offline or fails.
    private let fallbackTextToSpeechProvider: any TextToSpeechProvider

    /// Manager responsible for starting and stopping the local mlx_audio.server process.
    private let serverManager: MLXAudioServerManager

    /// Dedicated URLSession for TTS network requests with a 25-second timeout per sentence.
    private let networkSession: URLSession

    // MARK: - Current Speech Session State

    /// Unique identifier for the active speech session. Incremented on every `beginSpeechSession`
    /// so outdated asynchronous responses from previous sessions are cleanly ignored.
    private var currentSpeechSessionIdentifier: UUID?

    /// Sentences that have been enqueued in the current session in arrival order.
    private var enqueuedSentencesInCurrentSession: [String] = []

    /// Synthesized WAV audio data per sentence index. Nil while synthesis is still in progress.
    private var synthesizedAudioDataByIndex: [Int: Data] = [:]

    /// Active network synthesis tasks mapped by sentence index so they can be cancelled if needed.
    private var activeSynthesisTasksByIndex: [Int: Task<Void, Never>] = [:]

    /// The index of the sentence currently being played by the audio player.
    private var currentPlayingSentenceIndex: Int = 0

    /// Whether the full stream of sentences has finished arriving for the current session.
    private var hasFinishedEnqueueingSentencesForSession: Bool = false

    /// Currently active audio player playing speech audio through system output.
    private var activeAudioPlayer: AVAudioPlayer?

    /// Callback invoked once when the first audible chunk of the current session starts playing.
    private var onFirstAudioStartedForCurrentSession: (() -> Void)?

    /// Callback invoked once when all sentences in the current session have finished playing.
    private var onPlaybackFinishedForCurrentSession: (() -> Void)?

    /// Whether the first audio chunk of the current session has started playing.
    private(set) var hasCurrentSessionStartedAudio: Bool = false

    /// Flag tracking whether fallback provider has taken over the current session.
    private var isUsingFallbackProviderForCurrentSession: Bool = false

    init(
        fallbackTextToSpeechProvider: any TextToSpeechProvider,
        serverManager: MLXAudioServerManager = .shared
    ) {
        self.fallbackTextToSpeechProvider = fallbackTextToSpeechProvider
        self.serverManager = serverManager

        let configuredModelName = AppBundleConfiguration.stringValue(forKey: "LocalTTSModel")
            ?? "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"
        let configuredVoiceName = AppBundleConfiguration.stringValue(forKey: "LocalTTSVoice")
            ?? "Serena"
        let persistedVoiceName = UserDefaults.standard.string(forKey: "selectedTTSVoice")
            ?? configuredVoiceName
        let configuredLanguageCode = AppBundleConfiguration.stringValue(forKey: "LocalTTSLanguage")
            ?? "German"

        let persistedModelId = UserDefaults.standard.string(forKey: "selectedTTSModelId") ?? TTSModelCatalog.defaultModelId
        let activeModelOption = TTSModelCatalog.model(withId: persistedModelId)
        let resolvedModelName = activeModelOption.modelRepo ?? configuredModelName
        let persistedLanguageCode = UserDefaults.standard.string(forKey: "selectedTTSLanguageCode")
            ?? activeModelOption.defaultLanguageCode

        self.modelName = resolvedModelName
        self.voiceName = persistedVoiceName
        self.languageCode = persistedLanguageCode
        let persistedRate = UserDefaults.standard.double(forKey: "selectedTTSSpeechRate")
        self.speechRateMultiplier = persistedRate > 0.1 ? persistedRate : 1.0

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 25.0
        configuration.timeoutIntervalForResource = 30.0
        self.networkSession = URLSession(configuration: configuration)

        super.init()
    }

    /// Playback rate multiplier (e.g. 1.0 = normal, 1.25 = 25% faster).
    private var speechRateMultiplier: Double

    func setVoiceName(_ newVoiceName: String) {
        self.voiceName = newVoiceName
        fallbackTextToSpeechProvider.setVoiceName(newVoiceName)
        print("🔊 MLX Audio: active voice switched to '\(newVoiceName)'")
    }

    func setModelName(_ newModelName: String) {
        self.modelName = newModelName
        print("🔊 MLX Audio: active model switched to '\(newModelName)'")
    }

    func setLanguageCode(_ newLanguageCode: String) {
        self.languageCode = newLanguageCode
        fallbackTextToSpeechProvider.setLanguageCode(newLanguageCode)
        print("🔊 MLX Audio: active language code switched to '\(newLanguageCode)'")
    }

    func setSpeechRateMultiplier(_ newRateMultiplier: Double) {
        self.speechRateMultiplier = newRateMultiplier
        if let activePlayer = activeAudioPlayer {
            activePlayer.enableRate = true
            activePlayer.rate = Float(newRateMultiplier)
        }
        fallbackTextToSpeechProvider.setSpeechRateMultiplier(newRateMultiplier)
        print("🔊 MLX Audio: speech rate multiplier updated to \(String(format: "%.2f", newRateMultiplier))x")
    }

    // MARK: - TextToSpeechProvider Protocol

    var isPlaying: Bool {
        if isUsingFallbackProviderForCurrentSession {
            return fallbackTextToSpeechProvider.isPlaying
        }

        let isAudioPlayerActivelyPlaying = activeAudioPlayer?.isPlaying ?? false
        let hasPendingSynthesisTasks = !activeSynthesisTasksByIndex.isEmpty
        let hasSentencesAwaitingPlayback = currentPlayingSentenceIndex < enqueuedSentencesInCurrentSession.count

        return isAudioPlayerActivelyPlaying || hasPendingSynthesisTasks || hasSentencesAwaitingPlayback
    }

    /// Pre-warms the server and loads model weights into unified memory on launch.
    func prepare() {
        Task { [weak self] in
            guard let self = self else { return }
            let isServerReady = await self.serverManager.ensureServerIsRunning()
            guard isServerReady else {
                print("⚠️ MLX Audio: server could not be started at launch; will use fallback when needed.")
                return
            }

            print("🔊 MLX Audio: warming up model weights in background...")
            do {
                _ = try await self.requestAudioDataFromServer(
                    forSentenceText: "Bereit.",
                    sessionIdentifier: UUID()
                )
                print("🔊 MLX Audio: warm-up complete, model ready for instant response.")
            } catch {
                print("⚠️ MLX Audio: warm-up request failed: \(error)")
            }
        }
    }

    func shutdown() {
        stopPlayback()
        serverManager.shutdownManagedServerProcess()
    }

    func beginSpeechSession(
        onFirstAudioStarted: @escaping () -> Void,
        onPlaybackFinished: (() -> Void)? = nil
    ) {
        stopPlayback()

        // If Apple Speech is explicitly selected as the model (empty model name), delegate directly
        if modelName.isEmpty {
            self.isUsingFallbackProviderForCurrentSession = true
            fallbackTextToSpeechProvider.beginSpeechSession(
                onFirstAudioStarted: onFirstAudioStarted,
                onPlaybackFinished: onPlaybackFinished
            )
            return
        }

        let newSessionIdentifier = UUID()
        self.currentSpeechSessionIdentifier = newSessionIdentifier
        self.enqueuedSentencesInCurrentSession = []
        self.synthesizedAudioDataByIndex = [:]
        self.activeSynthesisTasksByIndex = [:]
        self.currentPlayingSentenceIndex = 0
        self.hasFinishedEnqueueingSentencesForSession = false
        self.onFirstAudioStartedForCurrentSession = onFirstAudioStarted
        self.onPlaybackFinishedForCurrentSession = onPlaybackFinished
        self.hasCurrentSessionStartedAudio = false
        self.isUsingFallbackProviderForCurrentSession = false

        print("🔊 MLX Audio: began new speech session [\(newSessionIdentifier.uuidString.prefix(8))]")
    }

    func enqueueSentenceForSpeech(_ sentenceText: String) {
        let trimmedSentence = sentenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSentence.isEmpty else { return }

        guard let sessionIdentifier = currentSpeechSessionIdentifier else {
            print("⚠️ MLX Audio: sentence enqueued without an active session, ignoring.")
            return
        }

        if isUsingFallbackProviderForCurrentSession {
            fallbackTextToSpeechProvider.enqueueSentenceForSpeech(trimmedSentence)
            return
        }

        let sentenceIndex = enqueuedSentencesInCurrentSession.count
        enqueuedSentencesInCurrentSession.append(trimmedSentence)
        print("🔊 MLX Audio: enqueued sentence #\(sentenceIndex) (\(trimmedSentence.count) chars): \"\(trimmedSentence.prefix(40))...\"")

        // Kick off synthesis immediately for this sentence
        let synthesisTask = Task { [weak self, sentenceIndex, sessionIdentifier, trimmedSentence] in
            guard let self = self else { return }

            do {
                let synthesizedWavAudioData = try await self.requestAudioDataFromServer(
                    forSentenceText: trimmedSentence,
                    sessionIdentifier: sessionIdentifier
                )

                await MainActor.run {
                    guard self.currentSpeechSessionIdentifier == sessionIdentifier else { return }
                    self.activeSynthesisTasksByIndex.removeValue(forKey: sentenceIndex)
                    self.synthesizedAudioDataByIndex[sentenceIndex] = synthesizedWavAudioData

                    // If the player is idle and this is the sentence we are waiting to play, play it now!
                    if self.activeAudioPlayer == nil && self.currentPlayingSentenceIndex == sentenceIndex {
                        self.playAudioForSentenceAtCurrentIndex()
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.currentSpeechSessionIdentifier == sessionIdentifier else { return }
                    self.activeSynthesisTasksByIndex.removeValue(forKey: sentenceIndex)
                    print("⚠️ MLX Audio: synthesis failed for sentence #\(sentenceIndex): \(error)")
                    self.handleSynthesisFailure(
                        forSentenceIndex: sentenceIndex,
                        failedSentenceText: trimmedSentence
                    )
                }
            }
        }

        activeSynthesisTasksByIndex[sentenceIndex] = synthesisTask
    }

    func finishSpeechSession() {
        guard !isUsingFallbackProviderForCurrentSession else {
            fallbackTextToSpeechProvider.finishSpeechSession()
            return
        }

        hasFinishedEnqueueingSentencesForSession = true
        print("🔊 MLX Audio: finished enqueueing all sentences for session (total: \(enqueuedSentencesInCurrentSession.count))")

        // If no sentences were enqueued, session ends immediately
        if enqueuedSentencesInCurrentSession.isEmpty {
            currentSpeechSessionIdentifier = nil
            let finishCallback = onPlaybackFinishedForCurrentSession
            onPlaybackFinishedForCurrentSession = nil
            finishCallback?()
        }
    }

    func stopPlayback() {
        // Cancel all in-flight synthesis tasks
        for (_, activeTask) in activeSynthesisTasksByIndex {
            activeTask.cancel()
        }
        activeSynthesisTasksByIndex.removeAll()

        // Stop active audio player
        activeAudioPlayer?.stop()
        activeAudioPlayer = nil

        currentSpeechSessionIdentifier = nil
        enqueuedSentencesInCurrentSession = []
        synthesizedAudioDataByIndex.removeAll()
        currentPlayingSentenceIndex = 0
        hasFinishedEnqueueingSentencesForSession = false
        onFirstAudioStartedForCurrentSession = nil
        hasCurrentSessionStartedAudio = false

        let finishCallback = onPlaybackFinishedForCurrentSession
        onPlaybackFinishedForCurrentSession = nil
        finishCallback?()

        if isUsingFallbackProviderForCurrentSession {
            fallbackTextToSpeechProvider.stopPlayback()
            isUsingFallbackProviderForCurrentSession = false
        }
    }

    // MARK: - Internal Playback & Networking

    /// Plays the synthesized audio data for the current playing sentence index.
    private func playAudioForSentenceAtCurrentIndex() {
        guard let sessionIdentifier = currentSpeechSessionIdentifier else { return }
        guard currentPlayingSentenceIndex < enqueuedSentencesInCurrentSession.count else {
            return
        }

        guard let audioData = synthesizedAudioDataByIndex[currentPlayingSentenceIndex] else {
            // Audio data for this sentence is not ready yet; wait for its synthesis task to complete.
            return
        }

        do {
            let newPlayer = try AVAudioPlayer(data: audioData)
            newPlayer.delegate = self
            newPlayer.enableRate = true
            newPlayer.rate = Float(speechRateMultiplier)
            self.activeAudioPlayer = newPlayer
            newPlayer.play()

            if !hasCurrentSessionStartedAudio {
                hasCurrentSessionStartedAudio = true
                print("🔊 MLX Audio: first audio playback started for session [\(sessionIdentifier.uuidString.prefix(8))]")
                onFirstAudioStartedForCurrentSession?()
            }

            print("🔊 MLX Audio: now playing sentence #\(currentPlayingSentenceIndex) (\(audioData.count / 1024) KB)")
        } catch {
            print("⚠️ MLX Audio: failed to initialize AVAudioPlayer for sentence #\(currentPlayingSentenceIndex): \(error)")
            // Advance to next sentence on playback initialization failure
            advanceToNextSentenceAfterPlaybackFinished()
        }
    }

    /// Advances the sentence counter and immediately starts playback of the next sentence if ready.
    private func advanceToNextSentenceAfterPlaybackFinished() {
        activeAudioPlayer = nil
        currentPlayingSentenceIndex += 1

        if currentPlayingSentenceIndex < enqueuedSentencesInCurrentSession.count {
            // Check if audio for the next sentence is already waiting
            if synthesizedAudioDataByIndex[currentPlayingSentenceIndex] != nil {
                playAudioForSentenceAtCurrentIndex()
            } else {
                print("🔊 MLX Audio: waiting for sentence #\(currentPlayingSentenceIndex) synthesis to complete...")
            }
        } else if hasFinishedEnqueueingSentencesForSession {
            print("🔊 MLX Audio: completed playback of all sentences in session.")
            currentSpeechSessionIdentifier = nil
            let finishCallback = onPlaybackFinishedForCurrentSession
            onPlaybackFinishedForCurrentSession = nil
            finishCallback?()
        }
    }

    /// When local MLX Audio synthesis fails, gracefully hands remaining sentences to Apple TTS.
    private func handleSynthesisFailure(forSentenceIndex sentenceIndex: Int, failedSentenceText: String) {
        print("⚠️ MLX Audio: switching current session to Apple TTS fallback.")
        isUsingFallbackProviderForCurrentSession = true

        fallbackTextToSpeechProvider.beginSpeechSession(
            onFirstAudioStarted: { [weak self] in
                guard let self = self else { return }
                if !self.hasCurrentSessionStartedAudio {
                    self.hasCurrentSessionStartedAudio = true
                    self.onFirstAudioStartedForCurrentSession?()
                }
            },
            onPlaybackFinished: { [weak self] in
                let finishCallback = self?.onPlaybackFinishedForCurrentSession
                self?.onPlaybackFinishedForCurrentSession = nil
                finishCallback?()
            }
        )

        // Enqueue the failed sentence and all subsequent unplayed sentences into Apple TTS
        fallbackTextToSpeechProvider.enqueueSentenceForSpeech(failedSentenceText)
        let startIndex = sentenceIndex + 1
        if startIndex < enqueuedSentencesInCurrentSession.count {
            for index in startIndex..<enqueuedSentencesInCurrentSession.count {
                fallbackTextToSpeechProvider.enqueueSentenceForSpeech(enqueuedSentencesInCurrentSession[index])
            }
        }

        if hasFinishedEnqueueingSentencesForSession {
            fallbackTextToSpeechProvider.finishSpeechSession()
        }
    }

    /// Sends HTTP request to mlx_audio.server `/v1/audio/speech` endpoint and returns synthesized WAV audio bytes.
    private func requestAudioDataFromServer(
        forSentenceText sentenceText: String,
        sessionIdentifier: UUID
    ) async throws -> Data {
        try Task.checkCancellation()

        let speechEndpointURL = serverManager.serverBaseURL.appendingPathComponent("v1/audio/speech")
        var request = URLRequest(url: speechEndpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/wav", forHTTPHeaderField: "Accept")

        var requestPayload: [String: Any] = [
            "model": modelName,
            "input": sentenceText,
            "voice": voiceName,
            "lang_code": languageCode,
            "response_format": "wav"
        ]
        if !languageCode.isEmpty {
            requestPayload["instruct"] = languageCode
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: requestPayload)

        let (responseData, response) = try await networkSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "MLXAudioQwenTTSClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid server response"]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: responseData, encoding: .utf8) ?? "Unknown server error"
            throw NSError(
                domain: "MLXAudioQwenTTSClient",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "TTS server error (\(httpResponse.statusCode)): \(errorText)"]
            )
        }

        return responseData
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.advanceToNextSentenceAfterPlaybackFinished()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor in
            print("⚠️ MLX Audio: audio player decode error: \(String(describing: error))")
            self.advanceToNextSentenceAfterPlaybackFinished()
        }
    }
}
