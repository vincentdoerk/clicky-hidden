# Ollama & Apple Native Local Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate Clicky from external cloud APIs (Claude, ElevenLabs, AssemblyAI) and the Cloudflare Worker proxy to 100% local macOS execution using Ollama for vision chat, Apple Speech framework for speech-to-text, and Apple AVSpeechSynthesizer for text-to-speech.

**Architecture:** A native Swift client `OllamaAPI` communicates with `http://localhost:11434` for NDJSON streaming chat and dynamic vision model discovery. A native `AppleTTSClient` leverages `AVSpeechSynthesizer` for zero-latency speech output. The app's existing `AppleSpeechTranscriptionProvider` is activated via `Info.plist`. `CompanionManager` coordinates the local pipeline and feeds dynamic vision model choices into `CompanionPanelView`.

**Tech Stack:** Swift, SwiftUI, AppKit, AVFoundation (`AVSpeechSynthesizer`), Speech (`SFSpeechRecognizer`), ScreenCaptureKit, Ollama HTTP API (`/api/chat`, `/api/tags`).

## Global Constraints

- Never run `xcodebuild` from the terminal (invalidates macOS TCC permissions).
- Follow AGENTS.md naming conventions strictly: optimize for clarity over concision, no single-character variable names, keep argument names identical.
- All UI state updates must be on `@MainActor`.
- Maintain existing comments and docstrings.
- Preserve Xcode project structure (using `PBXFileSystemSynchronizedRootGroup` for `leanring-buddy`).

---

### Task 1: Create `OllamaAPI.swift`

**Files:**
- Create: `leanring-buddy/OllamaAPI.swift`

**Interfaces:**
- Produces:
  ```swift
  class OllamaAPI {
      var selectedModelName: String
      init(baseURLString: String = "http://localhost:11434", selectedModelName: String = "llama3.2-vision")
      func fetchAvailableVisionModels() async throws -> [String]
      func analyzeImageStreaming(
          images: [(data: Data, label: String)],
          systemPrompt: String,
          conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
          userPrompt: String,
          onTextChunk: @MainActor @Sendable (String) -> Void
      ) async throws -> (text: String, duration: TimeInterval)
  }
  ```

- [ ] **Step 1: Write `OllamaAPI.swift`**
  - Implement `fetchAvailableVisionModels()` querying `GET /api/tags`, parsing `models` array, filtering entries where `capabilities` contains `"vision"` or model name contains `"vision"` or `"vl"`.
  - Implement `analyzeImageStreaming(...)` querying `POST /api/chat`, converting images to base64, building NDJSON stream reader using `URLSession.shared.bytes(for:)`, parsing `message.content`, calling `onTextChunk`, and returning accumulated text + duration.
- [ ] **Step 2: Commit `OllamaAPI.swift`**
  ```bash
  git add leanring-buddy/OllamaAPI.swift
  git commit -m "feat: add OllamaAPI client with NDJSON streaming and vision model discovery"
  ```

---

### Task 2: Create `AppleTTSClient.swift`

**Files:**
- Create: `leanring-buddy/AppleTTSClient.swift`

**Interfaces:**
- Produces:
  ```swift
  @MainActor
  final class AppleTTSClient: NSObject, AVSpeechSynthesizerDelegate {
      var isPlaying: Bool { get }
      func speakText(_ textToSpeak: String) async throws
      func stopPlayback()
  }
  ```

- [ ] **Step 1: Write `AppleTTSClient.swift`**
  - Use `AVSpeechSynthesizer` and implement `AVSpeechSynthesizerDelegate`.
  - Track `isPlaying` state via delegate methods (`speechSynthesizer:didStart:`, `speechSynthesizer:didFinish:`, `speechSynthesizer:didCancel:`).
  - Select high-quality system voice matching the current locale or fallback to `en-US`.
  - Implement `speakText(_ textToSpeak: String)` returning once speech has started.
  - Implement `stopPlayback()` calling `synthesizer.stopSpeaking(at: .immediate)`.
- [ ] **Step 2: Commit `AppleTTSClient.swift`**
  ```bash
  git add leanring-buddy/AppleTTSClient.swift
  git commit -m "feat: add AppleTTSClient using AVSpeechSynthesizer"
  ```

---

### Task 3: Switch Speech-to-Text Provider in `Info.plist`

**Files:**
- Modify: `leanring-buddy/Info.plist:11-13`

- [ ] **Step 1: Update `VoiceTranscriptionProvider` key**
  - Set `VoiceTranscriptionProvider` from `assemblyai` to `apple`.
- [ ] **Step 2: Commit `Info.plist`**
  ```bash
  git add leanring-buddy/Info.plist
  git commit -m "config: set VoiceTranscriptionProvider to apple in Info.plist"
  ```

---

### Task 4: Integrate `OllamaAPI` & `AppleTTSClient` into `CompanionManager` & update `CompanionPanelView`

**Files:**
- Modify: `leanring-buddy/CompanionManager.swift`
- Modify: `leanring-buddy/CompanionPanelView.swift`

**Interfaces:**
- Consumes:
  - `OllamaAPI` from Task 1
  - `AppleTTSClient` from Task 2
- Produces:
  - `companionManager.availableVisionModels: [String]`
  - `companionManager.refreshAvailableVisionModels()`
  - `companionManager.setSelectedModel(_ model: String)`

- [ ] **Step 1: Update `CompanionManager.swift`**
  - Replace `claudeAPI` with `ollamaAPI: OllamaAPI`.
  - Replace `elevenLabsTTSClient` with `appleTTSClient: AppleTTSClient`.
  - Remove `workerBaseURL`.
  - Add `@Published var availableVisionModels: [String] = []`.
  - Add `func refreshAvailableVisionModels() async`.
  - Update `sendTranscriptToClaudeWithScreenshot(transcript:)` to call `ollamaAPI.analyzeImageStreaming(...)` and `appleTTSClient.speakText(...)`.
  - Update `scheduleTransientHideIfNeeded()` to check `appleTTSClient.isPlaying`.
  - Update error fallback message if Ollama is not running.
- [ ] **Step 2: Update `CompanionPanelView.swift`**
  - Replace fixed Sonnet/Opus buttons with a dynamic Vision Model Picker menu.
  - Show the currently selected model.
  - Add a refresh button next to the picker to re-scan Ollama models.
- [ ] **Step 3: Commit integration**
  ```bash
  git add leanring-buddy/CompanionManager.swift leanring-buddy/CompanionPanelView.swift
  git commit -m "feat: wire OllamaAPI and AppleTTSClient into CompanionManager and CompanionPanelView"
  ```

---

### Task 5: Update Documentation (`AGENTS.md`)

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Update Architecture, Key Files table, and provider descriptions in `AGENTS.md`**
  - Document `OllamaAPI.swift` and `AppleTTSClient.swift`.
  - Note removal of Cloudflare Worker dependency for local operation.
- [ ] **Step 2: Commit `AGENTS.md`**
  ```bash
  git add AGENTS.md
  git commit -m "docs: update AGENTS.md for local Ollama and Apple TTS architecture"
  ```
