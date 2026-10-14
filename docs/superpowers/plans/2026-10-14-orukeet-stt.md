# Orukeet Speech-to-Text Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Whisper C++ with Orukeet (sherpa-onnx / Parakeet TDT v3) as Clicky's primary on-device Speech-to-Text provider.

**Architecture:** Connects to local sherpa-onnx WebSocket server on port 6006 (reusing OpenWhispr if running, or spawning our own instance if inactive). Mic input is buffered into 16kHz Float32 mono audio and transmitted via `URLSessionWebSocketTask` upon push-to-talk release.

**Tech Stack:** Swift, AVFoundation, URLSessionWebSocketTask, sherpa-onnx INT8 ONNX models (`oruk/orukeet`).

## Global Constraints

- Platform: macOS 14.2+ (Apple Silicon arm64).
- No external cloud dependencies or API keys.
- Preserve backward-compatibility and fallback to Apple Speech if Orukeet is unavailable.
- Maintain documentation integrity: update AGENTS.md.

---

### Task 1: Implement Float32 16kHz Audio Converter

**Files:**
- Modify: `leanring-buddy/Services/Audio/BuddyAudioConversionSupport.swift`
- Test: `leanring-buddyTests/UnitTests/OrukeetProviderTests.swift`

**Interfaces:**
- Produces:
  ```swift
  final class BuddyFloat32AudioConverter {
      init(targetSampleRate: Double = 16_000.0)
      func convertToFloat32Data(from buffer: AVAudioPCMBuffer) -> Data?
  }
  ```

- [ ] **Step 1: Write test for Float32 converter**
Create `leanring-buddyTests/UnitTests/OrukeetProviderTests.swift` with test validating `BuddyFloat32AudioConverter` converting an audio buffer into 16kHz Float32 little-endian PCM bytes:
```swift
import AVFoundation
import Testing
@testable import Clicky

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
}
```

- [ ] **Step 2: Implement `BuddyFloat32AudioConverter` in `BuddyAudioConversionSupport.swift`**
Add class:
```swift
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
        let estimatedOutputFrames = AVAudioFrameCount((Double(inputBuffer.frameLength) * sampleRateRatio).rounded(.up))
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
```

- [ ] **Step 3: Build and verify**
Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project leanring-buddy.xcodeproj -scheme leanring-buddy -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**
```bash
git add leanring-buddy/Services/Audio/BuddyAudioConversionSupport.swift leanring-buddyTests/UnitTests/OrukeetProviderTests.swift
git commit -m "feat(audio): add BuddyFloat32AudioConverter for 16kHz mono audio"
```

---

### Task 2: Implement `OrukeetServerManager`

**Files:**
- Create: `leanring-buddy/Services/Transcription/OrukeetServerManager.swift`
- Test: `leanring-buddyTests/UnitTests/OrukeetProviderTests.swift`

**Interfaces:**
- Produces:
  ```swift
  final class OrukeetServerManager {
      static let shared: OrukeetServerManager
      static let defaultPort: Int = 6006
      var isServerAvailable: Bool { get }
      func checkServerHealth() async -> Bool
      func ensureServerRunning() async -> Bool
      func terminateServer()
  }
  ```

- [ ] **Step 1: Write test for server manager health and discovery**
Add test to `leanring-buddyTests/UnitTests/OrukeetProviderTests.swift`:
```swift
    @Test("OrukeetServerManager discovers candidate paths")
    func testServerManagerPaths() {
        let manager = OrukeetServerManager.shared
        // Manager should locate either the model files or active server
        #expect(manager.port == 6006)
    }
```

- [ ] **Step 2: Implement `OrukeetServerManager`**
Create `leanring-buddy/Services/Transcription/OrukeetServerManager.swift`:
```swift
//
//  OrukeetServerManager.swift
//  leanring-buddy
//
//  Manages the lifecycle of the local sherpa-onnx Orukeet WebSocket server.
//

import Foundation
import AppKit

final class OrukeetServerManager {
    static let shared = OrukeetServerManager()
    let port: Int = 6006

    private var executionProcess: Process?
    private var ownsProcess = false
    private let stateQueue = DispatchQueue(label: "com.learningbuddy.orukeet.server")

    /// Resolved executable path for sherpa-onnx-ws.
    static var binaryPath: String? {
        let candidates = [
            "/Applications/OpenWhispr.app/Contents/Resources/bin/sherpa-onnx-ws-darwin-arm64",
            "/opt/homebrew/bin/sherpa-onnx-ws",
            "/usr/local/bin/sherpa-onnx-ws"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Directory containing Orukeet ONNX models.
    static var modelDirectoryURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".cache/openwhispr/parakeet-models/orukeet-v0.1.0"),
            home.appendingPathComponent("Library/Application Support/Clicky/models/orukeet")
        ]
        return candidates.first { dir in
            let requiredFiles = ["tokens.txt", "encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx"]
            return requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
        }
    }

    var isConfigured: Bool {
        return Self.binaryPath != nil && Self.modelDirectoryURL != nil
    }

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    deinit {
        terminateServer()
    }

    @objc private func applicationWillTerminate() {
        terminateServer()
    }

    /// Checks if a WebSocket server is already listening on port 6006.
    func checkServerHealth() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.8
        request.httpMethod = "GET"

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                // 426 Upgrade Required is returned by WebSocket servers when queried via HTTP
                return httpResponse.statusCode == 426 || (200...299).contains(httpResponse.statusCode)
            }
            return false
        } catch {
            return false
        }
    }

    /// Ensures the server is active, starting it if not already running.
    @discardableResult
    func ensureServerRunning() async -> Bool {
        if await checkServerHealth() {
            return true
        }

        guard let binary = Self.binaryPath, let modelDir = Self.modelDirectoryURL else {
            return false
        }

        return stateQueue.sync {
            if executionProcess != nil {
                return true
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = [
                "--tokens=\(modelDir.appendingPathComponent("tokens.txt").path)",
                "--encoder=\(modelDir.appendingPathComponent("encoder.int8.onnx").path)",
                "--decoder=\(modelDir.appendingPathComponent("decoder.int8.onnx").path)",
                "--joiner=\(modelDir.appendingPathComponent("joiner.int8.onnx").path)",
                "--model-type=nemo_transducer",
                "--port=\(port)",
                "--num-threads=4",
                "--num-work-threads=3"
            ]

            process.standardOutput = Pipe()
            process.standardError = Pipe()

            do {
                try process.run()
                self.executionProcess = process
                self.ownsProcess = true
                print("🎙️ Orukeet: Spawning server on port \(port)...")
                Thread.sleep(forTimeInterval: 0.5)
                return true
            } catch {
                print("❌ Orukeet: Failed to spawn server: \(error)")
                return false
            }
        }
    }

    func terminateServer() {
        stateQueue.sync {
            if ownsProcess, let proc = executionProcess, proc.isRunning {
                print("🛑 Orukeet: Terminating spawned server...")
                proc.terminate()
            }
            executionProcess = nil
            ownsProcess = false
        }
    }
}
```

- [ ] **Step 3: Build and verify**
Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project leanring-buddy.xcodeproj -scheme leanring-buddy -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**
```bash
git add leanring-buddy/Services/Transcription/OrukeetServerManager.swift leanring-buddyTests/UnitTests/OrukeetProviderTests.swift
git commit -m "feat(transcription): add OrukeetServerManager lifecycle controller"
```

---

### Task 3: Implement `OrukeetTranscriptionProvider` & Session

**Files:**
- Create: `leanring-buddy/Services/Transcription/OrukeetTranscriptionProvider.swift`
- Test: `leanring-buddyTests/UnitTests/OrukeetProviderTests.swift`

**Interfaces:**
- Produces:
  ```swift
  final class OrukeetTranscriptionProvider: BuddyTranscriptionProvider {
      let displayName: String = "Orukeet (Local)"
      let requiresSpeechRecognitionPermission: Bool = false
      var isConfigured: Bool { get }
      var unavailableExplanation: String? { get }
      func startStreamingSession(...) async throws -> any BuddyStreamingTranscriptionSession
  }
  ```

- [ ] **Step 1: Write test for Orukeet JSON decoding & payload framing**
Add test in `leanring-buddyTests/UnitTests/OrukeetProviderTests.swift`:
```swift
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
```

- [ ] **Step 2: Implement `OrukeetTranscriptionProvider.swift`**
Create `leanring-buddy/Services/Transcription/OrukeetTranscriptionProvider.swift`:
```swift
//
//  OrukeetTranscriptionProvider.swift
//  leanring-buddy
//
//  Local on-device transcription provider powered by Orukeet (Parakeet TDT v3).
//

import AVFoundation
import Foundation

struct OrukeetResponsePayload: Decodable {
    let lang: String?
    let text: String
}

struct OrukeetTranscriptionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class OrukeetTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Orukeet (Local)"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool {
        return OrukeetServerManager.shared.isConfigured
    }

    var unavailableExplanation: String? {
        if !isConfigured {
            return "Orukeet model files or sherpa-onnx binary not found."
        }
        return nil
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        let serverReady = await OrukeetServerManager.shared.ensureServerRunning()
        guard serverReady else {
            throw OrukeetTranscriptionError(message: "Failed to connect to or start Orukeet server on port \(OrukeetServerManager.shared.port).")
        }

        return OrukeetTranscriptionSession(
            port: OrukeetServerManager.shared.port,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

final class OrukeetTranscriptionSession: BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 8.0
    private static let targetSampleRate: Double = 16_000.0

    private let port: Int
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let audioFloat32Converter = BuddyFloat32AudioConverter(targetSampleRate: targetSampleRate)
    private let syncQueue = DispatchQueue(label: "com.learningbuddy.orukeet.session")

    private var bufferedFloat32Data = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var activeWebSocketTask: URLSessionWebSocketTask?

    init(
        port: Int,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.port = port
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        syncQueue.sync {
            guard !hasRequestedFinalTranscript && !isCancelled else { return }
            guard let floatData = audioFloat32Converter.convertToFloat32Data(from: audioBuffer) else { return }
            bufferedFloat32Data.append(floatData)
        }
    }

    func requestFinalTranscript() {
        syncQueue.sync {
            guard !hasRequestedFinalTranscript && !isCancelled else { return }
            hasRequestedFinalTranscript = true

            guard !bufferedFloat32Data.isEmpty else {
                deliverFinalTranscriptIfNeeded("")
                return
            }

            let audioSnapshot = bufferedFloat32Data
            Task {
                await sendAudioForTranscription(audioSnapshot)
            }
        }
    }

    func cancel() {
        syncQueue.sync {
            isCancelled = true
            activeWebSocketTask?.cancel(with: .normalClosure, reason: nil)
            activeWebSocketTask = nil
        }
    }

    static func buildHeader(sampleRate: UInt32, byteLength: UInt32) -> Data {
        var header = Data()
        var sr = sampleRate.littleEndian
        var bl = byteLength.littleEndian
        header.append(Data(bytes: &sr, count: 4))
        header.append(Data(bytes: &bl, count: 4))
        return header
    }

    private func sendAudioForTranscription(_ audioData: Data) async {
        guard let url = URL(string: "ws://127.0.0.1:\(port)") else {
            onError(OrukeetTranscriptionError(message: "Invalid WebSocket URL"))
            return
        }

        let session = URLSession(configuration: .default)
        let wsTask = session.webSocketTask(with: url)
        self.activeWebSocketTask = wsTask
        wsTask.resume()

        let header = Self.buildHeader(sampleRate: UInt32(Self.targetSampleRate), byteLength: UInt32(audioData.count))
        let payload = header + audioData

        // Stream payload in chunks of up to 10240 bytes
        let chunkSize = 10240
        var offset = 0
        while offset < payload.count {
            guard !isCancelled else { return }
            let currentChunkSize = min(chunkSize, payload.count - offset)
            let chunk = payload.subdata(in: offset..<(offset + currentChunkSize))
            do {
                try await wsTask.send(.data(chunk))
            } catch {
                guard !isCancelled else { return }
                onError(error)
                return
            }
            offset += currentChunkSize
        }

        guard !isCancelled else { return }

        // Await decoded result
        do {
            let message = try await wsTask.receive()
            var rawText = ""
            switch message {
            case .string(let text):
                rawText = text
            case .data(let data):
                rawText = String(data: data, encoding: .utf8) ?? ""
            @unknown default:
                break
            }

            let transcript: String
            if let data = rawText.data(using: .utf8),
               let payload = try? JSONDecoder().decode(OrukeetResponsePayload.self, from: data) {
                transcript = payload.text
            } else {
                transcript = rawText
            }

            let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            print("🎙️ Orukeet transcript: \"\(cleaned)\"")

            // Send done & close
            _ = try? await wsTask.send(.string("Done"))
            wsTask.cancel(with: .normalClosure, reason: nil)

            deliverFinalTranscriptIfNeeded(cleaned)
        } catch {
            guard !isCancelled else { return }
            onError(error)
        }
    }

    private func deliverFinalTranscriptIfNeeded(_ text: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(text)
    }
}
```

- [ ] **Step 3: Build and verify**
Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project leanring-buddy.xcodeproj -scheme leanring-buddy -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**
```bash
git add leanring-buddy/Services/Transcription/OrukeetTranscriptionProvider.swift leanring-buddyTests/UnitTests/OrukeetProviderTests.swift
git commit -m "feat(transcription): add OrukeetTranscriptionProvider with WebSocket streaming"
```

---

### Task 4: Replace Whisper in Factory, Configuration, and Remove Whisper File

**Files:**
- Modify: `leanring-buddy/Core/Protocols/BuddyTranscriptionProvider.swift`
- Modify: `leanring-buddy/Info.plist`
- Delete: `leanring-buddy/Services/Transcription/WhisperCPPTranscriptionProvider.swift`
- Modify: `AGENTS.md`

- [ ] **Step 1: Update `BuddyTranscriptionProvider.swift`**
Replace `whisperCPP` with `orukeet`:
```swift
    private enum PreferredProvider: String {
        case orukeet = "orukeet"
        case assemblyAI = "assemblyai"
        case openAI = "openai"
        case appleSpeech = "apple"
    }
```
Update `resolveProvider()`:
```swift
        let orukeetProvider = OrukeetTranscriptionProvider()
        let assemblyAIProvider = AssemblyAIStreamingTranscriptionProvider()
        let openAIProvider = OpenAIAudioTranscriptionProvider()

        if preferredProvider == .orukeet || preferredProvider == nil {
            if orukeetProvider.isConfigured {
                return orukeetProvider
            }
            print("⚠️ Transcription: Orukeet preferred but not configured, falling back to Apple Speech")
            return AppleSpeechTranscriptionProvider()
        }
```

- [ ] **Step 2: Update `Info.plist`**
Set `VoiceTranscriptionProvider` string value to `orukeet`.

- [ ] **Step 3: Remove `WhisperCPPTranscriptionProvider.swift` and update project**
Remove `leanring-buddy/Services/Transcription/WhisperCPPTranscriptionProvider.swift`.
Also remove references in `project.pbxproj`.

- [ ] **Step 4: Update `AGENTS.md`**
Update Speech-to-Text architecture description in `AGENTS.md`:
Replace Whisper with Orukeet (Parakeet TDT v3 via sherpa-onnx INT8).

- [ ] **Step 5: Build and verify**
Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project leanring-buddy.xcodeproj -scheme leanring-buddy -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**
```bash
git add leanring-buddy/Core/Protocols/BuddyTranscriptionProvider.swift leanring-buddy/Info.plist AGENTS.md leanring-buddy.xcodeproj/project.pbxproj
git rm leanring-buddy/Services/Transcription/WhisperCPPTranscriptionProvider.swift
git commit -m "refactor(transcription): replace Whisper with Orukeet as default local provider"
```

---

### Task 5: Live Verification & Quality Gate

**Files:**
- Test: Live end-to-end test script

- [ ] **Step 1: Run live transcription test with running Orukeet server**
Run a test recording or synthetic 16kHz audio buffer against `ws://127.0.0.1:6006` through `OrukeetTranscriptionProvider` to verify text extraction.

- [ ] **Step 2: Verify full Xcode project build**
Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project leanring-buddy.xcodeproj -scheme leanring-buddy -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit any final test adjustments**
```bash
git commit --allow-empty -m "chore: verify Orukeet STT end-to-end integration"
```
