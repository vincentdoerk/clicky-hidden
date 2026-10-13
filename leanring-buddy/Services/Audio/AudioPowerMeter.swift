//
//  AudioPowerMeter.swift
//  leanring-buddy
//
//  Calculates root-mean-square (RMS) and normalized power levels from audio buffers.
//

import AVFoundation
import Foundation

final class AudioPowerMeter {
    static let defaultBoostMultiplier: Float = 10.2

    /// Calculates the Root Mean Square (RMS) amplitude from the first float channel of an audio buffer.
    static func calculateRootMeanSquare(from audioBuffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = audioBuffer.floatChannelData else { return 0.0 }

        let channelSamples = channelData[0]
        let frameCount = Int(audioBuffer.frameLength)
        guard frameCount > 0 else { return 0.0 }

        var summedSquares: Float = 0
        for sampleIndex in 0..<frameCount {
            let sample = channelSamples[sampleIndex]
            summedSquares += sample * sample
        }

        return sqrt(summedSquares / Float(frameCount))
    }

    /// Calculates a normalized power level between 0.0 and 1.0 from an audio buffer.
    static func calculatePowerLevel(
        from audioBuffer: AVAudioPCMBuffer,
        boostMultiplier: Float = defaultBoostMultiplier
    ) -> Float {
        let rootMeanSquare = calculateRootMeanSquare(from: audioBuffer)
        let boostedLevel = min(max(rootMeanSquare * boostMultiplier, 0.0), 1.0)
        return boostedLevel
    }
}
