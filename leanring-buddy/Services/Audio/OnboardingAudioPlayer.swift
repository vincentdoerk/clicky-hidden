//
//  OnboardingAudioPlayer.swift
//  leanring-buddy
//
//  Manages playback of onboarding theme music (ff.mp3) and handles automatic
//  fading out over time.
//

import AVFoundation
import Foundation

final class OnboardingAudioPlayer {
    private let audioBundle: Bundle
    private let audioResourceName: String
    private let audioResourceExtension: String

    private var audioPlayer: AVAudioPlayer?
    private var fadeTimer: Timer?

    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    init(
        audioBundle: Bundle = .main,
        audioResourceName: String = "ff",
        audioResourceExtension: String = "mp3"
    ) {
        self.audioBundle = audioBundle
        self.audioResourceName = audioResourceName
        self.audioResourceExtension = audioResourceExtension
    }

    func startOnboardingMusic(
        initialVolume: Float = 0.3,
        playDurationBeforeFade: TimeInterval = 90.0,
        fadeOutDuration: TimeInterval = 3.0
    ) {
        stopOnboardingMusic()

        guard let musicURL = audioBundle.url(forResource: audioResourceName, withExtension: audioResourceExtension) else {
            print("⚠️ Clicky: \(audioResourceName).\(audioResourceExtension) not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = initialVolume
            player.play()
            self.audioPlayer = player

            // After specified duration, fade the music out
            fadeTimer = Timer.scheduledTimer(withTimeInterval: playDurationBeforeFade, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic(fadeOutDuration: fadeOutDuration)
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    func fadeOutOnboardingMusic(fadeOutDuration: TimeInterval = 3.0) {
        guard let player = audioPlayer else { return }

        fadeTimer?.invalidate()

        let fadeSteps = 30
        let stepInterval = fadeOutDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        fadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.audioPlayer = nil
                self?.fadeTimer = nil
            }
        }
    }

    func stopOnboardingMusic() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        audioPlayer?.stop()
        audioPlayer = nil
    }

    deinit {
        stopOnboardingMusic()
    }
}
