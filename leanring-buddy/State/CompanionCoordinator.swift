//
//  CompanionCoordinator.swift
//  leanring-buddy
//
//  Central state coordinator and state machine for Clicky companion.
//  Coordinates push-to-talk, speech recognition, vision chat,
//  speech synthesis, and cursor overlay pointing animations.
//

import AppKit
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

@MainActor
open class CompanionCoordinator: ObservableObject {

    // MARK: - Published UI & Coordination State

    @Published public internal(set) var voiceState: CompanionVoiceState = .idle
    @Published public internal(set) var lastTranscript: String?
    @Published public internal(set) var currentAudioPowerLevel: CGFloat = 0
    @Published public internal(set) var processingStepText: String = ""

    @Published public internal(set) var hasAccessibilityPermission: Bool = false
    @Published public internal(set) var hasScreenRecordingPermission: Bool = false
    @Published public internal(set) var hasMicrophonePermission: Bool = false
    @Published public internal(set) var hasScreenContentPermission: Bool = false
    @Published public internal(set) var isRequestingScreenContent: Bool = false

    @Published public var detectedElementScreenLocation: CGPoint?
    @Published public var detectedElementDisplayFrame: CGRect?
    @Published public var detectedElementBubbleText: String?
    @Published public var detectedElementHighlightSize: CGSize?

    @Published public internal(set) var isOverlayVisible: Bool = false
    @Published public var isClickyCursorEnabled: Bool = false
    @Published public var selectedModel: String = "llama3.2-vision"
    @Published public var availableVisionModels: [String] = []

    @Published public var selectedTTSModelId: String = TTSModelCatalog.defaultModelId
    @Published public var selectedTTSLanguageCode: String = "German"
    @Published public var selectedVoice: String = "Seraphina"
    @Published public var isPlayingVoicePreview: Bool = false
    @Published public var speechRateMultiplier: Double = 1.0

    @Published public var onboardingPromptText: String = ""
    @Published public var onboardingPromptOpacity: Double = 0.0
    @Published public var showOnboardingPrompt: Bool = false
    @Published public var hasSubmittedEmail: Bool = false

    // MARK: - Dependencies

    public let permissionsManager: any PermissionsManaging
    public let settingsStorage: any SettingsStoring
    public let onboardingAudioPlayer: OnboardingAudioPlayer
    public let onboardingLeadService: OnboardingLeadService
    public let buddyDictationManager: BuddyDictationManager
    public let globalPushToTalkShortcutMonitor: GlobalPushToTalkShortcutMonitor
    public let overlayWindowManager: OverlayWindowManager
    public let textToSpeechProvider: any TextToSpeechProvider
    public let ollamaAPI: OllamaAPI

    // MARK: - Internal Tasks & Subscriptions

    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []
    private var currentResponseTask: Task<Void, Never>?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    private var precapturedScreensTask: Task<[CompanionScreenCapture], Error>?
    private var transientHideTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?

    // MARK: - Computed Properties

    public var allPermissionsGranted: Bool {
        permissionsManager.allPermissionsGranted
    }

    public var availableTTSModels: [TTSModelOption] {
        TTSModelCatalog.allModels
    }

    public var currentTTSModel: TTSModelOption {
        TTSModelCatalog.model(withId: selectedTTSModelId)
    }

    public var availableLanguagesForCurrentModel: [TTSLanguageOption] {
        currentTTSModel.supportedLanguages
    }

    public var availableVoices: [String] {
        currentTTSModel.availableVoices
    }

    public var availableSpeechRates: [Double] {
        [0.85, 1.0, 1.1, 1.2, 1.25, 1.4, 1.5]
    }

    public var hasCompletedOnboarding: Bool {
        get { settingsStorage.bool(forKey: "hasCompletedOnboarding") }
        set { settingsStorage.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    public var hasActiveUserInteractionOrBackgroundProcess: Bool {
        globalPushToTalkShortcutMonitor.isShortcutCurrentlyPressed
            || buddyDictationManager.isDictationInProgress
            || buddyDictationManager.isActivelyRecordingAudio
            || pendingKeyboardShortcutStartTask != nil
            || currentResponseTask != nil
            || precapturedScreensTask != nil
            || textToSpeechProvider.isPlaying
            || isPlayingVoicePreview
            || detectedElementScreenLocation != nil
            || voiceState != .idle
    }

    // MARK: - Initialization

    public init(
        permissionsManager: any PermissionsManaging = PermissionsManager(),
        settingsStorage: any SettingsStoring = UserDefaultsSettingsStorage(),
        onboardingAudioPlayer: OnboardingAudioPlayer = OnboardingAudioPlayer(),
        onboardingLeadService: OnboardingLeadService = OnboardingLeadService(),
        buddyDictationManager: BuddyDictationManager = BuddyDictationManager(),
        globalPushToTalkShortcutMonitor: GlobalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor(),
        overlayWindowManager: OverlayWindowManager = OverlayWindowManager(),
        textToSpeechProvider: (any TextToSpeechProvider)? = nil,
        ollamaAPI: OllamaAPI? = nil
    ) {
        self.permissionsManager = permissionsManager
        self.settingsStorage = settingsStorage
        self.onboardingAudioPlayer = onboardingAudioPlayer
        self.onboardingLeadService = onboardingLeadService
        self.buddyDictationManager = buddyDictationManager
        self.globalPushToTalkShortcutMonitor = globalPushToTalkShortcutMonitor
        self.overlayWindowManager = overlayWindowManager

        let persistedModel = settingsStorage.string(forKey: "selectedOllamaVisionModel") ?? "llama3.2-vision"
        self.selectedModel = persistedModel
        self.ollamaAPI = ollamaAPI ?? OllamaAPI(selectedModelName: persistedModel)

        let resolvedTTSProvider = textToSpeechProvider ?? TextToSpeechProviderFactory.makeDefaultProvider()
        self.textToSpeechProvider = resolvedTTSProvider

        let persistedTTSModelId = settingsStorage.string(forKey: "selectedTTSModelId") ?? TTSModelCatalog.defaultModelId
        self.selectedTTSModelId = persistedTTSModelId

        let activeTTSModel = TTSModelCatalog.model(withId: persistedTTSModelId)
        let persistedTTSLang = settingsStorage.string(forKey: "selectedTTSLanguageCode")
        self.selectedTTSLanguageCode = (persistedTTSLang?.isEmpty == false) ? persistedTTSLang! : activeTTSModel.defaultLanguageCode

        let persistedVoice = settingsStorage.string(forKey: "selectedTTSVoice")
        if let persistedVoice = persistedVoice, activeTTSModel.availableVoices.contains(persistedVoice) {
            self.selectedVoice = persistedVoice
        } else {
            self.selectedVoice = activeTTSModel.defaultVoice
        }

        let persistedSpeed = settingsStorage.double(forKey: "selectedTTSSpeechRate")
        self.speechRateMultiplier = persistedSpeed > 0.1 ? persistedSpeed : 1.0

        self.isClickyCursorEnabled = settingsStorage.bool(forKey: "isClickyCursorEnabled")
        self.hasSubmittedEmail = settingsStorage.bool(forKey: "hasSubmittedEmail")

        self.hasAccessibilityPermission = permissionsManager.hasAccessibilityPermission
        self.hasScreenRecordingPermission = permissionsManager.hasScreenRecordingPermission
        self.hasMicrophonePermission = permissionsManager.hasMicrophonePermission
        self.hasScreenContentPermission = permissionsManager.hasScreenContentPermission
    }

    // MARK: - State Machine Simulation (Testing & State Control)

    /// Simulates user beginning speech input (e.g. push-to-talk keydown).
    /// Cancels any in-progress response task and stops ongoing audio playback (barge-in).
    public func simulateStartListening() {
        currentResponseTask?.cancel()
        currentResponseTask = nil
        textToSpeechProvider.stopPlayback()
        stopVoicePreview()
        clearDetectedElementLocation()

        voiceState = .listening
        processingStepText = ""
    }

    /// Simulates speech synthesis / buddy responding.
    public func simulateStartResponding() {
        voiceState = .responding
        processingStepText = ""
    }

    /// Simulates transition to processing state with an optional descriptive status.
    public func simulateStartProcessing(stepText: String = "Audio verarbeiten...") {
        voiceState = .processing
        processingStepText = stepText
    }

    /// Directly transitions coordinator voice state.
    public func simulateTransition(to newState: CompanionVoiceState) {
        voiceState = newState
        if newState == .idle {
            processingStepText = ""
        }
    }

    public func setProcessingStepText(_ text: String) {
        self.processingStepText = text
    }

    // MARK: - Lifecycle & Observation Bindings

    public func start() {
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")

        permissionsManager.startPolling { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }

        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()

        Task {
            await refreshAvailableVisionModels()
        }

        textToSpeechProvider.prepare()
        textToSpeechProvider.setSpeechRateMultiplier(speechRateMultiplier)

        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    public func stop() {
        permissionsManager.stopPolling()
        onboardingAudioPlayer.stopOnboardingMusic()
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()

        transientHideTask?.cancel()
        transientHideTask = nil
        currentResponseTask?.cancel()
        currentResponseTask = nil
        pendingKeyboardShortcutStartTask?.cancel()
        pendingKeyboardShortcutStartTask = nil
        precapturedScreensTask?.cancel()
        precapturedScreensTask = nil

        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        textToSpeechProvider.shutdown()
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
                    if !self.hasActiveUserInteractionOrBackgroundProcess {
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

    // MARK: - Push-To-Talk Shortcut Handling

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }

            transientHideTask?.cancel()
            transientHideTask = nil

            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Barge-in: cancel active response, speech, and pointing
            currentResponseTask?.cancel()
            currentResponseTask = nil
            stopVoicePreview()
            clearDetectedElementLocation()

            voiceState = .processing
            processingStepText = "Mikrofon vorbereiten..."

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

            precapturedScreensTask?.cancel()
            precapturedScreensTask = Task { @MainActor in
                try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            }

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task { [weak self] in
                await self?.buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
                self?.pendingKeyboardShortcutStartTask = nil
            }

        case .released:
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil

            transientHideTask?.cancel()
            transientHideTask = nil
            voiceState = .processing
            processingStepText = "Audio verarbeiten..."

            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()

        case .none:
            break
        }
    }

    // MARK: - AI Response & Speech Coordination

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

    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        textToSpeechProvider.stopPlayback()

        transientHideTask?.cancel()
        transientHideTask = nil

        currentResponseTask = Task {
            defer {
                precapturedScreensTask = nil
            }

            voiceState = .processing
            processingStepText = "Bildschirm erfassen..."

            do {
                let screenCaptures: [CompanionScreenCapture]
                if let task = precapturedScreensTask, let precaptured = try? await task.value {
                    screenCaptures = precaptured
                } else {
                    screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                }
                precapturedScreensTask = nil

                guard !Task.isCancelled else { return }

                processingStepText = "Bild analysieren..."

                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let sentenceSegmenter = SpeechSentenceSegmenter()
                textToSpeechProvider.beginSpeechSession(
                    onFirstAudioStarted: { [weak self] in
                        guard let self = self else { return }
                        if self.detectedElementScreenLocation == nil {
                            self.voiceState = .responding
                            self.processingStepText = ""
                        }
                    },
                    onPlaybackFinished: { [weak self] in
                        guard let self = self else { return }
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

                let remainingSentences = sentenceSegmenter.flushRemainingSentences()
                for remainingSentence in remainingSentences {
                    textToSpeechProvider.enqueueSentenceForSpeech(remainingSentence)
                }
                textToSpeechProvider.finishSpeechSession()

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                    processingStepText = ""
                } else if textToSpeechProvider.hasCurrentSessionStartedAudio {
                    voiceState = .responding
                    processingStepText = ""
                }

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

                    let displayLocalX = normalizedX * displayWidth
                    let displayLocalY = normalizedY * displayHeight
                    let appKitY = displayHeight - displayLocalY

                    var finalGlobalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    var finalHighlightWidth: CGFloat
                    var finalHighlightHeight: CGFloat
                    if let parsedSize = parseResult.size, parsedSize.width > 0 && parsedSize.height > 0 {
                        let isSizeNorm = parsedSize.width <= 1000.0 && parsedSize.height <= 1000.0
                        let normW = isSizeNorm ? (parsedSize.width / 1000.0) : (parsedSize.width / CGFloat(targetScreenCapture.screenshotWidthInPixels))
                        let normH = isSizeNorm ? (parsedSize.height / 1000.0) : (parsedSize.height / CGFloat(targetScreenCapture.screenshotHeightInPixels))
                        finalHighlightWidth = max(50.0, min(normW * displayWidth, 600.0))
                        finalHighlightHeight = max(24.0, min(normH * displayHeight, 300.0))
                    } else {
                        finalHighlightWidth = 140.0
                        finalHighlightHeight = 38.0
                    }

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

                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")
                ClickyAnalytics.trackAIResponseReceived(response: spokenText)
            } catch is CancellationError {
                textToSpeechProvider.stopPlayback()
                processingStepText = ""
            } catch {
                textToSpeechProvider.stopPlayback()
                processingStepText = ""
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                speakLocalErrorFallback(errorMessage: "Ollama is not running or encountered an error. Please make sure Ollama is running.")
            }

            currentResponseTask = nil

            if !Task.isCancelled {
                if detectedElementScreenLocation == nil && !textToSpeechProvider.isPlaying {
                    voiceState = .idle
                    processingStepText = ""
                    scheduleTransientHideIfNeeded()
                } else if detectedElementScreenLocation == nil && textToSpeechProvider.isPlaying {
                    voiceState = .responding
                    processingStepText = ""
                }
            }
        }
    }

    private func speakLocalErrorFallback(errorMessage: String) {
        voiceState = .responding
        textToSpeechProvider.speakCompleteText(
            errorMessage,
            onFirstAudioStarted: { [weak self] in
                self?.voiceState = .responding
            },
            onPlaybackFinished: { [weak self] in
                guard let self = self else { return }
                self.voiceState = .idle
                self.scheduleTransientHideIfNeeded()
            }
        )
    }

    // MARK: - Transient Overlay Management

    public func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementHighlightSize = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil

        if !hasActiveUserInteractionOrBackgroundProcess {
            voiceState = .idle
            scheduleTransientHideIfNeeded()
        }
    }

    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }
        guard !hasActiveUserInteractionOrBackgroundProcess else {
            transientHideTask?.cancel()
            transientHideTask = nil
            return
        }

        transientHideTask?.cancel()
        transientHideTask = Task {
            let pollingIntervalNanoseconds: UInt64 = 100_000_000 // 100ms
            let requiredContinuousIdleNanoseconds: UInt64 = 5_000_000_000 // 5 seconds
            var accumulatedContinuousIdleNanoseconds: UInt64 = 0

            while accumulatedContinuousIdleNanoseconds < requiredContinuousIdleNanoseconds {
                try? await Task.sleep(nanoseconds: pollingIntervalNanoseconds)
                guard !Task.isCancelled else { return }

                if hasActiveUserInteractionOrBackgroundProcess {
                    accumulatedContinuousIdleNanoseconds = 0
                    while hasActiveUserInteractionOrBackgroundProcess {
                        try? await Task.sleep(nanoseconds: pollingIntervalNanoseconds)
                        guard !Task.isCancelled else { return }
                    }
                } else {
                    accumulatedContinuousIdleNanoseconds += pollingIntervalNanoseconds
                }
            }

            guard !Task.isCancelled else { return }
            guard !hasActiveUserInteractionOrBackgroundProcess else { return }
            guard !isClickyCursorEnabled && isOverlayVisible else { return }

            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
            transientHideTask = nil
        }
    }

    // MARK: - TTS & Voice Preferences

    public func setSelectedTTSModel(_ modelId: String) {
        selectedTTSModelId = modelId
        settingsStorage.set(modelId, forKey: "selectedTTSModelId")

        let modelOption = TTSModelCatalog.model(withId: modelId)
        textToSpeechProvider.setModelName(modelOption.modelRepo ?? "")

        let supportsCurrentLanguage = modelOption.supportedLanguages.contains { $0.code == selectedTTSLanguageCode }
        if !supportsCurrentLanguage {
            setSelectedTTSLanguage(modelOption.defaultLanguageCode)
        } else {
            textToSpeechProvider.setLanguageCode(selectedTTSLanguageCode)
        }

        if !modelOption.availableVoices.contains(selectedVoice) {
            setSelectedVoice(modelOption.defaultVoice)
        } else {
            textToSpeechProvider.setVoiceName(selectedVoice)
        }
        print("🔊 Text-to-speech: model switched to '\(modelOption.displayName)'")
    }

    public func setSelectedTTSLanguage(_ languageCode: String) {
        selectedTTSLanguageCode = languageCode
        settingsStorage.set(languageCode, forKey: "selectedTTSLanguageCode")
        textToSpeechProvider.setLanguageCode(languageCode)
        print("🔊 Text-to-speech: language switched to '\(languageCode)'")
    }

    public func setSelectedVoice(_ voiceName: String) {
        selectedVoice = voiceName
        settingsStorage.set(voiceName, forKey: "selectedTTSVoice")
        textToSpeechProvider.setVoiceName(voiceName)
        print("🔊 Text-to-speech: voice switched to '\(voiceName)'")
    }

    public func playVoicePreview(for voiceName: String? = nil) {
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
            onFirstAudioStarted: {},
            onPlaybackFinished: { [weak self] in
                Task { @MainActor in
                    self?.isPlayingVoicePreview = false
                }
            }
        )
    }

    public func stopVoicePreview() {
        textToSpeechProvider.stopPlayback()
        isPlayingVoicePreview = false
    }

    public func setSpeechRateMultiplier(_ rateMultiplier: Double) {
        speechRateMultiplier = rateMultiplier
        settingsStorage.set(rateMultiplier, forKey: "selectedTTSSpeechRate")
        textToSpeechProvider.setSpeechRateMultiplier(rateMultiplier)
    }

    // MARK: - VLM Model Preferences

    public func setSelectedModel(_ modelName: String) {
        selectedModel = modelName
        settingsStorage.set(modelName, forKey: "selectedOllamaVisionModel")
        ollamaAPI.selectedModelName = modelName
    }

    public func refreshAvailableVisionModels() async {
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

    public func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        settingsStorage.set(enabled, forKey: "isClickyCursorEnabled")
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

    public func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        settingsStorage.set(true, forKey: "hasSubmittedEmail")
        onboardingLeadService.submitLeadInBackground(email: trimmedEmail)
    }

    // MARK: - System Permissions & Onboarding

    public func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        permissionsManager.refreshPermissions()

        hasAccessibilityPermission = permissionsManager.hasAccessibilityPermission
        hasScreenRecordingPermission = permissionsManager.hasScreenRecordingPermission
        hasMicrophonePermission = permissionsManager.hasMicrophonePermission
        hasScreenContentPermission = permissionsManager.hasScreenContentPermission

        if hasAccessibilityPermission {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    public func requestScreenContentPermission() {
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
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    permissionsManager.markScreenContentPermissionGranted()
                    hasScreenContentPermission = permissionsManager.hasScreenContentPermission
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

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

    public func triggerOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        hasCompletedOnboarding = true
        ClickyAnalytics.trackOnboardingStarted()
        onboardingAudioPlayer.startOnboardingMusic()
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
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

    public func performOnboardingDemoInteraction() {
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
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

                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }

    // MARK: - Static Pointing Helpers

    public typealias PointingParseResult = leanring_buddy.PointingParseResult

    public static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        PointingCoordinateParser.parsePointingCoordinates(from: responseText)
    }

    public static func buildCandidateKeywords(label: String?) -> [String] {
        PointingCoordinateParser.buildCandidateKeywords(label: label)
    }
}
