//
//  BuddyAudioConversionSupport.swift
//  leanring-buddy
//
//  Shared audio conversion helpers for voice transcription providers.
//

import AVFoundation
import Foundation

final class BuddyPCM16AudioConverter {
    private let targetAudioFormat: AVAudioFormat
    private var audioConverter: AVAudioConverter?
    private var currentInputFormatDescription: String?

    init(targetSampleRate: Double) {
        self.targetAudioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        )!
    }

    func convertToPCM16Data(from audioBuffer: AVAudioPCMBuffer) -> Data? {
        let inputFormatDescription = audioBuffer.format.settings.description

        if currentInputFormatDescription != inputFormatDescription {
            audioConverter = AVAudioConverter(from: audioBuffer.format, to: targetAudioFormat)
            currentInputFormatDescription = inputFormatDescription
        }

        guard let audioConverter else { return nil }

        let sampleRateRatio = targetAudioFormat.sampleRate / audioBuffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(
            (Double(audioBuffer.frameLength) * sampleRateRatio).rounded(.up) + 32
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetAudioFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            return nil
        }

        var hasProvidedSourceBuffer = false
        var conversionError: NSError?

        let conversionStatus = audioConverter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if hasProvidedSourceBuffer {
                outStatus.pointee = .noDataNow
                return nil
            }

            hasProvidedSourceBuffer = true
            outStatus.pointee = .haveData
            return audioBuffer
        }

        guard conversionStatus != .error else { return nil }
        guard let pcmDataPointer = outputBuffer.audioBufferList.pointee.mBuffers.mData else { return nil }

        let bytesPerFrame = Int(targetAudioFormat.streamDescription.pointee.mBytesPerFrame)
        let byteCount = Int(outputBuffer.frameLength) * bytesPerFrame
        guard byteCount > 0 else { return nil }

        return Data(bytes: pcmDataPointer, count: byteCount)
    }
}

final class BuddyFloat32AudioConverter {
    private let targetSampleRate: Double
    private let outputFormat: AVAudioFormat?
    private var cachedConverter: AVAudioConverter?
    private var cachedInputFormat: AVAudioFormat?

    init(targetSampleRate: Double = 16_000.0) {
        self.targetSampleRate = targetSampleRate
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )
    }

    func convertToFloat32Data(from inputBuffer: AVAudioPCMBuffer) -> Data? {
        guard inputBuffer.frameLength > 0, let outputFormat = outputFormat else { return nil }

        if cachedConverter == nil || cachedInputFormat != inputBuffer.format {
            cachedInputFormat = inputBuffer.format
            cachedConverter = AVAudioConverter(from: inputBuffer.format, to: outputFormat)
        }

        guard let converter = cachedConverter else { return nil }

        let sampleRateRatio = targetSampleRate / inputBuffer.format.sampleRate
        let estimatedOutputFrames = AVAudioFrameCount((Double(inputBuffer.frameLength) * sampleRateRatio).rounded(.up)) + 32
        guard estimatedOutputFrames > 0,
              let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: estimatedOutputFrames) else {
            return nil
        }

        var isInputConsumed = false
        var conversionError: NSError?

        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if isInputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            isInputConsumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        let status = converter.convert(to: convertedBuffer, error: &conversionError, withInputFrom: inputBlock)
        guard status != .error, conversionError == nil, convertedBuffer.frameLength > 0 else {
            return nil
        }

        guard let channelData = convertedBuffer.floatChannelData else { return nil }
        let byteCount = Int(convertedBuffer.frameLength) * MemoryLayout<Float>.size
        return Data(bytes: channelData[0], count: byteCount)
    }
}

enum BuddyWAVFileBuilder {
    static func buildWAVData(
        fromPCM16MonoAudio pcm16AudioData: Data,
        sampleRate: Int,
        channelCount: Int = 1,
        bitsPerSample: Int = 16
    ) -> Data {
        let byteRate = sampleRate * channelCount * bitsPerSample / 8
        let blockAlign = channelCount * bitsPerSample / 8
        let dataChunkSize = UInt32(pcm16AudioData.count)
        let fileSize = UInt32(36) + dataChunkSize

        var wavData = Data()

        wavData.append("RIFF".data(using: .ascii)!)
        wavData.append(littleEndianData(from: fileSize))
        wavData.append("WAVE".data(using: .ascii)!)
        wavData.append("fmt ".data(using: .ascii)!)
        wavData.append(littleEndianData(from: UInt32(16)))
        wavData.append(littleEndianData(from: UInt16(1)))
        wavData.append(littleEndianData(from: UInt16(channelCount)))
        wavData.append(littleEndianData(from: UInt32(sampleRate)))
        wavData.append(littleEndianData(from: UInt32(byteRate)))
        wavData.append(littleEndianData(from: UInt16(blockAlign)))
        wavData.append(littleEndianData(from: UInt16(bitsPerSample)))
        wavData.append("data".data(using: .ascii)!)
        wavData.append(littleEndianData(from: dataChunkSize))
        wavData.append(pcm16AudioData)

        return wavData
    }

    private static func littleEndianData<T: FixedWidthInteger>(from value: T) -> Data {
        var littleEndianValue = value.littleEndian
        return Data(bytes: &littleEndianValue, count: MemoryLayout<T>.size)
    }
}
