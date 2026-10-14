# Design Specification: Orukeet Speech-to-Text Integration

## 1. Context & Objectives

Clicky is a 100% local macOS menu bar companion app. Previously, local Speech-to-Text (STT) transcription relied on `whisper.cpp` (`whisper-cli` executing `large-v3-turbo`).
This specification replaces the local Whisper STT implementation with **Orukeet** (Parakeet TDT v3 based multilingual ASR from Hugging Face: `oruk/orukeet`).

### Key Goals:
- Replace `WhisperCPPTranscriptionProvider` with `OrukeetTranscriptionProvider`.
- Utilize local INT8 ONNX Orukeet models stored in `~/.cache/openwhispr/parakeet-models/orukeet-v0.1.0/` or Clicky's application support directory.
- Connect via a local WebSocket to `sherpa-onnx-ws-darwin-arm64` on port `6006`.
- **Hybrid process management**:
  - If a server on `ws://127.0.0.1:6006` is already active (e.g. via OpenWhispr), connect directly without spawning an unnecessary second process.
  - If no server is running on port 6006, automatically spawn `sherpa-onnx-ws-darwin-arm64` in the background and terminate it on app shutdown.
- Maintain seamless fallback to Apple Speech if Orukeet binaries or models are missing.

---

## 2. Architecture & Components

```
+-------------------------------------------------------------+
|                      BuddyDictationManager                  |
|          (Captures mic audio as AVAudioPCMBuffer)           |
+------------------------------+------------------------------+
                               |
                               v
+-------------------------------------------------------------+
|               OrukeetTranscriptionProvider                  |
|    - Conforms to BuddyTranscriptionProvider                 |
|    - Creates OrukeetTranscriptionSession on PTT start       |
+------------------------------+------------------------------+
                               |
                               v
+-------------------------------------------------------------+
|               OrukeetTranscriptionSession                   |
|    - Buffers audio buffers into 16kHz Float32 PCM           |
|    - On PTT release: opens URLSessionWebSocketTask          |
|    - Sends little-endian header:                            |
|        [sample_rate: UInt32, byte_length: UInt32]           |
|    - Streams raw Float32 audio bytes in 10,240-byte chunks  |
|    - Receives JSON payload: {"text": "..."}                 |
|    - Delivers finalized transcript via callback             |
+------------------------------+------------------------------+
                               |
                  WebSocket (ws://127.0.0.1:6006)
                               |
                               v
+-------------------------------------------------------------+
|                    OrukeetServerManager                     |
|    - Health checks ws://127.0.0.1:6006                      |
|    - Spawns sherpa-onnx-ws-darwin-arm64 if needed           |
|    - Manages child process lifecycle                        |
+-------------------------------------------------------------+
```

### 2.1. `OrukeetServerManager`
- **Location**: `leanring-buddy/Services/Transcription/OrukeetServerManager.swift`
- **Responsibilities**:
  - Probe `http://127.0.0.1:6006` or test WebSocket connectivity with a 1-second timeout.
  - Locate executable:
    - `/Applications/OpenWhispr.app/Contents/Resources/bin/sherpa-onnx-ws-darwin-arm64`
    - `/opt/homebrew/bin/sherpa-onnx-ws`
    - or bundled location.
  - Locate model files:
    - `~/.cache/openwhispr/parakeet-models/orukeet-v0.1.0/`
    - Check presence of `encoder.int8.onnx`, `decoder.int8.onnx`, `joiner.int8.onnx`, `tokens.txt`.
  - Spawning arguments:
    ```sh
    sherpa-onnx-ws-darwin-arm64 \
      --tokens=<path>/tokens.txt \
      --encoder=<path>/encoder.int8.onnx \
      --decoder=<path>/decoder.int8.onnx \
      --joiner=<path>/joiner.int8.onnx \
      --model-type=nemo_transducer \
      --port=6006 \
      --num-threads=4 \
      --num-work-threads=3
    ```
  - Tracks whether the process was spawned by Clicky (`ownsProcess: Bool`).
  - Terminates spawned process on `terminateServer()` or `NSApplication.willTerminateNotification`.

### 2.2. `OrukeetTranscriptionProvider` & `OrukeetTranscriptionSession`
- **Location**: `leanring-buddy/Services/Transcription/OrukeetTranscriptionProvider.swift`
- **Responsibilities**:
  - Implements `BuddyTranscriptionProvider`.
  - `displayName = "Orukeet (Local)"`.
  - `isConfigured`: returns `true` if server is reachable OR (executable and models exist).
  - Starts streaming session returning `BuddyStreamingTranscriptionSession`.
- **Session details**:
  - `appendAudioBuffer(_:)`: converts `AVAudioPCMBuffer` to 16 kHz Mono Float32 using `BuddyPCM16AudioConverter` (extended or converted to Float32).
  - `requestFinalTranscript()`:
    1. Ensures server is alive via `OrukeetServerManager.shared.ensureServerRunning()`.
    2. Builds header: `sampleRate: UInt32 = 16000`, `byteLength: UInt32 = UInt32(audioData.count)`.
    3. Connects via `URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:6006")!)`.
    4. Transmits header + audio payload in chunks of up to 10,240 bytes.
    5. Awaits message response (`{"lang": "...", "text": "...", ...}`).
    6. Sends `"Done"` signal and cancels/closes socket.
    7. Cleans up text and dispatches `onFinalTranscriptReady(cleanedText)`.

### 2.3. Audio Conversion Support
- `BuddyPCM16AudioConverter` / `BuddyFloat32AudioConverter`:
  - Convert input audio buffers (e.g. 48kHz / 44.1kHz float) to 16,000 Hz Mono Float32 byte buffer (`[Float]` or `Data`).

### 2.4. Configuration, Factory & UI Updates
- **`BuddyTranscriptionProvider.swift`**:
  - Replace `PreferredProvider.whisperCPP = "whisper"` with `PreferredProvider.orukeet = "orukeet"`.
  - In `resolveProvider()`: default to `OrukeetTranscriptionProvider()`, with fallback to `AppleSpeechTranscriptionProvider()`.
- **`Info.plist`**:
  - Set `VoiceTranscriptionProvider` to `orukeet`.
- **`leanring-buddy/UI/MenuBarPanel/Components/PanelFooterSection.swift`**:
  - Badge text displays active provider name dynamically (which will be `Orukeet (Local)`).
- **Removal**:
  - Remove `WhisperCPPTranscriptionProvider.swift`.
  - Remove all Whisper references in test mocks and docs.

---

## 3. Error Handling & Edge Cases

1. **Server unreachable and binary missing**:
   - `OrukeetTranscriptionProvider.isConfigured` returns `false`.
   - `BuddyTranscriptionProviderFactory` logs a warning and falls back to `AppleSpeechTranscriptionProvider`.
2. **WebSocket connection timeout / dropped packet**:
   - `OrukeetTranscriptionSession` times out after 8 seconds and falls back to calling `onError(error)`.
3. **Empty audio recorded**:
   - Instantly returns empty string `""` without querying the server.
4. **Port 6006 already in use by OpenWhispr**:
   - Server manager detects existing active server and reuses it without error or port conflict.

---

## 4. Testing Strategy

- **`leanring-buddyTests/UnitTests/OrukeetProviderTests.swift`**:
  - Verify initialization, `displayName`, and configuration state.
  - Test binary header serialization (`sampleRate`, `byteLength`).
  - Test JSON response parsing for valid transcripts, empty transcripts, and malformed outputs.
- **Factory Resolution Tests**:
  - Update `CoreProtocolsTests.swift` to verify `orukeet` is resolved as default.
