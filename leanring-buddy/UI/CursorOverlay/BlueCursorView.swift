//
//  BlueCursorView.swift
//  leanring-buddy
//
//  SwiftUI view for the blue glowing cursor companion on a single monitor.
//  Hosts the triangle cursor, waveform, spinner, element highlight, and speech bubbles.
//

import SwiftUI
import AppKit

struct BlueCursorView: View {
    let screenFrame: CGRect
    let isFirstAppearance: Bool
    @ObservedObject var companionManager: CompanionManager

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(screenFrame: CGRect, isFirstAppearance: Bool, companionManager: CompanionManager) {
        self.screenFrame = screenFrame
        self.isFirstAppearance = isFirstAppearance
        self.companionManager = companionManager

        // Seed the cursor position from the current mouse location so the
        // buddy doesn't flash at (0,0) before onAppear fires.
        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: CGPoint(x: localX + 35, y: localY + 25))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }

    @State private var timer: Timer?
    @State private var welcomeText: String = ""
    @State private var showWelcome: Bool = true
    @State private var bubbleSize: CGSize = .zero
    @State private var bubbleOpacity: Double = 1.0
    @State private var cursorOpacity: Double = 0.0

    // MARK: - Buddy Navigation State

    /// The buddy's current behavioral mode (following cursor, navigating, or pointing).
    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor

    /// The rotation angle of the triangle in degrees. Default is -35° (cursor-like).
    /// Changes to face the direction of travel when navigating to a target.
    @State private var triangleRotationDegrees: Double = -35.0

    /// Speech bubble text shown when pointing at a detected element.
    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero

    /// The cursor position at the moment navigation started, used to detect
    /// if the user moves the cursor enough to cancel the navigation.
    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero

    /// Timer driving the frame-by-frame bezier arc flight animation.
    @State private var navigationAnimationTimer: Timer?

    /// Scale factor applied to the buddy triangle during flight. Grows to ~1.3x
    /// at the midpoint of the arc and shrinks back to 1.0x on landing.
    @State private var buddyFlightScale: CGFloat = 1.0

    /// Scale factor for the navigation speech bubble's pop-in entrance.
    @State private var navigationBubbleScale: CGFloat = 1.0

    /// True when the buddy is flying BACK to the cursor after pointing.
    @State private var isReturningToCursor: Bool = false

    /// Bounding rectangle for highlighting the targeted UI element on this screen.
    @State private var targetHighlightRect: CGRect?
    /// Whether the target element highlight overlay is visible.
    @State private var showTargetHighlight: Bool = false

    private let fullWelcomeMessage = "hey! i'm clicky"

    private let navigationPointerPhrases = [
        "right here!",
        "this one!",
        "over here!",
        "click this!",
        "here it is!",
        "found it!"
    ]

    var body: some View {
        ZStack {
            // Nearly transparent background (helps with compositing)
            Color.black.opacity(0.001)

            // Welcome speech bubble (first launch only)
            if isCursorOnThisScreen && showWelcome && !welcomeText.isEmpty {
                Text(welcomeText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(bubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.5), value: bubbleOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Onboarding prompt — "press control + option and say hi" streamed after video ends
            if isCursorOnThisScreen && companionManager.showOnboardingPrompt && !companionManager.onboardingPromptText.isEmpty {
                Text(companionManager.onboardingPromptText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(companionManager.onboardingPromptOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.4), value: companionManager.onboardingPromptOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Element Highlight Overlay — Semi-transparent blue fill (~20%) + dashed border + anchor dot.
            if let highlightRect = targetHighlightRect, showTargetHighlight {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DS.Colors.overlayCursorBlue.opacity(0.20))

                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            DS.Colors.overlayCursorBlue,
                            style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                        )
                        .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.4), radius: 6, x: 0, y: 0)

                    Circle()
                        .fill(Color.white)
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle()
                                .stroke(DS.Colors.overlayCursorBlue, lineWidth: 1.5)
                        )
                        .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.8), radius: 4, x: 0, y: 0)
                        .position(x: highlightRect.width, y: highlightRect.height)
                }
                .frame(width: highlightRect.width, height: highlightRect.height)
                .position(x: highlightRect.midX, y: highlightRect.midY)
                .scaleEffect(showTargetHighlight ? 1.0 : 0.85)
                .opacity(showTargetHighlight ? 1.0 : 0.0)
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: showTargetHighlight)
                .allowsHitTesting(false)
            }

            // Navigation pointer bubble — shown when buddy arrives at a detected element.
            if buddyNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty {
                Text(navigationBubbleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(
                                color: DS.Colors.overlayCursorBlue.opacity(0.5 + (1.0 - navigationBubbleScale) * 1.0),
                                radius: 6 + (1.0 - navigationBubbleScale) * 16,
                                x: 0, y: 0
                            )
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: NavigationBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .scaleEffect(navigationBubbleScale)
                    .opacity(navigationBubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (navigationBubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: navigationBubbleScale)
                    .animation(.easeOut(duration: 0.5), value: navigationBubbleOpacity)
                    .onPreferenceChange(NavigationBubbleSizePreferenceKey.self) { newSize in
                        navigationBubbleSize = newSize
                    }
            }

            // Blue triangle cursor — shown when idle or while TTS is playing (responding).
            Triangle()
                .fill(DS.Colors.overlayCursorBlue)
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(triangleRotationDegrees))
                .shadow(color: DS.Colors.overlayCursorBlue, radius: 8 + (buddyFlightScale - 1.0) * 20, x: 0, y: 0)
                .scaleEffect(buddyFlightScale)
                .opacity(
                    buddyIsVisibleOnThisScreen && (
                        buddyNavigationMode != .followingCursor ||
                        companionManager.voiceState == .idle ||
                        companionManager.voiceState == .responding
                    ) ? cursorOpacity : 0
                )
                .position(cursorPosition)
                .animation(
                    buddyNavigationMode == .followingCursor
                        ? .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
                        : nil,
                    value: cursorPosition
                )
                .animation(.easeIn(duration: 0.25), value: companionManager.voiceState)
                .animation(
                    buddyNavigationMode == .navigatingToTarget ? nil : .easeInOut(duration: 0.3),
                    value: triangleRotationDegrees
                )

            // Blue waveform — replaces the triangle while listening
            BlueCursorWaveformView(audioPowerLevel: companionManager.currentAudioPowerLevel)
                .opacity(
                    buddyIsVisibleOnThisScreen &&
                    buddyNavigationMode == .followingCursor &&
                    companionManager.voiceState == .listening ? cursorOpacity : 0
                )
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

            // Blue spinner — shown while the AI is processing
            BlueCursorSpinnerView(statusText: companionManager.processingStepText)
                .opacity(
                    buddyIsVisibleOnThisScreen &&
                    buddyNavigationMode == .followingCursor &&
                    companionManager.voiceState == .processing ? cursorOpacity : 0
                )
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)
                .animation(.easeInOut(duration: 0.2), value: companionManager.processingStepText)
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)

            let swiftUIPosition = CursorFlightAnimator.convertScreenPointToSwiftUICoordinates(mouseLocation, screenFrame: screenFrame)
            self.cursorPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)

            startTrackingCursor()

            if isFirstAppearance && isCursorOnThisScreen {
                withAnimation(.easeIn(duration: 2.0)) {
                    self.cursorOpacity = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                    startWelcomeAnimation()
                }
            } else {
                self.cursorOpacity = 1.0
            }
        }
        .onDisappear {
            timer?.invalidate()
            navigationAnimationTimer?.invalidate()
        }
        .onChange(of: companionManager.detectedElementScreenLocation) { newLocation in
            guard let screenLocation = newLocation else { return }

            let isTargetOnThisScreen: Bool
            if let displayFrame = companionManager.detectedElementDisplayFrame {
                isTargetOnThisScreen = NSScreen.screens.count <= 1
                    || screenFrame.contains(CGPoint(x: displayFrame.midX, y: displayFrame.midY))
                    || displayFrame == screenFrame
                    || screenFrame.intersects(displayFrame)
            } else {
                isTargetOnThisScreen = isCursorOnThisScreen || NSScreen.screens.count <= 1
            }

            guard isTargetOnThisScreen else { return }

            startNavigatingToElement(screenLocation: screenLocation)
        }
    }

    /// Whether the buddy triangle should be visible on this screen.
    private var buddyIsVisibleOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .followingCursor:
            if let displayFrame = companionManager.detectedElementDisplayFrame {
                let isTargetOnThisScreen = NSScreen.screens.count <= 1
                    || screenFrame.contains(CGPoint(x: displayFrame.midX, y: displayFrame.midY))
                    || displayFrame == screenFrame
                    || screenFrame.intersects(displayFrame)
                if !isTargetOnThisScreen {
                    return false
                }
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    // MARK: - Cursor Tracking

    private func startTrackingCursor() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            let mouseLocation = NSEvent.mouseLocation
            let mouseIsOnThisScreen = self.screenFrame.contains(mouseLocation)
            self.isCursorOnThisScreen = mouseIsOnThisScreen

            guard mouseIsOnThisScreen else { return }

            if self.buddyNavigationMode == .navigatingToTarget && self.isReturningToCursor {
                let currentMouseInSwiftUI = CursorFlightAnimator.convertScreenPointToSwiftUICoordinates(mouseLocation, screenFrame: self.screenFrame)
                let distanceFromNavigationStart = hypot(
                    currentMouseInSwiftUI.x - self.cursorPositionWhenNavigationStarted.x,
                    currentMouseInSwiftUI.y - self.cursorPositionWhenNavigationStarted.y
                )
                if distanceFromNavigationStart > 100 {
                    cancelNavigationAndResumeFollowing()
                }
                return
            }

            if self.buddyNavigationMode != .followingCursor {
                return
            }

            let swiftUIPosition = CursorFlightAnimator.convertScreenPointToSwiftUICoordinates(mouseLocation, screenFrame: self.screenFrame)
            let buddyX = swiftUIPosition.x + 35
            let buddyY = swiftUIPosition.y + 25
            self.cursorPosition = CGPoint(x: buddyX, y: buddyY)
        }
    }

    // MARK: - Element Navigation

    private func startNavigatingToElement(screenLocation: CGPoint) {
        guard !showWelcome || welcomeText.isEmpty else { return }

        let highlightData = CursorFlightAnimator.calculateElementHighlightAndLanding(
            screenLocation: screenLocation,
            highlightSize: companionManager.detectedElementHighlightSize,
            screenFrame: screenFrame
        )
        self.targetHighlightRect = highlightData.highlightRect
        let clampedTarget = highlightData.landingPoint

        let initialFlightStart = CursorFlightAnimator.getLiveMouseOrigin(from: NSEvent.mouseLocation, screenFrame: screenFrame)

        self.cursorPosition = initialFlightStart
        self.cursorPositionWhenNavigationStarted = initialFlightStart

        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false
        showTargetHighlight = false

        animateDynamicFlightToTarget(destination: clampedTarget) {
            guard self.buddyNavigationMode == .navigatingToTarget else { return }
            self.startPointingAtElement()
        }
    }

    private func animateDynamicFlightToTarget(
        destination: CGPoint,
        onComplete: @escaping () -> Void
    ) {
        navigationAnimationTimer?.invalidate()

        let endPosition = destination
        let initialOrigin = CursorFlightAnimator.getLiveMouseOrigin(from: NSEvent.mouseLocation, screenFrame: screenFrame)
        let initialDeltaX = endPosition.x - initialOrigin.x
        let initialDeltaY = endPosition.y - initialOrigin.y
        let initialDistance = hypot(initialDeltaX, initialDeltaY)

        let flightDurationSeconds = CursorFlightAnimator.calculateFlightDuration(distance: initialDistance)
        let frameInterval: Double = 1.0 / 60.0
        let totalFrames = CursorFlightAnimator.calculateTotalFrames(duration: flightDurationSeconds, frameInterval: frameInterval)
        var currentFrame = 0

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            currentFrame += 1

            if currentFrame >= totalFrames {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = endPosition
                self.buddyFlightScale = 1.0
                onComplete()
                return
            }

            let currentLiveOrigin = CursorFlightAnimator.getLiveMouseOrigin(from: NSEvent.mouseLocation, screenFrame: self.screenFrame)
            let step = CursorFlightAnimator.evaluateDynamicFlightStep(
                currentFrame: currentFrame,
                totalFrames: totalFrames,
                currentLiveOrigin: currentLiveOrigin,
                destination: endPosition
            )

            self.cursorPosition = step.position
            if let rotation = step.rotationDegrees {
                self.triangleRotationDegrees = rotation
            }
            self.buddyFlightScale = step.scale
        }
    }

    private func animateBezierFlightArc(
        from startPosition: CGPoint,
        to destination: CGPoint,
        onComplete: @escaping () -> Void
    ) {
        navigationAnimationTimer?.invalidate()

        let endPosition = destination
        let deltaX = endPosition.x - startPosition.x
        let deltaY = endPosition.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        let flightDurationSeconds = CursorFlightAnimator.calculateFlightDuration(distance: distance)
        let frameInterval: Double = 1.0 / 60.0
        let totalFrames = CursorFlightAnimator.calculateTotalFrames(duration: flightDurationSeconds, frameInterval: frameInterval)
        var currentFrame = 0

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            currentFrame += 1

            if currentFrame > totalFrames {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = endPosition
                self.buddyFlightScale = 1.0
                onComplete()
                return
            }

            let step = CursorFlightAnimator.evaluateStaticFlightStep(
                currentFrame: currentFrame,
                totalFrames: totalFrames,
                startPosition: startPosition,
                destination: endPosition
            )

            self.cursorPosition = step.position
            if let rotation = step.rotationDegrees {
                self.triangleRotationDegrees = rotation
            }
            self.buddyFlightScale = step.scale
        }
    }

    private func startPointingAtElement() {
        buddyNavigationMode = .pointingAtTarget
        triangleRotationDegrees = -35.0

        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            showTargetHighlight = true
        }

        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = 0.5

        let pointerPhrase = companionManager.detectedElementBubbleText
            ?? navigationPointerPhrases.randomElement()
            ?? "right here!"

        streamNavigationBubbleCharacter(phrase: pointerPhrase, characterIndex: 0) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard self.buddyNavigationMode == .pointingAtTarget else { return }
                self.navigationBubbleOpacity = 0.0
                withAnimation(.easeOut(duration: 0.3)) {
                    self.showTargetHighlight = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard self.buddyNavigationMode == .pointingAtTarget else { return }
                    self.startFlyingBackToCursor()
                }
            }
        }
    }

    private func streamNavigationBubbleCharacter(
        phrase: String,
        characterIndex: Int,
        onComplete: @escaping () -> Void
    ) {
        guard buddyNavigationMode == .pointingAtTarget else { return }
        guard characterIndex < phrase.count else {
            onComplete()
            return
        }

        let charIndex = phrase.index(phrase.startIndex, offsetBy: characterIndex)
        navigationBubbleText.append(phrase[charIndex])

        if characterIndex == 0 {
            navigationBubbleScale = 1.0
        }

        let characterDelay = Double.random(in: 0.03...0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + characterDelay) {
            self.streamNavigationBubbleCharacter(
                phrase: phrase,
                characterIndex: characterIndex + 1,
                onComplete: onComplete
            )
        }
    }

    private func startFlyingBackToCursor() {
        let mouseLocation = NSEvent.mouseLocation
        if screenFrame.contains(mouseLocation) {
            let cursorInSwiftUI = CursorFlightAnimator.convertScreenPointToSwiftUICoordinates(mouseLocation, screenFrame: screenFrame)
            let cursorWithTrackingOffset = CGPoint(x: cursorInSwiftUI.x + 35, y: cursorInSwiftUI.y + 25)

            cursorPositionWhenNavigationStarted = cursorInSwiftUI
            buddyNavigationMode = .navigatingToTarget
            isReturningToCursor = true

            animateBezierFlightArc(from: self.cursorPosition, to: cursorWithTrackingOffset) {
                self.finishNavigationAndResumeFollowing()
            }
        } else {
            withAnimation(.easeOut(duration: 0.3)) {
                self.navigationBubbleOpacity = 0.0
                self.cursorOpacity = 0.0
                self.showTargetHighlight = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.finishNavigationAndResumeFollowing()
            }
        }
    }

    private func cancelNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        showTargetHighlight = false
        targetHighlightRect = nil
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        buddyFlightScale = 1.0
        finishNavigationAndResumeFollowing()
    }

    private func finishNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        showTargetHighlight = false
        targetHighlightRect = nil
        triangleRotationDegrees = -35.0
        buddyFlightScale = 1.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        cursorOpacity = 1.0
        companionManager.clearDetectedElementLocation()
    }

    // MARK: - Welcome Animation

    private func startWelcomeAnimation() {
        withAnimation(.easeIn(duration: 0.4)) {
            self.bubbleOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < self.fullWelcomeMessage.count else {
                timer.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.showWelcome = false
                }
                return
            }

            let index = self.fullWelcomeMessage.index(self.fullWelcomeMessage.startIndex, offsetBy: currentIndex)
            self.welcomeText.append(self.fullWelcomeMessage[index])
            currentIndex += 1
        }
    }
}

// MARK: - Blue Cursor Waveform

/// A small blue waveform that replaces the triangle cursor while
/// the user is holding the push-to-talk shortcut and speaking.
struct BlueCursorWaveformView: View {
    let audioPowerLevel: CGFloat

    private let barCount = 5
    private let listeningBarProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timelineContext in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { barIndex in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(DS.Colors.overlayCursorBlue)
                        .frame(
                            width: 2,
                            height: barHeight(
                                for: barIndex,
                                timelineDate: timelineContext.date
                            )
                        )
                }
            }
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
            .animation(.linear(duration: 0.08), value: audioPowerLevel)
        }
    }

    private func barHeight(for barIndex: Int, timelineDate: Date) -> CGFloat {
        let animationPhase = CGFloat(timelineDate.timeIntervalSinceReferenceDate * 3.6) + CGFloat(barIndex) * 0.35
        let normalizedAudioPowerLevel = max(audioPowerLevel - 0.008, 0)
        let easedAudioPowerLevel = pow(min(normalizedAudioPowerLevel * 2.85, 1), 0.76)
        let reactiveHeight = easedAudioPowerLevel * 10 * listeningBarProfile[barIndex]
        let idlePulse = (sin(animationPhase) + 1) / 2 * 1.5
        return 3 + reactiveHeight + idlePulse
    }
}

// MARK: - Blue Cursor Spinner

/// A small blue spinning indicator with an optional status label that replaces
/// the triangle cursor while the AI is processing a voice input.
struct BlueCursorSpinnerView: View {
    let statusText: String
    @State private var isSpinning = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .trim(from: 0.15, to: 0.85)
                .stroke(
                    AngularGradient(
                        colors: [
                            DS.Colors.overlayCursorBlue.opacity(0.0),
                            DS.Colors.overlayCursorBlue
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(isSpinning ? 360 : 0))
                .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
                .onAppear {
                    withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                        isSpinning = true
                    }
                }

            if !statusText.isEmpty {
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue.opacity(0.92))
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
    }
}
