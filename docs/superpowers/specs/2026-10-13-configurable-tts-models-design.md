# Design-Spezifikation: Konfigurierbare TTS-Modelle & Menüleisten-UI-Anpassung

## 1. Übersicht & Ziel
In Clicky soll die Sprachausgabe flexibel konfiguriert werden können. Benutzer sollen zwischen verschiedenen Text-to-Speech-Modellen (u. a. Qwen3-TTS 0.6B für maximale Geschwindigkeit auf Deutsch, Qwen3-TTS 1.7B für maximale Qualität, Kokoro-82M für ultraschnelles Englisch/Multilingual sowie Apple Speech als nativer macOS-Fallback) umschalten können.
Zusätzlich wird das Menüleisten-Panel modernisiert und semantisch geschärft:
- Label `Model` wird in `VLM` umbenannt (Vision Language Model).
- Label `Voice` wird in `TTS` umbenannt.
- Es gibt Selektoren für:
  1. TTS-Modell / Provider
  2. Stimme (dynamisch passend zum Modell)
  3. Sprache (z. B. German, English, etc.)
  4. Geschwindigkeit (0.85× – 1.5×, bleibt erhalten)

## 2. TTS-Modell-Katalog & Konfiguration

Wir definieren einen strukturierten Datentyp `TTSModelOption`:
```swift
struct TTSModelOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let subtitle: String
    let repoName: String?
    let supportedLanguages: [TTSLanguageOption]
    let defaultLanguageCode: String
    let availableVoices: [String]
    let defaultVoice: String
}
```

### Unterstützte Modelle:
1. **Qwen3-TTS 0.6B (Schnell)**:
   - Modell-ID: `qwen3-0.6b`
   - Repo: `mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit`
   - Sprachen: German (de), English (en), French (fr), Spanish (es), Italian (it), Japanese (ja), Chinese (zh)
   - Stimmen: Serena, Vivian, Ryan, Aiden, Dylan, Eric, Uncle_Fu, Ono_Anna, Sohee
2. **Qwen3-TTS 1.7B (High Quality)**:
   - Modell-ID: `qwen3-1.7b`
   - Repo: `mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit`
   - Gleiche Sprachen & Stimmen wie 0.6B, aber größerer Checkpoint.
3. **Kokoro-82M (Ultra Fast / Multilingual)**:
   - Modell-ID: `kokoro-82m`
   - Repo: `mlx-community/Kokoro-82M-bf16`
   - Sprachen: English (American & British), French, Spanish, Italian, Japanese, Chinese
   - Stimmen: af_heart, af_bella, af_nicole, af_sky, am_adam, am_michael, am_eric, bf_emma, bf_isabella, bm_george, bm_lewis
4. **Apple Speech (macOS Native)**:
   - Modell-ID: `apple-speech`
   - Repo: `nil`
   - Sprachen: System-Sprachen (Deutsch, English, etc.)
   - Stimmen: System-Stimmen (z. B. Anna, Markus, Viktor, Samantha)

## 3. Architektur & State Management
- `CompanionManager` verwaltet:
  - `selectedTTSModelId`: Gespeichert in `UserDefaults` (`selectedTTSModelId`, Default: `qwen3-0.6b`).
  - `selectedTTSLanguage`: Gespeichert in `UserDefaults` (`selectedTTSLanguage`, Default: `German`).
  - `selectedVoice`: Bleibt wie gehabt, passt sich automatisch der Modell-Auswahl an.
  - `speechRateMultiplier`: Bleibt unverändert.
- `MLXAudioQwenTTSClient` & `TextToSpeechProvider`:
  - `TextToSpeechProvider` erhält Methoden:
    - `setModelName(_ modelName: String)`
    - `setLanguageCode(_ languageCode: String)`
  - Beim Modellwechsel zu einem MLX-Modell wird `modelName` im Client aktualisiert.
  - Falls Apple Speech gewählt ist, delegiert der Provider direkt an `AppleTTSClient`.

## 4. UI-Layout im `CompanionPanelView`
- **VLM Row**:
  - Linkes Label: `VLM` (statt `Model`).
  - Dropdown für Vision-Modelle (Ollama) wie bisher.
- **TTS Configuration Section**:
  - Zeile 1:
    - Label `TTS`
    - Audio-Preview-Play/Stop-Button
    - Speed-Dropdown (0.85×, 1.0×, etc.)
    - Modell-Dropdown (z. B. "Qwen3-TTS 0.6B", "Qwen3-TTS 1.7B", "Kokoro-82M", "Apple Speech")
  - Zeile 2:
    - Sprach-Dropdown (Language: Deutsch, English, etc.)
    - Stimmen-Dropdown (Voice: Serena, Ryan, af_heart, etc.)
