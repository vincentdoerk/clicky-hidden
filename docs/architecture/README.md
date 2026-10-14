# Clicky Systemarchitektur & Diagramme

Willkommen in der technischen Architekturdokumentation von Clicky (`leanring-buddy`). Dieses Verzeichnis enthält die vollständigen UML-Klassen- und Sequenzdiagramme sowie einen interaktiven Web-Viewer zur visuellen Erkundung aller Datenverarbeitungs-Pipelines.

---

## 📚 Dokumentations-Inhalte

| Ressource | Format | Beschreibung |
|---|---|---|
| **[Interaktiver Diagramm-Viewer](index.html)** | HTML / SVG / Mermaid.js | Interaktive Webanwendung mit Pan/Zoom, Suche (`⌘K`), Code-Export und SVG-Download für alle 7 Diagramme. Kann direkt im Browser geöffnet werden: `open docs/architecture/index.html`. |
| **[UML-Klassendiagramme](uml-class-diagram.md)** | Markdown / Mermaid | Umfassende Klassenhierarchie und Schnittstellenbeziehungen für Core-Protokolle, Services, State Machine und Benutzeroberfläche. |
| **[Sequenzdiagramme aller Pipelines](sequence-diagrams.md)** | Markdown / Mermaid | Schritt-für-Schritt-Abläufe aller 5 Datenverarbeitungs-Pipelines mit exakten Methodennamen, Payloads, Thread-Kontexten und Latenzbudgets. |

---

## 🧭 Schnelleinstieg in die 5 Kern-Pipelines

1. **[Pipeline 1: Global Push-To-Talk & Audio Recording](sequence-diagrams.md#pipeline-1-global-push-to-talk--audioaufnahme)**
   - *Ablauf*: `CGEventTap` fängt `ctrl + option` ab ➔ `CompanionCoordinator` schaltet auf `.listening` ➔ `AudioEngineCaptureService` startet Input-Tap ➔ `AudioPowerMeter` berechnet RMS/dB ➔ `BlueCursorView` visualisiert die 5-Balken-Waveform bei 60 FPS.
2. **[Pipeline 2: Key Release, Screen Capture & Whisper STT](sequence-diagrams.md#pipeline-2-tastatur-release-screen-capture--whisper-stt)**
   - *Ablauf*: Tasten losgelassen ➔ Zustand `.processing` ➔ Multi-Monitor-JPEG-Snapshot via ScreenCaptureKit ➔ Parallele Inferenz via `WhisperCPPTranscriptionProvider` (`large-v3-turbo`) ➔ Transkript-Finalisierung.
3. **[Pipeline 3: Multimodal Vision Chat & Streaming Speech Synthesis](sequence-diagrams.md#pipeline-3-multimodales-vision-llm-streaming--satz-fr-satz-tts)**
   - *Ablauf*: Transkript + Screenshots an `OllamaAPI` ➔ NDJSON Token-Streaming ➔ `SpeechSentenceSegmenter` puffert Chunks, schützt deutsche Abkürzungen (`z. B.`, `ca.`) und filtert `[POINT]`-Tags ➔ `MLXAudioQwenTTSClient` synthetisiert Satz für Satz im Hintergrund über `mlx_audio.server`.
4. **[Pipeline 4: Pointing Detection, Apple Vision OCR & Bezier Flight Physics](sequence-diagrams.md#pipeline-4-pointing-erkennung-apple-vision-ocr--bezier-fluganimation)**
   - *Ablauf*: Extrahieren von `[POINT:x,y:label]` (0–1000) ➔ Apple Vision OCR (`VNRecognizeTextRequest`) snappt auf exakte UI-Text-Bounding-Box ➔ `CursorFlightAnimator` berechnet kubische Bezier-Flugkurve ➔ `BlueCursorView` fliegt mit Smoothstep zum Ziel und blendet Sprechblase ein.
5. **[Pipeline 5: Barge-In Interruption & Error Handling](sequence-diagrams.md#pipeline-5-barge-in-unterbrechung--fehlerbehandlung)**
   - *Ablauf*: Nutzer spricht während laufender Sprachausgabe erneut ➔ Sofortiger Abbruch laufender Concurrency Tasks und TTS-Queues ➔ Nahtloser Neustart der Aufnahme ohne Audio-Überlappung.

---

## 🖥️ Interaktiven Viewer starten

```bash
# Im Projektverzeichnis ausführen:
open docs/architecture/index.html
```
