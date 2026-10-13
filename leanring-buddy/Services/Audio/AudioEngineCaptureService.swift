//
//  AudioEngineCaptureService.swift
//  leanring-buddy
//
//  Low-level audio recording service that manages AVAudioEngine and input tap.
//

import AVFoundation
import Foundation

final class AudioEngineCaptureService {
    private let audioEngine: AVAudioEngine
    private let audioInputBus: AVAudioNodeBus = 0
    private let defaultBufferSize: AVAudioFrameCount = 1024

    var isRunning: Bool {
        audioEngine.isRunning
    }

    init(audioEngine: AVAudioEngine = AVAudioEngine()) {
        self.audioEngine = audioEngine
    }

    func startCapturing(bufferHandler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: audioInputBus)

        inputNode.removeTap(onBus: audioInputBus)
        inputNode.installTap(
            onBus: audioInputBus,
            bufferSize: defaultBufferSize,
            format: inputFormat
        ) { buffer, _ in
            bufferHandler(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    func stopCapturing() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: audioInputBus)
    }

    deinit {
        stopCapturing()
    }
}
