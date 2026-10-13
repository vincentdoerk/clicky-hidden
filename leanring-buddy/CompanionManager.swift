//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?
    /// Bounding box size (in display points) of the detected UI element for the highlight overlay.
    @Published var detectedElementHighlightSize: CGSize?

    /// Human-readable status description for the current processing pipeline step
    /// (e.g. "Audio verarbeiten...", "Bildschirm analysieren...").
    @Published private(set) var processingStepText: String = ""

    func setProcessingStepText(_ text: String) {
        self.processingStepText = text
    }

    // MARK: - TTS Model & Voice Selection State

    /// The unique identifier of the currently selected TTS model.
    @Published var selectedTTSModelId: String = {
        let persistedId = UserDefaults.standard.string(forKey: "selectedTTSModelId")
            ?? TTSModelCatalog.defaultModelId
        return persistedId
    }()

    /// The currently selected spoken language code (e.g. "German", "en").
    @Published var selectedTTSLanguageCode: String = {
        let persistedCode = UserDefaults.standard.string(forKey: "selectedTTSLanguageCode")
        if let persistedCode = persistedCode, !persistedCode.isEmpty {
            return persistedCode
        }
        let initialModel = TTSModelCatalog.model(withId: UserDefaults.standard.string(forKey: "selectedTTSModelId") ?? TTSModelCatalog.defaultModelId)
        return initialModel.defaultLanguageCode
    }()

    /// All available TTS models in the catalog.
    var availableTTSModels: [TTSModelOption] {
        return TTSModelCatalog.allModels
    }

    /// The active TTS model option.
    var currentTTSModel: TTSModelOption {
        return TTSModelCatalog.model(withId: selectedTTSModelId)
    }

    /// Supported languages for the active TTS model.
    var availableLanguagesForCurrentModel: [TTSLanguageOption] {
        return currentTTSModel.supportedLanguages
    }

    /// Supported preset voices for the active TTS model.
    var availableVoices: [String] {
        return currentTTSModel.availableVoices
    }

    /// The currently selected speech voice timbre. Persisted to UserDefaults.
    @Published var selectedVoice: String = {
        let persistedVoice = UserDefaults.standard.string(forKey: "selectedTTSVoice")
        let activeModel = TTSModelCatalog.model(withId: UserDefaults.standard.string(forKey: "selectedTTSModelId") ?? TTSModelCatalog.defaultModelId)
        if let persistedVoice = persistedVoice, activeModel.availableVoices.contains(persistedVoice) {
            return persistedVoice
        }
        return activeModel.defaultVoice
    }()

    /// Whether a sample voice preview is currently being spoken.
    @Published var isPlayingVoicePreview: Bool = false

    func setSelectedTTSModel(_ modelId: String) {
        selectedTTSModelId = modelId
        UserDefaults.standard.set(modelId, forKey: "selectedTTSModelId")

        let modelOption = TTSModelCatalog.model(withId: modelId)
        textToSpeechProvider.setModelName(modelOption.modelRepo ?? "")

        // Verify and update language if current language is not supported
        let supportsCurrentLanguage = modelOption.supportedLanguages.contains { $0.code == selectedTTSLanguageCode }
        if !supportsCurrentLanguage {
            setSelectedTTSLanguage(modelOption.defaultLanguageCode)
        } else {
            textToSpeechProvider.setLanguageCode(selectedTTSLanguageCode)
        }

        // Verify and update voice if current voice is not in the new model's voice list
        if !modelOption.availableVoices.contains(selectedVoice) {
            setSelectedVoice(modelOption.defaultVoice)
        } else {
            textToSpeechProvider.setVoiceName(selectedVoice)
        }
        print("🔊 Text-to-speech: model switched to '\(modelOption.displayName)'")
    }

    func setSelectedTTSLanguage(_ languageCode: String) {
        selectedTTSLanguageCode = languageCode
        UserDefaults.standard.set(languageCode, forKey: "selectedTTSLanguageCode")
        textToSpeechProvider.setLanguageCode(languageCode)
        print("🔊 Text-to-speech: language switched to '\(languageCode)'")
    }

    func setSelectedVoice(_ voiceName: String) {
        selectedVoice = voiceName
        UserDefaults.standard.set(voiceName, forKey: "selectedTTSVoice")
        textToSpeechProvider.setVoiceName(voiceName)
        print("🔊 Text-to-speech: voice switched to '\(voiceName)'")
    }

    /// Plays a short sample phrase to preview the given voice (or currently selected voice).
    func playVoicePreview(for voiceName: String? = nil) {
        if isPlayingVoicePreview {
            stopVoicePreview()
        }

        let voiceToPreview = voiceName ?? selectedVoice
        textToSpeechProvider.setVoiceName(voiceToPreview)
        textToSpeechProvider.setModelName(currentTTSModel.modelRepo ?? "")
        textToSpeechProvider.setLanguageCode(selectedTTSLanguageCode)
        isPlayingVoicePreview = true

        let cleanVoiceName = voiceToPreview.replacingOccurrences(of: "_", with: " ")
        let samplePreviewText: String
        if selectedTTSLanguageCode.lowercased().contains("en") || selectedTTSLanguageCode.lowercased() == "a" || selectedTTSLanguageCode.lowercased() == "b" {
            samplePreviewText = "Hello! My name is \(cleanVoiceName), and this is how I sound on your Mac."
        } else if selectedTTSLanguageCode.lowercased().contains("fr") {
            samplePreviewText = "Bonjour! Je m'appelle \(cleanVoiceName), et voici ma voix sur votre Mac."
        } else if selectedTTSLanguageCode.lowercased().contains("es") {
            samplePreviewText = "¡Hola! Mi nombre es \(cleanVoiceName), y así es como sueno en tu Mac."
        } else {
            samplePreviewText = "Hallo! Mein Name ist \(cleanVoiceName), und so klinge ich auf deinem Mac."
        }

        textToSpeechProvider.speakCompleteText(
            samplePreviewText,
            onFirstAudioStarted: {
                // Audio started playing
            },
            onPlaybackFinished: { [weak self] in
                Task { @MainActor in
                    self?.isPlayingVoicePreview = false
                }
            }
        )
    }

    /// Stops any ongoing voice preview playback.
    func stopVoicePreview() {
        textToSpeechProvider.stopPlayback()
        isPlayingVoicePreview = false
    }

    // MARK: - Speech Rate State

    /// The playback rate multiplier for spoken audio (1.0 = normal, 1.25 = 25% faster).
    @Published var speechRateMultiplier: Double = {
        let persistedRate = UserDefaults.standard.double(forKey: "selectedTTSSpeechRate")
        return persistedRate > 0.1 ? persistedRate : 1.0
    }()

    /// Available speech rate multiplier options for the panel picker.
    let availableSpeechRates: [Double] = [0.85, 1.0, 1.1, 1.2, 1.25, 1.4, 1.5]

    func setSpeechRateMultiplier(_ rateMultiplier: Double) {
        speechRateMultiplier = rateMultiplier
        UserDefaults.standard.set(rateMultiplier, forKey: "selectedTTSSpeechRate")
        textToSpeechProvider.setSpeechRateMultiplier(rateMultiplier)
    }

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    private lazy var ollamaAPI: OllamaAPI = {
        return OllamaAPI(selectedModelName: selectedModel)
    }()

    private lazy var textToSpeechProvider: any TextToSpeechProvider = {
        return TextToSpeechProviderFactory.makeDefaultProvider()
    }()

    /// Conversation history so Ollama remembers prior exchanges within a session.
    /// Each entry is the user's transcript and the assistant's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Pre-captured screen data taken immediately on push-to-talk release so the
    /// captured screen state and cursor location match the moment speech ended.
    private var precapturedScreensTask: Task<[CompanionScreenCapture], Error>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Ollama vision model used for responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedOllamaVisionModel") ?? "llama3.2-vision"

    /// Installed vision models discovered from Ollama.
    @Published var availableVisionModels: [String] = []

    func setSelectedModel(_ modelName: String) {
        selectedModel = modelName
        UserDefaults.standard.set(modelName, forKey: "selectedOllamaVisionModel")
        ollamaAPI.selectedModelName = modelName
    }

    /// Queries Ollama for installed vision models and updates availableVisionModels.
    func refreshAvailableVisionModels() async {
        do {
            let discoveredModels = try await ollamaAPI.fetchAvailableVisionModels()
            await MainActor.run {
                self.availableVisionModels = discoveredModels
                if !discoveredModels.isEmpty && !discoveredModels.contains(self.selectedModel) {
                    if let firstDiscoveredModel = discoveredModels.first {
                        self.setSelectedModel(firstDiscoveredModel)
                    }
                }
            }
            print("🦙 Discovered \(discoveredModels.count) Ollama vision models: \(discoveredModels)")
        } catch {
            print("⚠️ Failed to fetch Ollama vision models: \(error)")
        }
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? false
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        // Refresh available Ollama vision models on startup
        Task {
            await refreshAvailableVisionModels()
        }
        textToSpeechProvider.prepare()
        textToSpeechProvider.setSpeechRateMultiplier(speechRateMultiplier)

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementHighlightSize = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
        if !textToSpeechProvider.isPlaying {
            voiceState = .idle
            scheduleTransientHideIfNeeded()
        }
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
        textToSpeechProvider.shutdown()
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                    if self.processingStepText.isEmpty {
                        self.processingStepText = "Audio verarbeiten..."
                    }
                } else if isRecording {
                    self.voiceState = .listening
                    self.processingStepText = ""
                } else if isPreparing {
                    self.voiceState = .processing
                    self.processingStepText = "Mikrofon vorbereiten..."
                } else {
                    // If no response task is active, check whether dictation was not in progress
                    if self.currentResponseTask == nil {
                        self.voiceState = .idle
                        self.processingStepText = ""
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response, TTS, or voice preview from a previous utterance
            currentResponseTask?.cancel()
            stopVoicePreview()
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClickyAnalytics.trackPushToTalkStarted()

            // Pre-capture screenshots immediately when the user presses Control-Option!
            // This captures the exact screen content the user is looking at when asking for help.
            precapturedScreensTask?.cancel()
            precapturedScreensTask = Task { @MainActor in
                try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            }

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil

            // Keep the cursor visible in processing state while audio finishes transcribing
            transientHideTask?.cancel()
            transientHideTask = nil
            voiceState = .processing
            processingStepText = "Audio verarbeiten..."

            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - antworte immer auf deutsch, es sei denn der nutzer spricht explizit auf englisch mit dir.
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    coordinate system:
    use a normalized coordinate grid from 0 to 1000 for each screen image.
    origin (0,0) is top-left, (1000,1000) is bottom-right.
    x ranges from 0 (far left) to 1000 (far right).
    y ranges from 0 (top) to 1000 (bottom).
    always point at the EXACT center of the entire clickable button or element.
    CRITICAL: if a button contains both an icon and text (e.g. "[Fox] GitLab Docs" or "[+] Erstellen"), point at the center of the ENTIRE button (including the text), NOT just the icon on the left edge!

    format: append [POINT:x,y:w,h:label] or [POINT:x,y:label] (with optional :screenN) at the end of your response.
    - x, y: integer center coordinates normalized from 0 to 1000.
    - w, h: optional width and height of the element bounding box normalized from 0 to 1000 (e.g. 110,36).
    - label: short description (1-3 words, like "gitlab logo" or "erstellen").
    - if the element is on the primary screen (cursor screen), omit screen number or append :screen1.
    - if the element is on screen 2, append :screen2 (e.g. [POINT:450,300:120,40:terminal:screen2]).
    - if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks for Apple menu: "hier ist das apple-menü ganz oben links. [POINT:12,12:25,25:apple-menü]"
    - user asks for GitLab Docs logo button: "hier ist das gitlab docs logo. [POINT:250,102:115,36:gitlab docs logo]"
    - user asks for Spotify create button: "klicke hier auf erstellen. [POINT:480,210:95,35:erstellen]"
    - user asks how to search in spotify: "klicke oben auf suchen. [POINT:245,28:120,32:suche]"
    - user asks what html is: "html ist die grundstruktur jeder webseite. [POINT:none]"
    - element is on screen 2: "das terminal ist drüben auf deinem zweiten monitor. [POINT:450,320:200,80:terminal:screen2]"
    """

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        textToSpeechProvider.stopPlayback()

        // Cancel any pending transient hide so the overlay stays visible throughout this response
        transientHideTask?.cancel()
        transientHideTask = nil

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing
            processingStepText = "Bildschirm erfassen..."

            do {
                // Use screens pre-captured at hotkey press, or capture now if not yet available
                let screenCaptures: [CompanionScreenCapture]
                if let task = precapturedScreensTask, let precaptured = try? await task.value {
                    screenCaptures = precaptured
                } else {
                    screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                }
                precapturedScreensTask = nil

                guard !Task.isCancelled else { return }

                processingStepText = "Bild analysieren..."

                // Build image labels with the actual screenshot pixel dimensions
                // so the AI coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Pass conversation history so Ollama remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                // Start speech session before the LLM begins streaming text so sentences
                // can be enqueued and synthesized concurrently in real time.
                let sentenceSegmenter = SpeechSentenceSegmenter()
                textToSpeechProvider.beginSpeechSession(
                    onFirstAudioStarted: { [weak self] in
                        guard let self = self else { return }
                        // Only transition to responding if not pointing to an element
                        if self.detectedElementScreenLocation == nil {
                            self.voiceState = .responding
                            self.processingStepText = ""
                        }
                    },
                    onPlaybackFinished: { [weak self] in
                        guard let self = self else { return }
                        // If pointing is already finished or there was no pointing,
                        // transition to idle and start the 5-second transient hide timer.
                        if self.detectedElementScreenLocation == nil {
                            self.voiceState = .idle
                            self.processingStepText = ""
                            self.scheduleTransientHideIfNeeded()
                        }
                    }
                )

                let (fullResponseText, _) = try await ollamaAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.companionVoiceResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    onTextChunk: { [weak self] currentAccumulatedText in
                        guard let self = self else { return }
                        if self.processingStepText != "Antwort generieren..." && self.voiceState == .processing {
                            self.processingStepText = "Antwort generieren..."
                        }
                        let newSentences = sentenceSegmenter.appendAccumulatedResponseText(currentAccumulatedText)
                        for sentence in newSentences {
                            self.textToSpeechProvider.enqueueSentenceForSpeech(sentence)
                        }
                    }
                )

                guard !Task.isCancelled else { return }

                // Enqueue any final remaining sentences and close the speech session
                let remainingSentences = sentenceSegmenter.flushRemainingSentences()
                for remainingSentence in remainingSentences {
                    textToSpeechProvider.enqueueSentenceForSpeech(remainingSentence)
                }
                textToSpeechProvider.finishSpeechSession()

                // Parse the [POINT:...] tag from the model's response
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                // Handle element pointing if coordinates were returned.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                    processingStepText = ""
                } else if textToSpeechProvider.hasCurrentSessionStartedAudio {
                    voiceState = .responding
                    processingStepText = ""
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Modern vision models (like Gemma 4, Qwen 2.5-VL) output coordinates
                    // normalized in a 0..1000 grid. If coordinates are <= 1000, treat them as 0..1000.
                    // If a model ever outputs raw pixel coordinates > 1000, normalize by screenshot dimensions.
                    let isNormalizedGrid = pointCoordinate.x <= 1000.0 && pointCoordinate.y <= 1000.0

                    let normalizedX: CGFloat
                    let normalizedY: CGFloat

                    if isNormalizedGrid {
                        normalizedX = max(0.0, min(pointCoordinate.x, 1000.0)) / 1000.0
                        normalizedY = max(0.0, min(pointCoordinate.y, 1000.0)) / 1000.0
                    } else {
                        let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                        let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                        normalizedX = max(0.0, min(pointCoordinate.x, screenshotWidth)) / max(1.0, screenshotWidth)
                        normalizedY = max(0.0, min(pointCoordinate.y, screenshotHeight)) / max(1.0, screenshotHeight)
                    }

                    // Scale normalized 0..1 coordinates to display points (points are what macOS UI uses)
                    let displayLocalX = normalizedX * displayWidth
                    let displayLocalY = normalizedY * displayHeight

                    // Convert from top-left origin (vision model) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    var finalGlobalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    // Calculate highlight bounding box size in display points
                    var finalHighlightWidth: CGFloat
                    var finalHighlightHeight: CGFloat
                    if let parsedSize = parseResult.size, parsedSize.width > 0 && parsedSize.height > 0 {
                        let isSizeNorm = parsedSize.width <= 1000.0 && parsedSize.height <= 1000.0
                        let normW = isSizeNorm ? (parsedSize.width / 1000.0) : (parsedSize.width / CGFloat(targetScreenCapture.screenshotWidthInPixels))
                        let normH = isSizeNorm ? (parsedSize.height / 1000.0) : (parsedSize.height / CGFloat(targetScreenCapture.screenshotHeightInPixels))
                        finalHighlightWidth = max(50.0, min(normW * displayWidth, 600.0))
                        finalHighlightHeight = max(24.0, min(normH * displayHeight, 300.0))
                    } else {
                        // Default element highlight box size
                        finalHighlightWidth = 140.0
                        finalHighlightHeight = 38.0
                    }

                    // High-precision OCR text snapping via Apple Vision framework:
                    // If the user's query refers to a text button, menu item, or playlist,
                    // snap the coordinate and bounding box to the exact text element!
                    let candidateKeywords = Self.buildCandidateKeywords(label: parseResult.elementLabel)
                    if let snappedMatch = CompanionScreenCaptureUtility.snapToMatchingTextElement(
                        primaryTargetLabel: parseResult.elementLabel,
                        candidateKeywords: candidateKeywords,
                        near: finalGlobalLocation,
                        targetScreenCapture: targetScreenCapture
                    ) {
                        finalGlobalLocation = snappedMatch.globalCenter
                        finalHighlightWidth = snappedMatch.globalRect.width
                        finalHighlightHeight = snappedMatch.globalRect.height
                    }

                    detectedElementHighlightSize = CGSize(width: finalHighlightWidth, height: finalHighlightHeight)
                    detectedElementBubbleText = parseResult.elementLabel
                    detectedElementDisplayFrame = displayFrame
                    detectedElementScreenLocation = finalGlobalLocation
                    ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)

                    let screenIndexDescription = parseResult.screenNumber.map { "screen \($0)" } ?? "cursor screen"
                    print("🎯 Element pointing: raw=(\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) norm=(\(String(format: "%.1f%%", normalizedX * 100)), \(String(format: "%.1f%%", normalizedY * 100))) on \(screenIndexDescription) (\(Int(displayWidth))x\(Int(displayHeight)) pt) → displayLocal=(\(Int(displayLocalX)), \(Int(displayLocalY))) global=(\(Int(finalGlobalLocation.x)), \(Int(finalGlobalLocation.y))) [\"\(parseResult.elementLabel ?? "element")\"] size=(\(Int(finalHighlightWidth))x\(Int(finalHighlightHeight)))")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)
            } catch is CancellationError {
                // User spoke again — response was interrupted
                textToSpeechProvider.stopPlayback()
                processingStepText = ""
            } catch {
                textToSpeechProvider.stopPlayback()
                processingStepText = ""
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                speakLocalErrorFallback(errorMessage: "Ollama is not running or encountered an error. Please make sure Ollama is running.")
            }

            if !Task.isCancelled {
                // If neither pointing nor TTS is active, switch to idle and schedule hide.
                // Otherwise, the active process (pointing landing or TTS finish) will trigger it.
                if detectedElementScreenLocation == nil && !textToSpeechProvider.isPlaying {
                    voiceState = .idle
                    processingStepText = ""
                    scheduleTransientHideIfNeeded()
                } else if detectedElementScreenLocation == nil && textToSpeechProvider.isPlaying {
                    voiceState = .responding
                    processingStepText = ""
                }
            }
            currentResponseTask = nil
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 5-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while textToSpeechProvider.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 5 seconds after everything finishes (returning to cursor and speaking),
            // then smoothly fade out.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks an error message using macOS system TTS when local Ollama or TTS fails.
    private func speakLocalErrorFallback(errorMessage: String) {
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(errorMessage)
        voiceState = .responding
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from the model's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed center coordinate (normalized 0..1000), or nil if none found.
        let coordinate: CGPoint?
        /// The parsed bounding box size (normalized 0..1000), or nil if not provided.
        let size: CGSize?
        /// Short label describing the element (e.g. "gitlab logo"), or nil.
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:w,h:label:screenN] or [POINT:x,y:label] or [POINT:none] tag from the model's response.
    /// Returns the spoken text (tag removed) along with coordinates, optional bounding box size, label, and screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        let tagPattern = #"\[(?:POINT\s*:\s*)?([^\]\n]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: tagPattern, options: [.caseInsensitive]) else {
            return PointingParseResult(spokenText: responseText, coordinate: nil, size: nil, elementLabel: nil, screenNumber: nil)
        }

        let fullRange = NSRange(responseText.startIndex..., in: responseText)
        let matches = regex.matches(in: responseText, options: [], range: fullRange)

        guard let lastMatch = matches.last,
              let fullMatchRange = Range(lastMatch.range, in: responseText),
              let innerMatchRange = Range(lastMatch.range(at: 1), in: responseText) else {
            return PointingParseResult(spokenText: responseText, coordinate: nil, size: nil, elementLabel: nil, screenNumber: nil)
        }

        var cleanSpokenText = responseText
        cleanSpokenText.removeSubrange(fullMatchRange)
        cleanSpokenText = cleanSpokenText.trimmingCharacters(in: .whitespacesAndNewlines)

        let innerTag = String(responseText[innerMatchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        if innerTag.lowercased() == "none" {
            return PointingParseResult(spokenText: cleanSpokenText, coordinate: nil, size: nil, elementLabel: "none", screenNumber: nil)
        }

        let tokens = innerTag.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !tokens.isEmpty else {
            return PointingParseResult(spokenText: cleanSpokenText, coordinate: nil, size: nil, elementLabel: nil, screenNumber: nil)
        }

        var parsedCoordinate: CGPoint? = nil
        var parsedSize: CGSize? = nil
        var parsedLabel: String? = nil
        var parsedScreenNumber: Int? = nil

        var remainingTokens = tokens

        func extractNumbers(from string: String) -> [Double] {
            string.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "x" })
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }

        // Check if token 0 has 2 or 4 numbers (e.g. "x,y" or "x,y,w,h")
        if !remainingTokens.isEmpty {
            let nums = extractNumbers(from: remainingTokens[0])
            if nums.count >= 4 {
                parsedCoordinate = CGPoint(x: nums[0], y: nums[1])
                parsedSize = CGSize(width: nums[2], height: nums[3])
                remainingTokens.removeFirst()
            } else if nums.count >= 2 {
                parsedCoordinate = CGPoint(x: nums[0], y: nums[1])
                remainingTokens.removeFirst()
            }
        }

        // Check if token 1 provides w,h size (e.g. "115,36")
        if parsedSize == nil && !remainingTokens.isEmpty {
            let nums = extractNumbers(from: remainingTokens[0])
            if nums.count >= 2 {
                parsedSize = CGSize(width: nums[0], height: nums[1])
                remainingTokens.removeFirst()
            }
        }

        // Check remaining tokens for screen number and label
        for token in remainingTokens {
            let lower = token.lowercased()
            if let screenMatch = lower.range(of: #"^screen\s*(\d+)$"#, options: [.regularExpression]) {
                let digits = lower[screenMatch].filter(\.isNumber)
                if let num = Int(digits) {
                    parsedScreenNumber = num
                }
            } else if !token.isEmpty {
                if parsedLabel == nil {
                    parsedLabel = token
                } else {
                    parsedLabel = (parsedLabel ?? "") + " " + token
                }
            }
        }

        return PointingParseResult(
            spokenText: cleanSpokenText,
            coordinate: parsedCoordinate,
            size: parsedSize,
            elementLabel: parsedLabel,
            screenNumber: parsedScreenNumber
        )
    }

    /// Extracts candidate keywords from the element label to search for via Apple Vision OCR.
    /// Stray words from the user's transcript are excluded so unrelated text on screen
    /// (e.g. application names like "Xcode" in the menu bar) cannot hijack pointing away from the target element.
    private static func buildCandidateKeywords(label: String?) -> [String] {
        var candidates: [String] = []

        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty,
              label.lowercased() != "none" else {
            return []
        }

        candidates.append(label)
        let words = label.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        candidates.append(contentsOf: words)

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.lowercased()).inserted }
    }


    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await ollamaAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
