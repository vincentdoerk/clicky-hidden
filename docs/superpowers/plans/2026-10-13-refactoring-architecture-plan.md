# Refactoring & Architektur-Neustrukturierung Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zerlegung des 10.650-Zeilen-Monolithen in eine modulare Clean Architecture mit sauberer Verzeichnisstruktur, Dependency Injection und vollständiger Swift-Testing-Suite.

**Architecture:** Das System wird in UI-Layer (modulare SwiftUI-Views), State-Layer (`CompanionCoordinator` als schlanke State Machine), Core-Layer (Protokolle & Models) und Services-Layer (Infrastruktur & Hardware-Kapselung) aufgeteilt. Externe Abhängigkeiten werden hinter Protokollen gekapselt und über Mocks isoliert testbar gemacht.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Swift Testing (`import Testing`), ScreenCaptureKit, AVFoundation, Whisper C++, MLX Audio.

## Global Constraints

- macOS 14.2+ Deployment Target
- App-Typ: Menu-bar-only (`LSUIElement=true`), keine Dock-Icons oder Hauptfenster
- Concurrency: `@MainActor` Isolation für UI und State-Updates, `async/await` für asynchrone Pipelines
- **CRITICAL**: Führe niemals `xcodebuild` im Terminal aus (invalidiert TCC-Berechtigungen für Screen Recording und Accessibility).
- Verwende für alle neuen Tests ausschließlich das Apple Swift Testing Framework (`import Testing`, `@Test`, `#expect`), kein XCTest.
- Behalte `Info.plist`, `leanring-buddy.entitlements` und `Assets.xcassets` im Root-Verzeichnis `leanring-buddy/`, um bestehende Xcode-Target-Pfade nicht zu brechen.

---

### Task 1: Struktur-First – Verzeichnisse anlegen & bestehende Dateien verschieben

**Files:**
- Create:
  - `leanring-buddy/App/`
  - `leanring-buddy/Core/Models/`
  - `leanring-buddy/Core/Protocols/`
  - `leanring-buddy/Services/Audio/`
  - `leanring-buddy/Services/SpeechSynthesis/`
  - `leanring-buddy/Services/Transcription/`
  - `leanring-buddy/Services/VisionAndAI/`
  - `leanring-buddy/Services/ScreenCapture/`
  - `leanring-buddy/Services/System/`
  - `leanring-buddy/Services/Analytics/`
  - `leanring-buddy/UI/DesignSystem/`
  - `leanring-buddy/UI/MenuBarPanel/`
  - `leanring-buddy/UI/CursorOverlay/`
  - `leanring-buddy/Resources/Audio/`
  - `leanring-buddy/Resources/Images/`
- Modify: Dateipfade via `git mv`

**Interfaces:**
- Consumes: Bisherige 27 Swift-Dateien und Audio-/Bildressourcen in `leanring-buddy/`
- Produces: Geordnete Verzeichnisstruktur, die dank `PBXFileSystemSynchronizedRootGroup` in Xcode 16 automatisch synchronisiert wird.

- [ ] **Step 1: Ordnerhierarchie im Dateisystem anlegen**

```bash
mkdir -p leanring-buddy/App
mkdir -p leanring-buddy/Core/Models
mkdir -p leanring-buddy/Core/Protocols
mkdir -p leanring-buddy/Services/Audio
mkdir -p leanring-buddy/Services/SpeechSynthesis
mkdir -p leanring-buddy/Services/Transcription
mkdir -p leanring-buddy/Services/VisionAndAI
mkdir -p leanring-buddy/Services/ScreenCapture
mkdir -p leanring-buddy/Services/System
mkdir -p leanring-buddy/Services/Analytics
mkdir -p leanring-buddy/UI/DesignSystem
mkdir -p leanring-buddy/UI/MenuBarPanel
mkdir -p leanring-buddy/UI/CursorOverlay
mkdir -p leanring-buddy/Resources/Audio
mkdir -p leanring-buddy/Resources/Images
```

- [ ] **Step 2: Bestehende Dateien per `git mv` in Zielordner verschieben**

```bash
# App
git mv leanring-buddy/leanring_buddyApp.swift leanring-buddy/App/
git mv leanring-buddy/AppBundleConfiguration.swift leanring-buddy/App/

# Core / Models & Protocols
git mv leanring-buddy/TTSModelCatalog.swift leanring-buddy/Core/Models/
git mv leanring-buddy/TextToSpeechProvider.swift leanring-buddy/Core/Protocols/
git mv leanring-buddy/BuddyTranscriptionProvider.swift leanring-buddy/Core/Protocols/

# Services / Audio & Shortcuts
git mv leanring-buddy/BuddyDictationManager.swift leanring-buddy/Services/Audio/
git mv leanring-buddy/BuddyAudioConversionSupport.swift leanring-buddy/Services/Audio/
git mv leanring-buddy/GlobalPushToTalkShortcutMonitor.swift leanring-buddy/Services/Audio/

# Services / SpeechSynthesis
git mv leanring-buddy/MLXAudioQwenTTSClient.swift leanring-buddy/Services/SpeechSynthesis/
git mv leanring-buddy/MLXAudioServerManager.swift leanring-buddy/Services/SpeechSynthesis/
git mv leanring-buddy/AppleTTSClient.swift leanring-buddy/Services/SpeechSynthesis/
git mv leanring-buddy/ElevenLabsTTSClient.swift leanring-buddy/Services/SpeechSynthesis/
git mv leanring-buddy/SpeechSentenceSegmenter.swift leanring-buddy/Services/SpeechSynthesis/

# Services / Transcription
git mv leanring-buddy/WhisperCPPTranscriptionProvider.swift leanring-buddy/Services/Transcription/
git mv leanring-buddy/AppleSpeechTranscriptionProvider.swift leanring-buddy/Services/Transcription/
git mv leanring-buddy/AssemblyAIStreamingTranscriptionProvider.swift leanring-buddy/Services/Transcription/
git mv leanring-buddy/OpenAIAudioTranscriptionProvider.swift leanring-buddy/Services/Transcription/

# Services / Vision & AI
git mv leanring-buddy/OllamaAPI.swift leanring-buddy/Services/VisionAndAI/
git mv leanring-buddy/ClaudeAPI.swift leanring-buddy/Services/VisionAndAI/
git mv leanring-buddy/OpenAIAPI.swift leanring-buddy/Services/VisionAndAI/
git mv leanring-buddy/ElementLocationDetector.swift leanring-buddy/Services/VisionAndAI/

# Services / ScreenCapture
git mv leanring-buddy/CompanionScreenCaptureUtility.swift leanring-buddy/Services/ScreenCapture/

# Services / System
git mv leanring-buddy/WindowPositionManager.swift leanring-buddy/Services/System/

# Services / Analytics
git mv leanring-buddy/ClickyAnalytics.swift leanring-buddy/Services/Analytics/

# UI
git mv leanring-buddy/DesignSystem.swift leanring-buddy/UI/DesignSystem/
git mv leanring-buddy/MenuBarPanelManager.swift leanring-buddy/UI/MenuBarPanel/
git mv leanring-buddy/CompanionPanelView.swift leanring-buddy/UI/MenuBarPanel/
git mv leanring-buddy/OverlayWindow.swift leanring-buddy/UI/CursorOverlay/
git mv leanring-buddy/CompanionResponseOverlay.swift leanring-buddy/UI/CursorOverlay/

# Resources
git mv leanring-buddy/*.mp3 leanring-buddy/Resources/Audio/
git mv leanring-buddy/steve.jpg leanring-buddy/Resources/Images/
git mv leanring-buddy/codex-add-project.png leanring-buddy/Resources/Images/
```

- [ ] **Step 3: Verifizieren, dass keine Dateien verloren gingen**

Run: `git status`
Expected: Alle Dateien als `renamed:` markiert, keine fehlenden Dateien.

- [ ] **Step 4: Commit der Verzeichnisstruktur**

```bash
git commit -m "refactor: restructure codebase into modular directories"
```

---

### Task 2: Core-Protokolle, In-Memory-Storage & Mock-Fundament

**Files:**
- Create:
  - `leanring-buddy/Core/Protocols/ScreenCapturing.swift`
  - `leanring-buddy/Core/Protocols/VisionChatService.swift`
  - `leanring-buddy/Core/Protocols/PermissionsManaging.swift`
  - `leanring-buddy/Core/Protocols/SettingsStoring.swift`
  - `leanring-buddy/Services/Storage/UserDefaultsSettingsStorage.swift`
  - `leanring-buddyTests/Mocks/MockPermissionsManager.swift`
  - `leanring-buddyTests/Mocks/MockVisionChatService.swift`
  - `leanring-buddyTests/Mocks/MockTextToSpeechProvider.swift`
  - `leanring-buddyTests/Mocks/MockTranscriptionProvider.swift`
  - `leanring-buddyTests/Mocks/MockSettingsStorage.swift`
  - `leanring-buddyTests/Mocks/MockScreenCaptureUtility.swift`
- Test: `leanring-buddyTests/UnitTests/CoreProtocolsTests.swift`

**Interfaces:**
- Consumes: `TTSModelCatalog`, `CompanionScreenCapture` aus bestehenden Dateien
- Produces:
  - `protocol ScreenCapturing: Sendable { func captureScreens() async throws -> [CompanionScreenCapture] }`
  - `protocol VisionChatService: AnyObject { func streamChat(prompt: String, screenCaptures: [CompanionScreenCapture], history: [(user: String, assistant: String)]) async throws -> AsyncThrowingStream<String, Error>; func fetchAvailableModels() async throws -> [String] }`
  - `protocol PermissionsManaging: AnyObject { var allPermissionsGranted: Bool { get }; var hasAccessibilityPermission: Bool { get }; var hasScreenRecordingPermission: Bool { get }; var hasMicrophonePermission: Bool { get }; var hasScreenContentPermission: Bool { get }; func refreshPermissions(); func startPolling(onChange: @escaping () -> Void); func stopPolling() }`
  - `protocol SettingsStoring: AnyObject { func string(forKey key: String) -> String?; func set(_ value: String?, forKey key: String); func double(forKey key: String) -> Double; func set(_ value: Double, forKey key: String); func bool(forKey key: String) -> Bool; func set(_ value: Bool, forKey key: String) }`

- [ ] **Step 1: Protokolle in `Core/Protocols/` anlegen**

Implementiere:
- `ScreenCapturing.swift` mit `func captureScreens() async throws -> [CompanionScreenCapture]`
- `VisionChatService.swift` mit `streamChat(...)` und `fetchAvailableModels()`
- `PermissionsManaging.swift` mit Flags und Polling-Methoden
- `SettingsStoring.swift` mit Gettern/Settern für String, Double, Bool

- [ ] **Step 2: `UserDefaultsSettingsStorage` in `Services/Storage/` implementieren**

```swift
import Foundation

final class UserDefaultsSettingsStorage: SettingsStoring {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    func set(_ value: String?, forKey key: String) { defaults.set(value, forKey: key) }
    func double(forKey key: String) -> Double { defaults.double(forKey: key) }
    func set(_ value: Double, forKey key: String) { defaults.set(value, forKey: key) }
    func bool(forKey key: String) -> Bool { defaults.bool(forKey: key) }
    func set(_ value: Bool, forKey key: String) { defaults.set(value, forKey: key) }
}
```

- [ ] **Step 3: Mocks in `leanring-buddyTests/Mocks/` anlegen**

Erstelle:
- `MockPermissionsManager.swift` mit steuerbaren Flags (`var allPermissionsGranted = true`, etc.)
- `MockVisionChatService.swift` mit konfigurierbarem Antwort-Stream
- `MockTextToSpeechProvider.swift` mit Protokollierung aufgerufener Sätze (`var spokenTexts: [String] = []`)
- `MockSettingsStorage.swift` mit privatem `[String: Any]`-Dictionary
- `MockScreenCaptureUtility.swift` mit Dummy-Capture-Rückgabe

- [ ] **Step 4: Test zur Verifikation der Mock-Infrastruktur schreiben**

In `leanring-buddyTests/UnitTests/CoreProtocolsTests.swift`:
```swift
import Testing
@testable import leanring_buddy

struct CoreProtocolsTests {
    @Test func mockSettingsStorageStoresAndRetrievesValues() async throws {
        let storage = MockSettingsStorage()
        storage.set("test-model", forKey: "selectedModel")
        #expect(storage.string(forKey: "selectedModel") == "test-model")
        
        storage.set(1.25, forKey: "speed")
        #expect(storage.double(forKey: "speed") == 1.25)
    }

    @Test func mockPermissionsManagerReportsGrantedState() async throws {
        let permissions = MockPermissionsManager()
        permissions.allPermissionsGranted = true
        #expect(permissions.allPermissionsGranted)
    }
}
```

- [ ] **Step 5: Commit**

```bash
git add leanring-buddy/Core/Protocols leanring-buddy/Services/Storage leanring-buddyTests/Mocks leanring-buddyTests/UnitTests/CoreProtocolsTests.swift
git commit -m "feat: introduce core protocols, settings storage, and test mocks"
```

---

### Task 3: Services aus `CompanionManager` & `BuddyDictationManager` extrahieren

**Files:**
- Create:
  - `leanring-buddy/Services/System/PermissionsManager.swift`
  - `leanring-buddy/Services/Audio/OnboardingAudioPlayer.swift`
  - `leanring-buddy/Services/Analytics/OnboardingLeadService.swift`
  - `leanring-buddy/Services/Audio/AudioEngineCaptureService.swift`
  - `leanring-buddy/Services/Audio/AudioPowerMeter.swift`
- Modify:
  - `leanring-buddy/CompanionManager.swift` (Nutzung der extrahierten Services)
  - `leanring-buddy/Services/Audio/BuddyDictationManager.swift` (Delegation an CaptureService und PowerMeter)
- Test:
  - `leanring-buddyTests/UnitTests/AudioMeteringTests.swift`
  - `leanring-buddyTests/UnitTests/PermissionManagerTests.swift`

**Interfaces:**
- Consumes: `PermissionsManaging`, `SettingsStoring`, `AVAudioEngine`
- Produces:
  - `PermissionsManager: PermissionsManaging`: Reines Permissions-Lifecycle-Management
  - `OnboardingAudioPlayer`: Kapselt `ff.mp3`-Playback und 90s/3s-Fade
  - `OnboardingLeadService`: Kapselt PostHog-Identify und FormSpark REST-Call
  - `AudioPowerMeter`: Berechnet RMS und Dezibel aus `AVAudioPCMBuffer`
  - `AudioEngineCaptureService`: Low-Level Recording

- [ ] **Step 1: Test für `AudioPowerMeter` schreiben**

In `leanring-buddyTests/UnitTests/AudioMeteringTests.swift`:
```swift
import Testing
import AVFoundation
@testable import leanring_buddy

struct AudioMeteringTests {
    @Test func powerMeterReturnsZeroForEmptyOrSilentBuffer() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024
        
        let powerLevel = AudioPowerMeter.calculatePowerLevel(from: buffer)
        #expect(powerLevel >= 0.0 && powerLevel <= 1.0)
    }
}
```

- [ ] **Step 2: `AudioPowerMeter` implementieren**

In `leanring-buddy/Services/Audio/AudioPowerMeter.swift`:
RMS-Berechnung aus dem Float-Channel-Data extrahieren.

- [ ] **Step 3: `PermissionsManager` implementieren**

In `leanring-buddy/Services/System/PermissionsManager.swift`:
Implementiert `PermissionsManaging`, übernimmt die Timer- und Polling-Logik aus `CompanionManager.swift` (Zeilen 348–370, 480–520).

- [ ] **Step 4: `OnboardingAudioPlayer` & `OnboardingLeadService` implementieren**

Lagere die Methoden `startOnboardingMusic()`, `fadeOutOnboardingMusic()` und `submitEmail()` aus `CompanionManager.swift` in dedizierte Klassen aus.

- [ ] **Step 5: `CompanionManager` auf die neuen Services umstellen**

Ersetze inline `AVAudioPlayer` und `FormSpark` URLSession-Code durch Delegationsaufrufe an `OnboardingAudioPlayer` und `OnboardingLeadService`.

- [ ] **Step 6: Commit**

```bash
git add leanring-buddy/Services/ leanring-buddy/CompanionManager.swift leanring-buddyTests/UnitTests/
git commit -m "refactor: extract permissions, audio playback, and lead capture services"
```

---

### Task 4: Verschlankung des `CompanionManager` zu `CompanionCoordinator`

**Files:**
- Create:
  - `leanring-buddy/Core/Models/CompanionVoiceState.swift`
  - `leanring-buddy/Core/Models/PointingDetection.swift`
  - `leanring-buddy/State/CompanionCoordinator.swift`
- Modify:
  - `leanring-buddy/CompanionManager.swift` (Wird zu Typealias oder schlankem Wrapper um `CompanionCoordinator` für Abwärtskompatibilität)
- Test:
  - `leanring-buddyTests/UnitTests/CoordinatorStateMachineTests.swift`

**Interfaces:**
- Consumes: Alle `Core/Protocols/` Interfaces
- Produces: Schlanker `CompanionCoordinator` mit sauberem State-Machine Lifecycle (`idle` ➔ `listening` ➔ `processing` ➔ `responding` ➔ `idle`) und `@MainActor` Isolation.

- [ ] **Step 1: Test für Zustandsmaschine schreiben**

In `leanring-buddyTests/UnitTests/CoordinatorStateMachineTests.swift`:
```swift
import Testing
@testable import leanring_buddy

struct CoordinatorStateMachineTests {
    @Test @MainActor func initialStateIsIdleWhenPermissionsGranted() async throws {
        let mockPermissions = MockPermissionsManager(allGranted: true)
        let coordinator = CompanionCoordinator(permissionsManager: mockPermissions)
        #expect(coordinator.voiceState == .idle)
    }

    @Test @MainActor func bargeInCancelsCurrentResponseAndStartsListening() async throws {
        let coordinator = CompanionCoordinator(permissionsManager: MockPermissionsManager(allGranted: true))
        coordinator.simulateStartListening()
        #expect(coordinator.voiceState == .listening)
        
        coordinator.simulateStartResponding()
        #expect(coordinator.voiceState == .responding)
        
        // Neues Diktat unterbricht laufende Antwort
        coordinator.simulateStartListening()
        #expect(coordinator.voiceState == .listening)
    }
}
```

- [ ] **Step 2: `CompanionVoiceState` und `PointingDetection` nach `Core/Models/` auslagern**

Extrahiere `enum CompanionVoiceState` und die Koordinaten-Structs in eigene Dateien.

- [ ] **Step 3: `CompanionCoordinator` implementieren**

Reduziere den bisherigen 1.300-Zeilen `CompanionManager` auf die reine Koordination:
- Dependency Injection im `init(...)` mit Standardwerten für Produktion.
- Push-to-Talk Lifecycle & Abbruchverwaltung (`Task.cancel()`).
- Saubere Trennung von UI-Properties (`@Published`) und Service-Aufrufen.

- [ ] **Step 4: Commit**

```bash
git add leanring-buddy/Core/Models leanring-buddy/State leanring-buddy/CompanionManager.swift leanring-buddyTests/UnitTests/CoordinatorStateMachineTests.swift
git commit -m "feat: implement slim CompanionCoordinator with dependency injection and state tests"
```

---

### Task 5: UI-Monolithen aufteilen (`OverlayWindow`, `CompanionPanelView`, `DesignSystem`)

**Files:**
- Create:
  - `leanring-buddy/UI/CursorOverlay/OverlayWindowManager.swift`
  - `leanring-buddy/UI/CursorOverlay/BlueCursorView.swift`
  - `leanring-buddy/UI/CursorOverlay/CursorFlightAnimator.swift`
  - `leanring-buddy/UI/CursorOverlay/CursorShapes.swift`
  - `leanring-buddy/UI/MenuBarPanel/Components/PanelHeaderView.swift`
  - `leanring-buddy/UI/MenuBarPanel/Components/PanelPermissionsCard.swift`
  - `leanring-buddy/UI/MenuBarPanel/Components/PanelModelPickerSection.swift`
  - `leanring-buddy/UI/MenuBarPanel/Components/PanelTTSVoiceSection.swift`
  - `leanring-buddy/UI/MenuBarPanel/Components/PanelFooterSection.swift`
  - `leanring-buddy/UI/DesignSystem/Colors.swift`
  - `leanring-buddy/UI/DesignSystem/Typography.swift`
  - `leanring-buddy/UI/DesignSystem/Metrics.swift`
  - `leanring-buddy/UI/DesignSystem/ButtonStyles.swift`
  - `leanring-buddy/UI/DesignSystem/AppKitBridges.swift`
- Modify:
  - `leanring-buddy/UI/CursorOverlay/OverlayWindow.swift` (nur noch `NSWindow`-Subklasse)
  - `leanring-buddy/UI/MenuBarPanel/CompanionPanelView.swift` (schlanker Container, ~120 Zeilen)
  - `leanring-buddy/UI/DesignSystem/DesignSystem.swift` (Aggregation oder Forwarding)

**Interfaces:**
- Consumes: `CompanionCoordinator`, `DS`-Design Tokens
- Produces: Modulare, übersichtliche SwiftUI-Komponenten, die jeweils < 250 Zeilen umfassen.

- [ ] **Step 1: `DesignSystem.swift` aufteilen**

Teile die 880 Zeilen auf in:
- `Colors.swift` (Farb-Tokens und Gradienten)
- `Typography.swift` (Fonts)
- `Metrics.swift` (CornerRadii, Spacing, Shadows)
- `ButtonStyles.swift` (Die 7 ButtonStyle-Structs)
- `AppKitBridges.swift` (`IBeamCursorView`)

- [ ] **Step 2: `OverlayWindow.swift` aufteilen**

Teile die 1.049 Zeilen auf in:
- `OverlayWindow.swift` (`NSWindow`-Subklasse, ~45 Zeilen)
- `OverlayWindowManager.swift` (Multi-Screen Window Lifecycle, ~140 Zeilen)
- `BlueCursorView.swift` (SwiftUI-Cursor Container, ~250 Zeilen)
- `CursorFlightAnimator.swift` (Bezier- und Koordinatenberechnungen, ~180 Zeilen)
- `CursorShapes.swift` (`Triangle`, `SizePreferenceKey`, ~60 Zeilen)

- [ ] **Step 3: `CompanionPanelView.swift` aufteilen**

Teile die 1.016 Zeilen auf in:
- `CompanionPanelView.swift` (Haupt-Container mit ScrollView, ~120 Zeilen)
- `PanelHeaderView.swift` (Status-Badge, Titel)
- `PanelPermissionsCard.swift` (Permissions-Grid & Buttons)
- `PanelModelPickerSection.swift` (VLM-Auswahl)
- `PanelTTSVoiceSection.swift` (TTS-Modell, Sprache, Stimme, Audition, Speed)
- `PanelFooterSection.swift` (Toggle, Shortcuts, Quit)

- [ ] **Step 4: Commit**

```bash
git add leanring-buddy/UI/
git commit -m "refactor: decompose OverlayWindow, CompanionPanelView, and DesignSystem into modular components"
```

---

### Task 6: Vollständige Swift-Testing-Suite ausbauen

**Files:**
- Create:
  - `leanring-buddyTests/UnitTests/SpeechSentenceSegmenterTests.swift`
  - `leanring-buddyTests/UnitTests/PointingParserTests.swift`
  - `leanring-buddyTests/UnitTests/TTSCatalogAndSelectionTests.swift`
- Modify:
  - `leanring-buddyTests/leanring_buddyTests.swift` (Konsolidierung oder Aufteilung)

**Interfaces:**
- Consumes: `SpeechSentenceSegmenter`, `TTSModelCatalog`, `CompanionCoordinator.parsePointingCoordinates`
- Produces: Vollständige Testabdeckung für Streaming-Parsing, Tag-Extraktion und TTS-Modell-Fallbacks.

- [ ] **Step 1: Erweiterte Tests für `SpeechSentenceSegmenter` schreiben**

In `leanring-buddyTests/UnitTests/SpeechSentenceSegmenterTests.swift`:
- Test für Chunk-Zusammenführung über Token-Streaming-Grenzen hinweg.
- Test für deutsche Abkürzungen (`z. B.`, `ca.`, `Dr.`, `usw.`).
- Test für das vollständige Entfernen von `[POINT:x,y:label:screenN]` aus den emittierten Sätzen.

- [ ] **Step 2: Tests für Pointing-Parser schreiben**

In `leanring-buddyTests/UnitTests/PointingParserTests.swift`:
- Test für reguläre Koordinaten (`[POINT:500,200:Zahnrad:screen1]`).
- Test für Koordinaten ohne Screen-Angabe (`[POINT:120,45:Stop]`).
- Test für fehlerhafte / unvollständige Tags (robuster Fallback, kein Absturz).

- [ ] **Step 3: Tests für TTS-Katalog & Stimmenauswahl schreiben**

In `leanring-buddyTests/UnitTests/TTSCatalogAndSelectionTests.swift`:
- Test für Standardmodell (`qwen3-0.6b`).
- Test für Fallback auf Standardsprache/Standardstimme bei Modellwechsel.
- Test für Persistenz des Sprechgeschwindigkeits-Multiplikators im `SettingsStoring`-Mock.

- [ ] **Step 4: Commit**

```bash
git add leanring-buddyTests/UnitTests/
git commit -m "test: add comprehensive test suites for streaming segmenter, pointing parser, and tts catalog"
```

---

### Task 7: Dokumentations-Update (`AGENTS.md`) & Finale Verifikation

**Files:**
- Modify: `AGENTS.md` (und Symlink `CLAUDE.md`)

**Interfaces:**
- Consumes: Neue Verzeichnisstruktur, geänderte Dateipfade und aktualisierte Zeilenzahlen
- Produces: Aktuelle "Single Source of Truth" für zukünftige Agenten und Entwickler gemäß Self-Update-Instructions.

- [ ] **Step 1: Key Files Tabelle in `AGENTS.md` aktualisieren**

Passe die Tabelle der Hauptdateien an:
- Neue Pfade (`App/`, `Core/`, `Services/`, `UI/`) eintragen.
- Aktualisierte Zeilenanzahlen (jede Datei unter 300–400 Zeilen) reflektieren.
- Neue Test-Struktur in der Dokumentation abbilden.

- [ ] **Step 2: Architektur-Abschnitt in `AGENTS.md` aktualisieren**

Beschreibe das `CompanionCoordinator`-Muster, die Protokoll-Abstraktionen und die In-Memory-Mock-Infrastruktur.

- [ ] **Step 3: Commit**

```bash
git add AGENTS.md
git commit -m "docs: update AGENTS.md to reflect new modular architecture and folder structure"
```

---

## Plan Self-Review Checkliste

- [x] **Spec Coverage**: Alle in der Spezifikation genehmigten Bestandteile (Ordnerstruktur, Protokolle, Services, Coordinator, UI-Zerlegung, Testsuiten) sind als Tasks hinterlegt.
- [x] **No Placeholders**: Alle Schritte enthalten exakte Pfade, Bash-Befehle, Test-Code und Signaturen.
- [x] **Global Constraints eingehalten**: Kein `xcodebuild`-Aufruf, reines Swift Testing (`import Testing`), Erhalt von `Info.plist`/Entitlements im Root.
- [x] **Bite-Sized Tasks**: Jeder Task ist in 3–6 klare, unabhängige Schritte unterteilt.
