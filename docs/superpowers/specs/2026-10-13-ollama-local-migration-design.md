# Design Specification: 100% Lokale Migration für Clicky (Ollama, Apple Speech, Apple TTS)

## 1. Übersicht & Ziel
Clicky wird von cloudbasierten APIs (Anthropic Claude, ElevenLabs TTS, AssemblyAI STT) und dem Cloudflare Worker Proxy vollständig auf lokale On-Device-Verarbeitung auf macOS migriert:
- **Vision LLM:** Lokale Ollama-Instanz (`http://localhost:11434`) mit dynamischer Erkennung installierter Vision-Modelle.
- **Speech-to-Text:** Nativer macOS `AppleSpeechTranscriptionProvider` (`SFSpeechRecognizer`).
- **Text-to-Speech:** Nativer macOS `AppleTTSClient` (`AVSpeechSynthesizer`).

---

## 2. Architektur & Komponenten

```mermaid
flowchart TD
    User["Nutzer (MacBook M-Serie)"] -->|Push-to-Talk Ctrl+Opt| App["Clicky macOS Menüleisten-App"]
    
    subgraph Local_Pipeline["100% Lokale On-Device Pipeline"]
        App -->|1. Mic Audio| AppleSpeech["Apple Speech Framework (SFSpeechRecognizer)"]
        AppleSpeech -->|Transkript| App
        App -->|2. Multi-Display Screenshots + Prompt| OllamaAPI["OllamaAPI (localhost:11434/api/chat)"]
        OllamaAPI -->|3. NDJSON Streaming + [POINT]-Tag| App
        App -->|4. Antworttext| AppleTTS["AppleTTSClient (AVSpeechSynthesizer)"]
        AppleTTS -->|Audioausgabe| User
    end

    App -->|5. Cursor-Flug & Zeige-Animation| User
```

### 2.1 Vision & Chat: `OllamaAPI.swift`
- **Endpunkte:**
  - `GET http://localhost:11434/api/tags`: Ruft alle installierten Modelle ab. Filtert Modelle mit `capabilities.contains("vision")` heraus (sowie Namensmuster wie `*vision*` oder `*vl*`).
  - `POST http://localhost:11434/api/chat`: Sendet System-Prompt, Konversations-Historie, Bildschirmaufnahmen (Base64) und Nutzer-Prompt im NDJSON-Streaming-Format.
- **Streaming-Parser:**
  - Liest zeilenweise JSON (`URLSession.bytes(for:)`).
  - Extrahiert Chunks aus `message.content`.
  - Liefert Chunks progressiv an den Caller und gibt nach Stream-Ende den Gesamttext und die Dauer zurück.
- **Model-Management:**
  - Dynamische Liste verfügbarer Vision-Modelle.
  - Speichert das ausgewählte Modell in `UserDefaults`.

### 2.2 Text-to-Speech: `AppleTTSClient.swift`
- **Implementierung:**
  - Nutzt `AVSpeechSynthesizer` aus `AVFoundation`.
  - Implementiert `AVSpeechSynthesizerDelegate` zur Überwachung des Sprechstatus (`didStart`, `didFinish`, `didCancel`).
  - Eigenschaft `isPlaying: Bool`: Gibt den aktuellen Wiedergabestatus für das Ausblenden des Overlays (`transientHideTask`) zurück.
  - Methode `speakText(_ text: String) async throws`: Startet die Sprachausgabe mit der optimalen Systemstimme (z. B. Siri/Enhanced Stimme entsprechend Systemsprache/Locale).
  - Methode `stopPlayback()`: Bricht die Wiedergabe sofort ab (`synthesizer.stopSpeaking(at: .immediate)`).

### 2.3 Speech-to-Text: `AppleSpeechTranscriptionProvider.swift`
- Bereits vollständig implementiert.
- Konfiguration in `Info.plist`:
  - `VoiceTranscriptionProvider` wird auf `apple` gesetzt.

### 2.4 Manager & UI Integration
- **`CompanionManager.swift`:**
  - Ersetzt `ClaudeAPI` durch `OllamaAPI`.
  - Ersetzt `ElevenLabsTTSClient` durch `AppleTTSClient`.
  - Entfernt Worker-Proxy-URLs (`http://localhost:8787`).
  - Stellt Methoden und Publisher für verfügbare Vision-Modelle bereit.
- **`CompanionPanelView.swift`:**
  - Der statische "Sonnet/Opus"-Picker wird durch einen dynamischen Vision-Modell-Picker ersetzt.
  - Zeigt die von Ollama erkannten Vision-fähigen Modelle an.
  - Bietet einen Reload-Button zur Aktualisierung der Modellliste.

---

## 3. Fehlerbehandlung & Ausfallsicherheit
- **Ollama nicht erreichbar:** Wenn `localhost:11434` nicht antwortet, informiert die Sprachausgabe / UI den Nutzer ("Ollama is not running. Please start Ollama.").
- **Keine Vision-Modelle installiert:** Warnung im UI mit Hinweis auf `ollama run llama3.2-vision` oder `ollama run qwen2.5-vl`.
- **Apple Speech Fallback:** Lokale Erkennung läuft offline über Apples On-Device Speech Recognizer.

---

## 4. Konventionen
- Einhaltung der Naming-Regeln aus `AGENTS.md` (Klarheit vor Kürze, keine Ein-Buchstaben-Variablen).
- `@MainActor` Isolation für alle UI-relevanten Properties und Methoden.
- Kein Aufruf von `xcodebuild` im Terminal zur Erhaltung der macOS TCC-Berechtigungen.
