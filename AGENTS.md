# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it locally via Orukeet (sherpa-onnx / Parakeet TDT v3) or Apple Speech framework, and sends the transcript + a screenshot of the user's screen to a local Ollama vision model (e.g. llama3.2-vision, qwen2.5-vl, or installed MLX vision models). The model responds with text (streamed via NDJSON) and spoken audio (local Qwen3-TTS via MLX Audio or Apple Speech fallback). A blue cursor overlay can fly to and point at UI elements referenced on any connected monitor.

Operates 100% locally with zero cloud dependencies or API keys required.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: Clean Architecture & MVVM with `@StateObject` / `@Published` state management and Coordinator State Machine
- **AI Chat**: Local Ollama vision LLMs (`http://localhost:11434/api/chat`) via NDJSON streaming with dynamic model discovery (conforming to `VisionChatService`)
- **Speech-to-Text**: Orukeet (sherpa-onnx / Parakeet TDT v3 INT8) local on-device transcription default (Apple Speech, AssemblyAI, and OpenAI as optional fallbacks conforming to `BuddyTranscriptionProvider`)
- **Text-to-Speech**: Local Qwen3-TTS via Apple Silicon MLX Audio server (`mlx_audio.server`, 0.6B CustomVoice) with sentence-by-sentence streaming playback and Apple Speech (`AVSpeechSynthesizer`) fallback (conforming to `TextToSpeechProvider`)
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support at native monitor resolution with Apple Vision OCR UI text snapping (conforming to `ScreenCapturing`)
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: Vision LLM embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: PostHog via `ClickyAnalytics.swift`
- **Testing**: Swift Testing framework (`import Testing`) with protocol-based in-memory mocks (`leanring-buddyTests/Mocks/`)

### Modular Directory Structure

The codebase follows a modular Clean Architecture separating concerns into clear layers:

- `leanring-buddy/App/`: Application entry point (`leanring_buddyApp.swift`) and bundle configuration (`AppBundleConfiguration.swift`).
- `leanring-buddy/Core/`:
  - `Models/`: Pure domain data models and utility parsers (`CompanionVoiceState`, `PointingDetection`, `TTSModelCatalog`).
  - `Protocols/`: Core domain protocol abstractions for dependency injection and testing (`PermissionsManaging`, `ScreenCapturing`, `SettingsStoring`, `TextToSpeechProvider`, `VisionChatService`, `BuddyTranscriptionProvider`).
- `leanring-buddy/State/`: Central state machine and lifecycle coordinator (`CompanionCoordinator.swift`).
- `leanring-buddy/Services/`: Concrete domain implementations organized by capability:
  - `Analytics/`: Usage analytics and lead capture (`ClickyAnalytics`, `OnboardingLeadService`).
  - `Audio/`: Microphone capture, audio metering, shortcut monitoring, and onboarding audio playback.
  - `ScreenCapture/`: ScreenCaptureKit multi-monitor capture and Vision OCR snapping (`CompanionScreenCaptureUtility`).
  - `SpeechSynthesis/`: MLX Audio (Qwen3-TTS/Kokoro), Apple TTS, sentence segmenter, and server process manager.
  - `Storage/`: Persistent user settings storage (`UserDefaultsSettingsStorage`).
  - `System/`: System permissions lifecycle (`PermissionsManager`) and window placement (`WindowPositionManager`).
  - `Transcription/`: Orukeet (sherpa-onnx / Parakeet TDT v3), Apple Speech, AssemblyAI streaming, and OpenAI audio backends.
  - `VisionAndAI/`: Ollama, Claude, OpenAI vision clients, and UI element detection.
- `leanring-buddy/UI/`: Decomposed SwiftUI views, components, and AppKit window hosts:
  - `MenuBarPanel/`: Menu bar status item, floating control panel, and decomposed sections (`Header`, `Permissions`, `ModelPicker`, `TTSVoice`, `Footer`).
  - `CursorOverlay/`: Borderless transparent multi-screen overlay windows, blue cursor view, bezier flight animator, shapes, and response overlay bubble.
  - `DesignSystem/`: Atomic design tokens split into `Colors`, `Typography`, `Metrics`, `ButtonStyles`, and `AppKitBridges`.
- `leanring-buddy/Resources/`: Static bundled assets (audio files `ff.mp3`, `enter.mp3`, `eshop.mp3` and images).
- `leanring-buddyTests/`:
  - `Mocks/`: In-memory test doubles implementing core protocols.
  - `UnitTests/`: Swift Testing suites testing state machine, protocols, audio metering, sentence segmenter, pointing parser, permissions, and TTS catalog.
- `docs/architecture/`: Comprehensive UML and sequence documentation:
  - `index.html`: Standalone interactive web viewer (Mermaid.js) with pan/zoom, search, and SVG export.
  - `uml-class-diagram.md`: Complete UML class diagram covering Core Protocols, Models, State, Services, and UI.
  - `sequence-diagrams.md`: Detailed sequence diagrams for all 5 data pipelines (PTT, STT, Vision/TTS, Pointing/OCR, Barge-In).

### State Machine & Coordinator Pattern

The central `CompanionCoordinator` (`leanring-buddy/State/CompanionCoordinator.swift`) models the voice interaction lifecycle as an explicit state machine:
- **States**: `idle` ➔ `listening` ➔ `processing` ➔ `responding` ➔ `idle` (defined in `CompanionVoiceState`).
- **Dependency Injection**: Fully decoupled via core protocol abstractions (`PermissionsManaging`, `ScreenCapturing`, `SettingsStoring`, `TextToSpeechProvider`, `VisionChatService`, `BuddyTranscriptionProvider`). Production defaults are provided, while tests inject in-memory mocks.
- **Barge-In Support**: Starting a new voice session immediately cancels any active processing task, halts TTS playback, and interrupts ongoing cursor flight animations.
- **Backward Compatibility**: `CompanionManager.swift` provides `public typealias CompanionManager = CompanionCoordinator`, allowing existing views to remain unmodified.

### Swift Testing & Test Architecture

The test suite uses modern Apple Swift Testing (`import Testing`):
- All tests are organized with `@Suite` and `@Test` attributes, including parameterized tests (`@Test(arguments: ...)`).
- Complete in-memory mock implementations in `leanring-buddyTests/Mocks/` allow 100% test execution without physical audio hardware, ScreenCaptureKit permissions, or network connectivity.
- Deterministic unit tests cover state transitions, streaming token buffering, German abbreviation preservation, regex coordinate extraction, and TTS model fallbacks.

### API Proxy (Cloudflare Worker)

The app never calls external APIs directly. All requests go through a Cloudflare Worker (`worker/src/index.ts`) that holds the real API keys as secrets.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.anthropic.com/v1/messages` | Claude vision + streaming chat |
| `POST /tts` | `api.elevenlabs.io/v1/text-to-speech/{voiceId}` | ElevenLabs TTS audio |
| `POST /transcribe-token` | `streaming.assemblyai.com/v3/token` | Fetches a short-lived (480s) AssemblyAI websocket token |

Worker secrets: `ANTHROPIC_API_KEY`, `ASSEMBLYAI_API_KEY`, `ELEVENLABS_API_KEY`
Worker vars: `ELEVENLABS_VOICE_ID`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Transient Cursor Mode**: When "Show Clicky" is off (default), pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → processing steps badge → response → TTS → optional pointing), then fades it out automatically after 5 seconds of inactivity once it returns to the cursor.

## Key Files

### App & State
| File | Lines | Purpose |
|------|-------|---------|
| `leanring-buddy/App/leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionCoordinator`. No main window — the app lives entirely in the status bar. |
| `leanring-buddy/App/AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `leanring-buddy/CompanionManager.swift` | ~11 | Backward-compatibility typealias (`public typealias CompanionManager = CompanionCoordinator`). |
| `leanring-buddy/State/CompanionCoordinator.swift` | ~1017 | Central state machine and coordinator. Manages dictation, shortcut monitoring, screen capture, vision chat, speech synthesis, and cursor overlay lifecycle via dependency injection. Tracks voice states (`idle`, `listening`, `processing`, `responding`), supports barge-in cancellation, and drives UI via `@MainActor` `@Published` properties. |

### Core (Domain Models & Protocol Abstractions)
| File | Lines | Purpose |
|------|-------|---------|
| `leanring-buddy/Core/Models/CompanionVoiceState.swift` | ~15 | Enum modeling the voice interaction lifecycle states (`idle`, `listening`, `processing`, `responding`). |
| `leanring-buddy/Core/Models/PointingDetection.swift` | ~159 | Model and parser for vision model `[POINT:...]` tags (`PointingParseResult`, `PointingCoordinateParser`), bounding box calculation, and candidate keywords for Apple Vision OCR UI snapping. |
| `leanring-buddy/Core/Models/TTSModelCatalog.swift` | ~148 | Unified catalog of Text-to-Speech models (Qwen3-TTS 0.6B, 1.7B, Kokoro-82M, Apple Speech), preset voices, supported languages, and fallback resolution. |
| `leanring-buddy/Core/Protocols/BuddyTranscriptionProvider.swift` | ~110 | Protocol surface and provider factory for voice transcription backends (Orukeet, Apple Speech, AssemblyAI, OpenAI). |
| `leanring-buddy/Core/Protocols/PermissionsManaging.swift` | ~21 | Protocol abstraction for checking, polling, and granting macOS system permissions. |
| `leanring-buddy/Core/Protocols/ScreenCapturing.swift` | ~12 | Protocol abstraction for multi-monitor screenshot capture and OCR text snapping. |
| `leanring-buddy/Core/Protocols/SettingsStoring.swift` | ~17 | Protocol abstraction for persistent user settings (`UserDefaults` wrapper). |
| `leanring-buddy/Core/Protocols/TextToSpeechProvider.swift` | ~119 | Protocol surface and provider factory for speech synthesis backends with sentence queueing and playback lifecycle. |
| `leanring-buddy/Core/Protocols/VisionChatService.swift` | ~18 | Protocol abstraction for Vision LLM chat completion with streaming responses. |

### Services
| File | Lines | Purpose |
|------|-------|---------|
| `leanring-buddy/Services/Audio/BuddyDictationManager.swift` | ~845 | Push-to-talk voice pipeline. Handles microphone capture via `AudioEngineCaptureService`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio metering via `AudioPowerMeter`. |
| `leanring-buddy/Services/Audio/AudioEngineCaptureService.swift` | ~51 | Low-level microphone capture service wrapping `AVAudioEngine` and input node tap lifecycle. |
| `leanring-buddy/Services/Audio/AudioPowerMeter.swift` | ~40 | Calculates Root Mean Square (RMS) and normalized power levels from `AVAudioPCMBuffer` for waveform visualizers. |
| `leanring-buddy/Services/Audio/BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio or Float32 16kHz for Orukeet, and builds WAV payloads. |
| `leanring-buddy/Services/Audio/GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `leanring-buddy/Services/Audio/OnboardingAudioPlayer.swift` | ~94 | Manages playback, looping, and timed fade-out of onboarding music (`ff.mp3`). |
| `leanring-buddy/Services/ScreenCapture/CompanionScreenCaptureUtility.swift` | ~419 | Multi-monitor screenshot capture at native monitor resolution using ScreenCaptureKit and high-precision Apple Vision OCR UI text snapping, conforming target for ScreenCapturing. |
| `leanring-buddy/Services/SpeechSynthesis/MLXAudioQwenTTSClient.swift` | ~465 | Local on-device TTS client using Qwen3-TTS / Kokoro via `mlx_audio.server` with sentence-by-sentence streaming playback and Apple TTS fallback. Conforms to `TextToSpeechProvider`. |
| `leanring-buddy/Services/SpeechSynthesis/MLXAudioServerManager.swift` | ~294 | Manages local `mlx_audio.server` lifecycle (spawns child process on demand and terminates on app exit). |
| `leanring-buddy/Services/SpeechSynthesis/AppleTTSClient.swift` | ~202 | Native macOS Text-to-Speech client conforming to `TextToSpeechProvider`. Used as fallback when the local MLX server is unavailable. |
| `leanring-buddy/Services/SpeechSynthesis/ElevenLabsTTSClient.swift` | ~81 | Legacy ElevenLabs TTS client. Sends text to the Worker proxy, plays back audio via `AVAudioPlayer`. |
| `leanring-buddy/Services/SpeechSynthesis/SpeechSentenceSegmenter.swift` | ~268 | Incremental sentence segmenter splitting streamed LLM tokens into complete sentences while preserving German abbreviations and stripping control tags like `[POINT:...]`. |
| `leanring-buddy/Services/Storage/UserDefaultsSettingsStorage.swift` | ~40 | Thread-safe `UserDefaults` backed implementation of `SettingsStoring`. |
| `leanring-buddy/Services/System/PermissionsManager.swift` | ~101 | System permissions lifecycle manager conforming to `PermissionsManaging`. Handles checking, timer polling, and persistence for Accessibility, Screen Recording, Microphone, and Screen Content. |
| `leanring-buddy/Services/System/WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `leanring-buddy/Services/Transcription/OrukeetTranscriptionProvider.swift` | ~229 | Local on-device transcription provider backed by Orukeet (Parakeet TDT v3 via sherpa-onnx) with WebSocket streaming (active default). Conforms to `BuddyTranscriptionProvider`. |
| `leanring-buddy/Services/Transcription/OrukeetServerManager.swift` | ~138 | Manages local sherpa-onnx Orukeet WebSocket server lifecycle (discovery, health check, spawn, terminate). |
| `leanring-buddy/Services/Transcription/AppleSpeechTranscriptionProvider.swift` | ~150 | Local on-device transcription provider backed by Apple's Speech framework. Conforms to `BuddyTranscriptionProvider`. |
| `leanring-buddy/Services/Transcription/AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Streaming transcription provider. Fetches temp tokens from Cloudflare Worker, opens AssemblyAI v3 websocket, streams PCM16 audio. Conforms to `BuddyTranscriptionProvider`. |
| `leanring-buddy/Services/Transcription/OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release. Conforms to `BuddyTranscriptionProvider`. |
| `leanring-buddy/Services/VisionAndAI/OllamaAPI.swift` | ~210 | Local Ollama vision chat API client with NDJSON streaming and `/api/tags` vision model capability discovery, conforming target for VisionChatService. |
| `leanring-buddy/Services/VisionAndAI/ClaudeAPI.swift` | ~291 | Legacy Claude vision API client with streaming (SSE) and non-streaming modes. |
| `leanring-buddy/Services/VisionAndAI/OpenAIAPI.swift` | ~142 | OpenAI vision chat client with streaming and non-streaming responses. |
| `leanring-buddy/Services/VisionAndAI/ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `leanring-buddy/Services/Analytics/ClickyAnalytics.swift` | ~121 | PostHog analytics integration for usage tracking. |
| `leanring-buddy/Services/Analytics/OnboardingLeadService.swift` | ~54 | Service handling onboarding email capture, PostHog user identification, and FormSpark REST submission. |

### UI (MenuBarPanel, CursorOverlay, DesignSystem)
| File | Lines | Purpose |
|------|-------|---------|
| `leanring-buddy/UI/MenuBarPanel/MenuBarPanelManager.swift` | ~243 | `NSStatusItem` + custom `NSPanel` lifecycle. Creates menu bar icon, manages floating companion panel (show/hide/position), installs outside-click dismiss monitor. |
| `leanring-buddy/UI/MenuBarPanel/CompanionPanelView.swift` | ~64 | Decomposed top-level SwiftUI panel view aggregating header, permissions, model pickers, TTS controls, and footer. |
| `leanring-buddy/UI/MenuBarPanel/Components/PanelHeaderView.swift` | ~87 | Status indicator badge, status text, title, and close button. |
| `leanring-buddy/UI/MenuBarPanel/Components/PanelPermissionsCard.swift` | ~393 | Onboarding overview, email lead capture, and interactive macOS permissions checklist with live status polling. |
| `leanring-buddy/UI/MenuBarPanel/Components/PanelModelPickerSection.swift` | ~90 | Vision LLM (Ollama model) picker dropdown with refresh capabilities. |
| `leanring-buddy/UI/MenuBarPanel/Components/PanelTTSVoiceSection.swift` | ~295 | TTS configuration section: engine selector (Qwen3, Kokoro, Apple), speed multiplier, audition preview, language, and voice picker. |
| `leanring-buddy/UI/MenuBarPanel/Components/PanelFooterSection.swift` | ~94 | Cursor visibility toggle, active STT provider badge, and quit application button. |
| `leanring-buddy/UI/CursorOverlay/OverlayWindow.swift` | ~49 | Borderless full-screen transparent `NSWindow` subclass hosting the blue cursor overlay across all active displays. |
| `leanring-buddy/UI/CursorOverlay/OverlayWindowManager.swift` | ~77 | `@MainActor` window manager managing overlay window creation, display repositioning, and animated fade-in/out transitions. |
| `leanring-buddy/UI/CursorOverlay/BlueCursorView.swift` | ~706 | Main companion cursor view with glowing triangle, live audio waveform, thinking spinner, target highlight box, and speech bubble. |
| `leanring-buddy/UI/CursorOverlay/CursorFlightAnimator.swift` | ~217 | Screen-to-window coordinate math, bezier trajectory interpolation, velocity profiling, and tangent rotation calculation for cursor flight animations. |
| `leanring-buddy/UI/CursorOverlay/CursorShapes.swift` | ~59 | SwiftUI custom geometric shapes (`Triangle`), preference keys, and navigation mode enums. |
| `leanring-buddy/UI/CursorOverlay/CompanionResponseOverlay.swift` | ~217 | SwiftUI response bubble displaying streamed assistant text, Markdown styling, and animated audio waveform next to cursor. |
| `leanring-buddy/UI/DesignSystem/DesignSystem.swift` | ~21 | Root `DS` namespace entry point and design system documentation. |
| `leanring-buddy/UI/DesignSystem/Colors.swift` | ~218 | Color tokens (`DS.Colors`), Tailwind blue palette, semantic themes, and hex conversion helpers. |
| `leanring-buddy/UI/DesignSystem/Typography.swift` | ~56 | Typography tokens (`DS.Typography`) for titles, body, buttons, captions, and code blocks. |
| `leanring-buddy/UI/DesignSystem/Metrics.swift` | ~74 | Layout metrics (`DS.Spacing`, `DS.CornerRadius`, `DS.Animation`, `DS.StateLayer`, `DS.Shadows`). |
| `leanring-buddy/UI/DesignSystem/ButtonStyles.swift` | ~509 | 7 standardized button styles (primary, secondary, tertiary, text, outlined, destructive, icon) and pointer-cursor modifiers. |
| `leanring-buddy/UI/DesignSystem/AppKitBridges.swift` | ~113 | AppKit bridge views (`PointerCursorView`, `IBeamCursorView`, `NativeTooltipView`) and SwiftUI view modifiers. |

### Tests & Mocks (`leanring-buddyTests/`)
| File | Lines | Purpose |
|------|-------|---------|
| `leanring-buddyTests/Mocks/MockPermissionsManager.swift` | ~58 | In-memory mock conforming to `PermissionsManaging` with controllable permission states and method call counters. |
| `leanring-buddyTests/Mocks/MockScreenCaptureUtility.swift` | ~54 | In-memory mock conforming to `ScreenCapturing` returning synthetic image buffers and mock OCR bounding boxes. |
| `leanring-buddyTests/Mocks/MockSettingsStorage.swift` | ~49 | In-memory mock conforming to `SettingsStoring` backed by a dictionary for deterministic test assertions. |
| `leanring-buddyTests/Mocks/MockTextToSpeechProvider.swift` | ~90 | In-memory mock conforming to `TextToSpeechProvider` tracking spoken sentence queues, playback state, and synthesis events. |
| `leanring-buddyTests/Mocks/MockTranscriptionProvider.swift` | ~82 | In-memory mock conforming to `BuddyTranscriptionProvider` simulating audio streaming and customizable transcript yields. |
| `leanring-buddyTests/Mocks/MockVisionChatService.swift` | ~55 | In-memory mock conforming to `VisionChatService` emitting scripted streaming tokens and point tags. |
| `leanring-buddyTests/UnitTests/CoordinatorStateMachineTests.swift` | ~183 | Swift Testing suite verifying `CompanionCoordinator` state transitions (`idle` ➔ `listening` ➔ `processing` ➔ `responding`), barge-in cancellation, and dependency wiring. |
| `leanring-buddyTests/UnitTests/CoreProtocolsTests.swift` | ~137 | Swift Testing suite verifying protocol conformances, factory instantiations, and in-memory mock behaviors. |
| `leanring-buddyTests/UnitTests/PointingParserTests.swift` | ~187 | Swift Testing suite testing `PointingCoordinateParser` regex parsing, monitor indices, bounding boxes, OCR candidate keywords, and malformed tag handling. |
| `leanring-buddyTests/UnitTests/SpeechSentenceSegmenterTests.swift` | ~182 | Swift Testing suite validating chunk buffering, sentence boundary detection, German abbreviation preservation, tag stripping, and flushing. |
| `leanring-buddyTests/UnitTests/TTSCatalogAndSelectionTests.swift` | ~201 | Swift Testing suite validating model catalog completeness, fallback defaults, language/voice mappings, and storage persistence. |
| `leanring-buddyTests/UnitTests/AudioMeteringTests.swift` | ~71 | Swift Testing suite testing `AudioPowerMeter` RMS calculation, decibel normalization, and silence thresholds. |
| `leanring-buddyTests/UnitTests/PermissionManagerTests.swift` | ~99 | Swift Testing suite testing permission polling, cache invalidation, and permission state flags. |
| `leanring-buddyTests/leanring_buddyTests.swift` | ~46 | Root test target sanity test verifying bundle linkage and test environment initialization. |

### API Proxy & Worker
| File | Lines | Purpose |
|------|-------|---------|
| `worker/src/index.ts` | ~141 | Cloudflare Worker proxy holding API secrets. Routes: `POST /chat` (Claude), `POST /tts` (ElevenLabs), `POST /transcribe-token` (AssemblyAI). |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Cloudflare Worker

```bash
cd worker
npm install

# Add secrets
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY

# Deploy
npx wrangler deploy

# Local dev (create worker/.dev.vars with your keys)
npx wrangler dev
```

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
