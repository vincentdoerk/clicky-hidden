# Configurable TTS Models & VLM UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow users to choose between local TTS models (Qwen3-TTS 0.6B, Qwen3-TTS 1.7B, Kokoro-82M, Apple Speech), adjust spoken language, voice, and speed, and rename the menu bar panel labels from Model -> VLM and Voice -> TTS.

**Architecture:** Model options are encapsulated in a unified configuration type `TTSModelCatalog`. `CompanionManager` coordinates the selected VLM, TTS model, language, voice, and speed with reactive updates to `TextToSpeechProvider` and UI menus in `CompanionPanelView`.

**Tech Stack:** Swift, SwiftUI, AppKit, MLX Audio (`mlx_audio.server`), AVFoundation (`AVSpeechSynthesizer`).

## Global Constraints
- Do not run `xcodebuild` from the terminal (invalidates TCC permissions).
- Retain dark design system tokens (`DS.Colors`, `DS.CornerRadius`).
- All interactive buttons must have `.pointerCursor()`.
- State updates on `@MainActor`.
- Keep German docstrings / comments where appropriate.

---

### Task 1: Create TTS Model Catalog and Data Models

**Files:**
- Create: `leanring-buddy/TTSModelCatalog.swift`
- Modify: `leanring-buddy.xcodeproj/project.pbxproj` (if needed, or place inside target structure)

**Interfaces:**
- Produces:
  ```swift
  struct TTSLanguageOption: Identifiable, Hashable {
      let id: String
      let displayName: String
      let code: String
  }

  struct TTSModelOption: Identifiable, Hashable {
      let id: String
      let displayName: String
      let shortName: String
      let modelRepo: String?
      let isLocalMLX: Bool
      let supportedLanguages: [TTSLanguageOption]
      let defaultLanguageCode: String
      let availableVoices: [String]
      let defaultVoice: String
  }

  enum TTSModelCatalog {
      static let allModels: [TTSModelOption]
      static func model(withId id: String) -> TTSModelOption?
      static let defaultModelId: String
  }
  ```

- [ ] **Step 1: Write `TTSModelCatalog.swift` with models for Qwen3-0.6B, Qwen3-1.7B, Kokoro-82M, and Apple Speech**
- [ ] **Step 2: Add unit / catalog verification to ensure voices and languages match defaults**
- [ ] **Step 3: Commit catalog changes**

---

### Task 2: Extend `TextToSpeechProvider` Protocol and `MLXAudioQwenTTSClient`

**Files:**
- Modify: `leanring-buddy/TextToSpeechProvider.swift`
- Modify: `leanring-buddy/MLXAudioQwenTTSClient.swift`
- Modify: `leanring-buddy/AppleTTSClient.swift`

**Interfaces:**
- Updates `TextToSpeechProvider`:
  ```swift
  func setModelName(_ modelName: String)
  func setLanguageCode(_ languageCode: String)
  ```
- Consumes `TTSModelCatalog` for dynamic switching.

- [ ] **Step 1: Update `TextToSpeechProvider` protocol with default protocol extension implementations**
- [ ] **Step 2: Update `MLXAudioQwenTTSClient` to update `modelName` and `languageCode` dynamically when requested**
- [ ] **Step 3: Support delegation to `AppleTTSClient` when Apple Speech model is explicitly selected**
- [ ] **Step 4: Commit TTS provider changes**

---

### Task 3: Update `CompanionManager` State Machine

**Files:**
- Modify: `leanring-buddy/CompanionManager.swift`

**Interfaces:**
- Produces:
  ```swift
  @Published var selectedTTSModelId: String
  @Published var selectedTTSLanguageCode: String
  var availableTTSModels: [TTSModelOption]
  var currentTTSModel: TTSModelOption
  var availableLanguagesForCurrentModel: [TTSLanguageOption]
  var availableVoicesForCurrentModel: [String]
  func setSelectedTTSModel(_ modelId: String)
  func setSelectedTTSLanguage(_ languageCode: String)
  ```

- [ ] **Step 1: Add published properties for `selectedTTSModelId` and `selectedTTSLanguageCode` with `UserDefaults` persistence**
- [ ] **Step 2: Implement dynamic voice reset / fallbacks when switching between models (e.g. Qwen -> Kokoro -> Apple)**
- [ ] **Step 3: Update preview speech phrase to use the appropriate language and model**
- [ ] **Step 4: Commit `CompanionManager` changes**

---

### Task 4: Update `CompanionPanelView` UI (Rename to VLM & TTS, add Model & Language Pickers)

**Files:**
- Modify: `leanring-buddy/CompanionPanelView.swift`

**Interfaces:**
- Consumes `CompanionManager` state:
  - `modelPickerRow` changed from label "Model" to "VLM"
  - `voicePickerRow` converted into a complete `ttsConfigurationSection`:
    - Row 1: Label "TTS", Audio preview play/stop button, Speed picker, TTS Model dropdown
    - Row 2: Language dropdown, Voice dropdown

- [ ] **Step 1: Rename `Model` label to `VLM` in `modelPickerRow`**
- [ ] **Step 2: Redesign `voicePickerRow` into `ttsSection` with TTS Model picker, Language picker, Voice picker, and Speed multiplier**
- [ ] **Step 3: Add formatting helpers for model, language, and voice display names**
- [ ] **Step 4: Commit UI changes**

---

### Task 5: Update Documentation (`AGENTS.md`) & Final Verification

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Update `AGENTS.md` to reflect new TTS model options, VLM naming, and line counts**
- [ ] **Step 2: Review all modified files for code conventions and correctness**
- [ ] **Step 3: Commit documentation update**
