//
//  AudioMeteringTests.swift
//  leanring-buddyTests
//
//  Unit tests for AudioPowerMeter calculation from PCM buffers.
//

import AVFoundation
import Testing
@testable import leanring_buddy

struct AudioMeteringTests {
    @Test func powerMeterReturnsZeroForEmptyOrSilentBuffer() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024

        let powerLevel = AudioPowerMeter.calculatePowerLevel(from: buffer)
        #expect(powerLevel >= 0.0 && powerLevel <= 1.0)
    }

    @Test func powerMeterReturnsZeroForZeroFrameLength() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 0

        let powerLevel = AudioPowerMeter.calculatePowerLevel(from: buffer)
        #expect(powerLevel == 0.0)
    }

    @Test func powerMeterCalculatesExpectedLevelForSynthesizedAudio() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024

        guard let channelData = buffer.floatChannelData else {
            Issue.record("Expected floatChannelData to be non-nil")
            return
        }

        // Fill with constant value 0.05
        for index in 0..<1024 {
            channelData[0][index] = 0.05
        }

        let rms = AudioPowerMeter.calculateRootMeanSquare(from: buffer)
        #expect(abs(rms - 0.05) < 0.001)

        let powerLevel = AudioPowerMeter.calculatePowerLevel(from: buffer)
        // 0.05 * 10.2 = 0.51
        #expect(abs(powerLevel - 0.51) < 0.01)
    }

    @Test func powerMeterClampsLevelToOneForLoudAudio() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024

        guard let channelData = buffer.floatChannelData else {
            Issue.record("Expected floatChannelData to be non-nil")
            return
        }

        for index in 0..<1024 {
            channelData[0][index] = 1.0
        }

        let powerLevel = AudioPowerMeter.calculatePowerLevel(from: buffer)
        #expect(powerLevel == 1.0)
    }
}
