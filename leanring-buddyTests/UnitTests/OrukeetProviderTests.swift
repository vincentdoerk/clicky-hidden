//
//  OrukeetProviderTests.swift
//  leanring-buddyTests
//
//  Unit tests for Orukeet Speech-to-Text integration and audio conversion.
//

import AVFoundation
import Testing
@testable import leanring_buddy

@Suite("Orukeet Integration Tests")
struct OrukeetIntegrationTests {
    @Test("Converts PCM buffer to 16kHz Float32 Data")
    func testFloat32AudioConverter() throws {
        let converter = BuddyFloat32AudioConverter(targetSampleRate: 16_000.0)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000.0, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800 // 0.1s of audio

        let data = converter.convertToFloat32Data(from: buffer)
        #expect(data != nil)
        // 0.1s at 16kHz = 1600 samples * 4 bytes per Float32 = 6400 bytes
        #expect(data?.count == 6400)
    }

    @Test("Handles empty PCM buffer gracefully")
    func testEmptyBufferReturnsNil() throws {
        let converter = BuddyFloat32AudioConverter(targetSampleRate: 16_000.0)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000.0, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 0

        let data = converter.convertToFloat32Data(from: buffer)
        #expect(data == nil)
    }

    @Test("Converts 16kHz input without resampling")
    func testSameSampleRateConversion() throws {
        let converter = BuddyFloat32AudioConverter(targetSampleRate: 16_000.0)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000.0, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600

        let data = converter.convertToFloat32Data(from: buffer)
        #expect(data != nil)
        #expect(data?.count == 1600 * 4)
    }

    @Test("OrukeetServerManager discovers candidate paths")
    func testServerManagerPaths() {
        let manager = OrukeetServerManager.shared
        #expect(manager.port == 6006)

        if let binaryPath = OrukeetServerManager.binaryPath {
            #expect(FileManager.default.isExecutableFile(atPath: binaryPath))
        }

        if let modelDir = OrukeetServerManager.modelDirectoryURL {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: modelDir.path, isDirectory: &isDir)
            #expect(exists && isDir.boolValue)
        }
    }

    @Test("Orukeet JSON response decodes text correctly")
    func testOrukeetJSONDecoding() {
        let jsonString = """
        {"lang": "de", "text": "Hallo Antigravity", "timestamps": []}
        """
        let data = jsonString.data(using: .utf8)!
        let decoded = try? JSONDecoder().decode(OrukeetResponsePayload.self, from: data)
        #expect(decoded?.text == "Hallo Antigravity")
    }

    @Test("Orukeet framing constructs 8-byte header")
    func testOrukeetHeaderFraming() {
        let header = OrukeetTranscriptionSession.buildHeader(sampleRate: 16000, byteLength: 6400)
        #expect(header.count == 8)
        let sampleRate = header.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
        let byteLength = header.suffix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(sampleRate == 16000)
        #expect(byteLength == 6400)
    }
}

