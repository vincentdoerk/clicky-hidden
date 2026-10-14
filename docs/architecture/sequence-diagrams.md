# Architektur: UML-Sequenzdiagramme der Clicky-Datenverarbeitungspipelines

Dieses Dokument enthält detaillierte UML-Sequenzdiagramme (`sequenceDiagram`) für sämtliche Kern-Workflows und Datenverarbeitungspipelines der Clicky-Anwendung (`leanring-buddy`). Die Diagramme basieren direkt auf den realen Swift-Implementierungen, ihren Concurrency-Modellen (`@MainActor`, `async`/`await`, `Task`, CoreGraphics RunLoop Source), Datenstrukturen und Fehlerbehandlungsmechanismen.

---

## Inhaltsverzeichnis

1. [Pipeline 1: Global Push-To-Talk & Audio Recording](#pipeline-1-global-push-to-talk--audio-recording)
2. [Pipeline 2: Key Release, Screen Capture & Whisper STT](#pipeline-2-key-release-screen-capture--whisper-stt)
3. [Pipeline 3: Multimodal Vision Chat & Streaming Speech Synthesis](#pipeline-3-multimodal-vision-chat--streaming-speech-synthesis)
4. [Pipeline 4: Pointing Detection, Apple Vision OCR & Bezier Flight Physics](#pipeline-4-pointing-detection-apple-vision-ocr--bezier-flight-physics)
5. [Pipeline 5: Barge-In Interruption & Error Handling](#pipeline-5-barge-in-interruption--error-handling)

---

## Pipeline 1: Global Push-To-Talk & Audio Recording

### Übersicht
Diese Pipeline beschreibt den Vorgang vom Drücken des systemweiten Hotkeys (`ctrl + option`) über das Starten der Mikrofonaufnahme mittels `AVAudioEngine`, die parallele Vorab-Bildschirmerfassung (Pre-Capture) zur Latenzreduktion bis hin zur Berechnung der Audio-Wellenform und deren Darstellung im SwiftUI-Cursor-Overlay.

```mermaid
sequenceDiagram
    autonumber
    actor User as Benutzer
    participant CG as CGEventTap (CoreGraphics / CFMachPort)
    participant PTT as GlobalPushToTalkShortcutMonitor
    participant Coord as CompanionCoordinator (@MainActor)
    participant OverlayMgr as OverlayWindowManager (@MainActor)
    participant ScreenUtil as CompanionScreenCaptureUtility (@MainActor)
    participant Dict as BuddyDictationManager (@MainActor)
    participant AudioEng as AudioEngineCaptureService (AVAudioEngine)
    participant PowerMeter as AudioPowerMeter
    participant WhisperSession as WhisperCPPTranscriptionSession
    participant CursorView as BlueCursorView / Waveform (SwiftUI)

    Note over User,CG: Benutzer drückt 'ctrl + option'
    User->>CG: Key Down / Flags Changed Event (Modifikatoren aktiv)
    activate CG
    CG->>PTT: handleGlobalEventTap(eventType: .flagsChanged, event: CGEvent)
    deactivate CG
    activate PTT
    PTT->>PTT: BuddyPushToTalkShortcut.shortcutTransition(...) -> .pressed
    PTT->>PTT: isShortcutCurrentlyPressed = true
    PTT-->>Coord: shortcutTransitionPublisher.send(.pressed) [DispatchQueue.main]
    deactivate PTT

    activate Coord
    Coord->>Coord: handleShortcutTransition(.pressed)
    
    opt Overlay nicht sichtbar (Transient Mode)
        Coord->>OverlayMgr: showOverlay(onScreens: NSScreen.screens, companionManager: self)
        OverlayMgr->>OverlayMgr: Erzeuge/Positioniere borderless NSPanels (.floating, .canJoinAllSpaces)
        Coord->>Coord: isOverlayVisible = true
    end

    Note over Coord: Barge-In: Vorherige Tasks & Audio stoppen
    Coord->>Coord: currentResponseTask?.cancel()
    Coord->>Coord: stopVoicePreview()
    Coord->>Coord: clearDetectedElementLocation()
    Coord->>Coord: voiceState = .processing, processingStepText = "Mikrofon vorbereiten..."

    par Latenzoptimierung: Bildschirm-Precapture starten
        Coord->>ScreenUtil: precapturedScreensTask = Task { captureAllScreensAsJPEG() }
        activate ScreenUtil
        ScreenUtil-->>Coord: Async Task gestartet (erfasst Screens parallel zur Sprache)
        deactivate ScreenUtil
    and Audio-Aufnahmesitzung starten
        Coord->>Dict: startPushToTalkFromKeyboardShortcut(...)
        activate Dict
        Dict->>Dict: isPreparingToRecord = true
        Dict->>Dict: requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts()
        Dict->>WhisperSession: startStreamingSession(keyterms: [...])
        activate WhisperSession
        WhisperSession-->>Dict: Instanz von WhisperCPPTranscriptionSession
        deactivate WhisperSession

        Dict->>AudioEng: startCapturing(bufferHandler: { buffer in ... })
        activate AudioEng
        AudioEng->>AudioEng: inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat)
        AudioEng->>AudioEng: audioEngine.start()
        AudioEng-->>Dict: Erfolgreich gestartet
        deactivate AudioEng

        Dict->>Dict: isRecordingFromKeyboardShortcut = true, isPreparingToRecord = false
        Dict-->>Coord: Combine Sink: isRecording == true -> voiceState = .listening
        deactivate Dict
    end
    deactivate Coord

    Note over AudioEng,CursorView: Kontinuierlicher Audio-Streaming-Loop während Spracheingabe
    loop Für jeden Audiopuffer (1024 Frames, ~44.1/48 kHz AVAudioPCMBuffer)
        AudioEng->>Dict: bufferHandler(audioBuffer: AVAudioPCMBuffer)
        activate Dict
        
        par Audio-Pufferung für Transkription
            Dict->>WhisperSession: appendAudioBuffer(audioBuffer)
            activate WhisperSession
            WhisperSession->>WhisperSession: audioPCM16Converter.convertToPCM16Data(from: audioBuffer)
            WhisperSession->>WhisperSession: bufferedPCM16AudioData.append(pcm16Data) [16 kHz Mono]
            deactivate WhisperSession
        and RMS & Wellenform-Pegelberechnung
            Dict->>PowerMeter: calculatePowerLevel(from: audioBuffer, boostMultiplier: 10.2)
            activate PowerMeter
            PowerMeter->>PowerMeter: calculateRootMeanSquare(floatChannelData[0])
            PowerMeter-->>Dict: boostedLevel: Float (0.0 ... 1.0)
            deactivate PowerMeter
            
            Dict->>Dict: Glättung: max(boostedLevel, currentAudioPowerLevel * 0.72)
            Dict->>Dict: currentAudioPowerLevel = smoothedLevel
            Dict-->>Coord: Combine Sink: coordinator.currentAudioPowerLevel = powerLevel
            Coord-->>CursorView: @ObservedObject companionManager.currentAudioPowerLevel
            activate CursorView
            CursorView->>CursorView: BlueCursorWaveformView rendert 5 animierte Balken via TimelineView (36-60 FPS)
            deactivate CursorView
        end
        deactivate Dict
    end
```

### Technische Erläuterung & Latenzbetrachtungen

1. **Ereignisüberwachung via `CGEventTap`**:
   - Die Überwachung der Modifikatortasten (`ctrl + option`) erfolgt über einen `listenOnly`-Event-Tap auf Session-Ebene (`kCGSessionEventTap`).
   - Da die Callback-Funktion direkt in den `CFRunLoopGetMain()` eingebunden ist, werden Tastenzustandsänderungen mit minimaler Latenz (< 2 ms) im Hauptthread abgefangen.

2. **Parallele Bildschirmerfassung (Pre-Capture)**:
   - Anstatt erst nach dem Loslassen der Taste mit der Bildschirmerfassung zu beginnen, startet `CompanionCoordinator` unmittelbar beim `pressed`-Event eine asynchrone Task:
     ```swift
     precapturedScreensTask = Task { @MainActor in
         try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
     }
     ```
   - Dadurch wird die Bildschirmerfassung via ScreenCaptureKit (Dauer ca. 80–180 ms je nach Monitoranzahl und Auflösung) vollständig parallel zur Audioaufnahme des Nutzers ausgeführt. Sobald der Nutzer fertig gesprochen hat, liegt der Screenshot bereits im Speicher vor – Latenzgewinn: **100 % der Screenshot-Erfassungszeit**.

3. **Audio-Erfassung & RMS-Berechnung**:
   - `AudioEngineCaptureService` installiert einen Bus-0-Tap auf der `AVAudioInputNode` mit einer Puffergröße von 1024 Frames (ca. 21–23 ms Audiodaten pro Puffer).
   - In `AudioPowerMeter` wird der Root Mean Square (RMS) des ersten Audiokanals berechnet:
     $$\text{RMS} = \sqrt{\frac{1}{N}\sum_{i=0}^{N-1} s_i^2}$$
     Dieser Wert wird mit `boostMultiplier = 10.2` skaliert und auf den Bereich $[0.0, 1.0]$ normiert.
   - `BuddyDictationManager` wendet eine exponentielle Abklingglättung an (`smoothed = max(boosted, current * 0.72)`), um ein unruhiges Flackern der UI-Wellenform in `BlueCursorWaveformView` zu verhindern.

---

## Pipeline 2: Key Release, Screen Capture & Whisper STT

### Übersicht
Beim Loslassen der Tastenkombination wird die Mikrofonerfassung sofort gestoppt. Die gepufferten Audiodaten werden zu einer 16-kHz-Mono-WAV-Datei zusammengesetzt, an das lokale `whisper-cli`-Binary übergeben und transkribiert. Parallel wird das vorab erfasste Screenshot-Ergebnis abgeholt und die visuelle KI-Pipeline initiiert.

```mermaid
sequenceDiagram
    autonumber
    actor User as Benutzer
    participant CG as CGEventTap (CoreGraphics)
    participant PTT as GlobalPushToTalkShortcutMonitor
    participant Coord as CompanionCoordinator (@MainActor)
    participant Dict as BuddyDictationManager (@MainActor)
    participant AudioEng as AudioEngineCaptureService
    participant WhisperSession as WhisperCPPTranscriptionSession
    participant WAVBuilder as BuddyWAVFileBuilder
    participant WhisperCLI as whisper-cli (C++ Process)
    participant ScreenUtil as CompanionScreenCaptureUtility
    participant SCK as ScreenCaptureKit (macOS Framework)

    Note over User,CG: Benutzer lässt 'ctrl + option' los
    User->>CG: Key Up / Flags Changed Event
    activate CG
    CG->>PTT: handleGlobalEventTap(eventType: .flagsChanged, event: CGEvent)
    deactivate CG
    activate PTT
    PTT->>PTT: BuddyPushToTalkShortcut.shortcutTransition(...) -> .released
    PTT->>PTT: isShortcutCurrentlyPressed = false
    PTT-->>Coord: shortcutTransitionPublisher.send(.released)
    deactivate PTT

    activate Coord
    Coord->>Coord: handleShortcutTransition(.released)
    Coord->>Coord: voiceState = .processing, processingStepText = "Audio verarbeiten..."
    Coord->>Dict: stopPushToTalkFromKeyboardShortcut()
    deactivate Coord

    activate Dict
    Dict->>Dict: isRecordingFromKeyboardShortcut = false, isFinalizingTranscript = true
    Dict->>AudioEng: stopCapturing()
    activate AudioEng
    AudioEng->>AudioEng: audioEngine.stop(), inputNode.removeTap(onBus: 0)
    deactivate AudioEng

    Dict->>WhisperSession: requestFinalTranscript()
    activate WhisperSession
    Dict->>Dict: Starte Fallback-Timer (finalizeFallbackWorkItem, 10.0s Timeout)

    WhisperSession->>WhisperSession: synchronizationQueue.sync { guard !bufferedPCM16AudioData.isEmpty }
    WhisperSession->>WAVBuilder: buildWAVData(fromPCM16MonoAudio: bufferedData, sampleRate: 16000)
    activate WAVBuilder
    WAVBuilder-->>WhisperSession: wavData: Data (RIFF/WAVE Header + PCM16 Payload)
    deactivate WAVBuilder

    WhisperSession->>WhisperSession: Schreibe Datei: /tmp/whisper_<UUID>.wav
    WhisperSession->>WhisperCLI: Process.run(/opt/homebrew/bin/whisper-cli, args: [-m, modelPath, -f, wavPath, -l, auto, -nt, -np])
    activate WhisperCLI
    Note over WhisperCLI: Lokale Inferenz mit ggml-large-v3-turbo.bin (Metal/CPU Acceleration)
    WhisperCLI-->>WhisperSession: STDOUT Pipe: rawTranscriptText
    deactivate WhisperCLI

    WhisperSession->>WhisperSession: Bereinige Text (Regex: [_BEG_], [_TT_\d+], [BLANK_AUDIO])
    WhisperSession->>WhisperSession: Lösche temporäre WAV-Datei
    WhisperSession-->>Dict: onFinalTranscriptReady(cleanedTranscript)
    deactivate WhisperSession

    Dict->>Dict: finalizeFallbackWorkItem?.cancel()
    Dict->>Dict: submitDraftText(cleanedTranscript)
    Dict->>Dict: resetSessionState()
    deactivate Dict

    activate Coord
    Coord->>Coord: lastTranscript = cleanedTranscript
    Coord->>Coord: sendTranscriptToVisionModelWithScreenshot(transcript: cleanedTranscript)

    alt Pre-Capture war bereits erfolgreich beendet
        Coord->>Coord: Verwende precapturedScreensTask.value (0 ms Wartezeit!)
    else Pre-Capture läuft noch
        Coord->>ScreenUtil: await precapturedScreensTask.value
        activate ScreenUtil
        ScreenUtil-->>Coord: [CompanionScreenCapture]
        deactivate ScreenUtil
    else Fallback: Kein Pre-Capture vorhanden
        Coord->>ScreenUtil: captureAllScreensAsJPEG()
        activate ScreenUtil
        ScreenUtil->>SCK: SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        ScreenUtil->>SCK: SCScreenshotManager.captureImage(...) für jeden Monitor
        SCK-->>ScreenUtil: [CGImage]
        ScreenUtil->>ScreenUtil: NSBitmapImageRep -> JPEG (Compression: 0.85)
        ScreenUtil-->>Coord: [CompanionScreenCapture]
        deactivate ScreenUtil
    end

    Note over Coord: Übergang zu Pipeline 3 (Vision Chat & TTS)
    deactivate Coord
```

### Technische Erläuterung & Datentransformationen

1. **Audio-Serialisierung**:
   - `AudioEngineCaptureService` liefert Samples im nativen Hardware-Format (häufig 44.1 kHz oder 48 kHz Float32).
   - `BuddyPCM16AudioConverter` konvertiert diese in Echtzeit über `AVAudioConverter` in 16.000 Hz, 16-Bit Signed Integer Linear PCM (Mono).
   - Beim Loslassen der Taste konstruiert `BuddyWAVFileBuilder` einen standardkonformen 44-Byte RIFF/WAVE-Header und speichert die Datei im RAM-basierten temporären Dateisystem (`FileManager.default.temporaryDirectory`).

2. **Inferenz mit Whisper C++**:
   - Ausführung des nativen CLI-Tools `whisper-cli`:
     ```bash
     whisper-cli -m models/ggml-large-v3-turbo.bin -f /tmp/whisper_XYZ.wav -l auto -nt -np
     ```
     `-nt` unterdrückt Zeitstempelmarkierungen, `-np` unterdrückt Fortschrittsbalken.
   - Textbereinigung filtert interne Token-Tags (`\[_BEG_\]`, `\[_TT_\d+\]`, `\[BLANK_AUDIO\]`) per Regular Expression heraus.

3. **Multi-Monitor ScreenCaptureKit Geometrie**:
   - Bildschirme werden deterministisch von links nach rechts (`origin.x`) sortiert, sodass Bildschirmindizes über Sitzungen hinweg stabil bleiben.
   - Die Bildschirmkoordinaten werden zwischen dem AppKit-System (Nullpunkt unten links) und Core Graphics (Nullpunkt oben links) exakt abgeglichen.
   - Die Cursorposition zum Aufnahmezeitpunkt (`NSEvent.mouseLocation`) wird normalisiert ($0\dots 1000$) in das Label des primären Bildschirms eingebettet:
     `"screen 1 — user's cursor is currently at [450,320]"`

---

## Pipeline 3: Multimodal Vision Chat & Streaming Speech Synthesis

### Übersicht
Sobald Transkript und Screenshots vorliegen, streamt `OllamaAPI` die Antwort zeilenweise als NDJSON. Der `SpeechSentenceSegmenter` extrahiert vollständige Sätze, entfernt Steuerbefehle wie `[POINT:...]` und übermittelt die Sätze an den `MLXAudioQwenTTSClient`. Dieser synthetisiert die Sätze asynchron und parallel über `mlx_audio.server`, sodass die Sprachausgabe bereits beginnt, während das Vision-LLM noch generiert.

```mermaid
sequenceDiagram
    autonumber
    participant Coord as CompanionCoordinator (@MainActor)
    participant OllamaClient as OllamaAPI (URLSession bytes)
    participant OllamaDaemon as Ollama Daemon (:11434)
    participant Segmenter as SpeechSentenceSegmenter
    participant MLXClient as MLXAudioQwenTTSClient (@MainActor)
    participant MLXDaemon as mlx_audio.server (:8000)
    participant Player as AVAudioPlayer
    participant CursorView as BlueCursorView (UI)

    activate Coord
    Coord->>Coord: voiceState = .processing, processingStepText = "Bild analysieren..."
    Coord->>Segmenter: let sentenceSegmenter = SpeechSentenceSegmenter()
    Coord->>MLXClient: beginSpeechSession(onFirstAudioStarted: {...}, onPlaybackFinished: {...})
    activate MLXClient
    MLXClient->>MLXClient: Initialisiere neue Sitzung (UUID), leere Warteschlangen
    deactivate MLXClient

    Coord->>OllamaClient: analyzeImageStreaming(images, systemPrompt, history, userPrompt, onTextChunk)
    activate OllamaClient
    OllamaClient->>OllamaDaemon: POST /api/chat (stream: true, model: "llama3.2-vision", images: [base64...])
    activate OllamaDaemon
    OllamaDaemon-->>OllamaClient: HTTP 200 Streaming Response (NDJSON chunks)

    loop Für jede Zeile im Byte-Stream (responseLine in byteStream.lines)
        OllamaDaemon-->>OllamaClient: {"message": {"content": " token"}, "done": false}\n
        OllamaClient->>OllamaClient: accumulatedResponseText += contentChunk
        OllamaClient->>Coord: await onTextChunk(accumulatedResponseText) [@MainActor]
        
        Coord->>Coord: processingStepText = "Antwort generieren..."
        Coord->>Segmenter: appendAccumulatedResponseText(accumulatedResponseText)
        activate Segmenter
        Segmenter->>Segmenter: Entferne Tags ([POINT:...]) und Markdown-Zeichen (*, #, `)
        Segmenter->>Segmenter: Schütze deutsche Abkürzungen (z.B., d.h., bzw., usw., Dr.)
        Segmenter->>Segmenter: Prüfe Satzgrenzen (. ! ? …) & Mindestlänge (>= 12 Zeichen)
        Segmenter-->>Coord: [Vollständiger Satz i] (falls abgeschlossen)
        deactivate Segmenter

        opt Vollständiger Satz erkannt
            Coord->>MLXClient: enqueueSentenceForSpeech(sentence_i)
            activate MLXClient
            MLXClient->>MLXClient: enqueuedSentences.append(sentence_i)
            
            Note over MLXClient,MLXDaemon: Parallele asynchrone Synthese-Task für Satz i
            par Asynchrone Synthese von Satz i
                MLXClient->>MLXDaemon: POST /v1/audio/speech {"input": sentence_i, "voice": "Seraphina", "model": "Qwen3-TTS"}
                activate MLXDaemon
                MLXDaemon-->>MLXClient: WAV Audio Bytes (RIFF/WAVE)
                deactivate MLXDaemon
                MLXClient->>MLXClient: synthesizedAudioDataByIndex[i] = wavData
                
                opt Player ist idle und wartet auf Satz i
                    MLXClient->>Player: AVAudioPlayer(data: wavData)
                    activate Player
                    Player->>Player: play()
                    deactivate Player
                    
                    opt Erstes Audio der Session
                        MLXClient->>MLXClient: hasCurrentSessionStartedAudio = true
                        MLXClient-->>Coord: onFirstAudioStarted()
                        Coord->>Coord: voiceState = .responding, processingStepText = ""
                        Coord-->>CursorView: Status .responding -> zeige blaues Dreieck & Audio-Wiedergabe
                    end
                end
            end
            deactivate MLXClient
        end
    end
    deactivate OllamaDaemon

    OllamaClient-->>Coord: (fullResponseText, totalDuration)
    deactivate OllamaClient

    Coord->>Segmenter: flushRemainingSentences()
    activate Segmenter
    Segmenter-->>Coord: [Verbleibende Sätze inkl. gehaltene Kurzfragmente]
    deactivate Segmenter

    loop Für jeden verbleibenden Satz
        Coord->>MLXClient: enqueueSentenceForSpeech(remainingSentence)
    end
    Coord->>MLXClient: finishSpeechSession()
    activate MLXClient
    MLXClient->>MLXClient: hasFinishedEnqueueingSentencesForSession = true
    deactivate MLXClient

    Note over Player,MLXClient: Sequenzielle unterbrechungsfreie Audiowiedergabe
    loop Wenn Satz i beendet ist
        Player-->>MLXClient: audioPlayerDidFinishPlaying(player, successfully: true)
        activate MLXClient
        MLXClient->>MLXClient: advanceToNextSentenceAfterPlaybackFinished()
        MLXClient->>MLXClient: currentPlayingSentenceIndex += 1
        
        alt Nächster Satz i+1 bereits im Cache
            MLXClient->>Player: AVAudioPlayer(data: synthesizedAudioDataByIndex[i+1]).play()
        else Synthese für i+1 läuft noch
            MLXClient->>MLXClient: Warte auf Beendigung der Synthese-Task...
        end
        deactivate MLXClient
    end

    Note over MLXClient,Coord: Letzter Satz abgespielt
    MLXClient-->>Coord: onPlaybackFinished()
    activate Coord
    opt Kein aktives Pointing vorhanden
        Coord->>Coord: voiceState = .idle, processingStepText = ""
        Coord->>Coord: scheduleTransientHideIfNeeded() (Fade-out nach 5s Inaktivität)
    end
    deactivate Coord
```

### Technische Erläuterung & Segmentierungslogik

1. **Streaming-Architektur (`SpeechSentenceSegmenter`)**:
   - LLMs generieren Text tokenweise. Ein Warten auf die vollständige Antwort würde eine Latenz von 3–8 Sekunden bedeuten.
   - Der `SpeechSentenceSegmenter` verarbeitet ausschließlich neu hinzugekommene Skalare (`newlyAppendedScalars`).
   - **Tag-Stripping im Stream**: Befindet sich der Parser innerhalb von `[...]`, werden die Zeichen verworfen, sodass Koordinatentags wie `[POINT:450,210:erstellen]` niemals vom TTS vorgelesen werden.
   - **Abkürzungserkennung**: Eine feste Menge deutscher und englischer Abkürzungen (`z.B.`, `d.h.`, `u.a.`, `bzw.`, `usw.`, `ca.`, `Dr.`, `Prof.`, `e.g.`) wird erkannt. Ein Punkt nach einer solchen Abkürzung löst **keinen** Satzabschluss aus.
   - **Minimale/Maximale Latenzgrenzen**:
     - `minimumSentenceCharacterCount = 12`: Verhindert abgehackte Mini-Fragmente ("ja.", "klar.").
     - `maximumPendingCharacterCountBeforeCommaSplit = 220`: Teilt lange Schachtelsätze am letzten Komma, um die Time-to-First-Audio (TTFA) unter 1,5 Sekunden zu halten.

2. **Parallele Vorab-Synthese (`MLXAudioQwenTTSClient`)**:
   - Jeder emittierte Satz startet sofort einen eigenständigen HTTP-Request gegen `mlx_audio.server`.
   - Die resultierenden WAV-Puffer werden in `synthesizedAudioDataByIndex: [Int: Data]` indiziert abgelegt.
   - Der `AVAudioPlayer` spielt die Sätze sequenziell ab. Da Satz $N+1$ synthetisiert wird, während Satz $N$ noch abgespielt wird, entsteht eine nahtlose, unterbrechungsfreie Sprachausgabe.

---

## Pipeline 4: Pointing Detection, Apple Vision OCR & Bezier Flight Physics

### Übersicht
Nach Abschluss der LLM-Generierung parst der `PointingCoordinateParser` das `[POINT:...]`-Tag. Die normalisierten Koordinaten ($0\dots 1000$) werden in Bildschirmkoordinaten umgerechnet. Zur Beseitigung von KI-Ungenauigkeiten führt Apple Vision (`VNRecognizeTextRequest`) ein lokales OCR-Snapping auf den echten Button-Rahmen durch. Anschließend berechnet `CursorFlightAnimator` eine Bezier-Kurve mit dynamischer Drehung und Skalierung, die `BlueCursorView` mit 60 FPS abfliegt.

```mermaid
sequenceDiagram
    autonumber
    participant Coord as CompanionCoordinator (@MainActor)
    participant Parser as PointingCoordinateParser
    participant ScreenUtil as CompanionScreenCaptureUtility (@MainActor)
    participant VN as Apple Vision OCR (VNRecognizeTextRequest)
    participant CursorView as BlueCursorView (SwiftUI Overlay)
    participant Animator as CursorFlightAnimator
    participant Timer60 as Animation Timer (60 FPS / RunLoop)

    activate Coord
    Coord->>Parser: parsePointingCoordinates(from: fullResponseText)
    activate Parser
    Parser->>Parser: Regex: \[POINT\s*:\s*([^\]\n]+)\]
    Parser->>Parser: Extrahiere x, y, w, h, elementLabel, screenNumber
    Parser-->>Coord: PointingParseResult(coordinate: CGPoint(480, 210), size: CGSize(95, 35), label: "erstellen")
    deactivate Parser

    Coord->>Coord: Ermittle Target-Screen aus screenCaptures
    Coord->>Coord: Normalisiere Koordinaten: normX = 480/1000, normY = 210/1000
    Coord->>Coord: Berechne AppKit-Position: globalPoint = (localX + frame.origin.x, appKitY + frame.origin.y)

    Note over Coord,VN: Apple Vision OCR Snapping (Präzise Zentrierung auf UI-Element)
    Coord->>Parser: buildCandidateKeywords(label: "erstellen") -> ["erstellen"]
    Coord->>ScreenUtil: snapToMatchingTextElement(primaryTargetLabel, candidateKeywords, near: globalPoint, capture)
    activate ScreenUtil
    ScreenUtil->>ScreenUtil: Berechne Region of Interest (ROI: ±20% horizontal, ±20% vertikal um globalPoint)
    ScreenUtil->>VN: VNImageRequestHandler.perform([VNRecognizeTextRequest(recognitionLevel: .accurate)])
    activate VN
    VN-->>ScreenUtil: [VNRecognizedTextObservation]
    deactivate VN

    loop Für jede Texterkennung in der ROI
        ScreenUtil->>ScreenUtil: Berechne Distanz mit vertikaler Strafgewichtung: sqrt((dx*0.5)^2 + (dy*3.0)^2)
        ScreenUtil->>ScreenUtil: Prüfe Textübereinstimmung (Exact Match = 10000 Punkte)
    end
    ScreenUtil-->>Coord: ScreenTextMatch(text: "Erstellen", globalRect: CGRect(...), globalCenter: CGPoint(...))
    deactivate ScreenUtil

    Coord->>Coord: finalGlobalLocation = snappedMatch.globalCenter
    Coord->>Coord: detectedElementHighlightSize = snappedMatch.globalRect.size
    Coord->>Coord: detectedElementBubbleText = "erstellen"
    Coord->>Coord: detectedElementScreenLocation = finalGlobalLocation
    deactivate Coord

    Note over Coord,CursorView: SwiftUI State Update & Fluganimation
    activate CursorView
    CursorView->>CursorView: .onChange(of: detectedElementScreenLocation)
    CursorView->>CursorView: startNavigatingToElement(screenLocation)
    CursorView->>Animator: calculateElementHighlightAndLanding(screenLocation, highlightSize, screenFrame)
    activate Animator
    Animator-->>CursorView: (highlightRect, landingPoint: targetCorner + (6, 7))
    deactivate Animator

    CursorView->>CursorView: buddyNavigationMode = .navigatingToTarget, isReturningToCursor = false
    CursorView->>Timer60: Timer.scheduledTimer(withTimeInterval: 1/60, repeats: true)
    activate Timer60

    loop 60 FPS Animations-Schleife (Dauer: 0.6s bis 1.4s je nach Distanz)
        Timer60->>CursorView: Tick (currentFrame / totalFrames)
        CursorView->>Animator: evaluateDynamicFlightStep(currentFrame, totalFrames, liveMouseOrigin, destination)
        activate Animator
        Animator->>Animator: Hermite Smoothstep: t = progress^2 * (3 - 2 * progress)
        Animator->>Animator: Quadratic Bezier Arc: B(t) mit Scheitelpunktbogen (-min(dist * 0.2, 80))
        Animator->>Animator: Tangentenwinkel: atan2(dY, dX) * (180/pi) + 90°
        Animator->>Animator: Scale Pulse: 1.0 + sin(progress * pi) * 0.3 (bis zu 1.3x)
        Animator-->>CursorView: CursorFlightTrajectoryStep(position, rotationDegrees, scale)
        deactivate Animator
        
        CursorView->>CursorView: Aktualisiere State: cursorPosition, triangleRotationDegrees, buddyFlightScale
    end
    Timer60->>Timer60: invalidate()
    deactivate Timer60

    Note over CursorView: Landung & Element-Hervorhebung
    CursorView->>CursorView: buddyNavigationMode = .pointingAtTarget, triangleRotationDegrees = -35.0
    CursorView->>CursorView: withAnimation { showTargetHighlight = true } (Blaue gestrichelte Box)
    CursorView->>CursorView: streamNavigationBubbleCharacter("erstellen") (Typewriter-Effekt)

    Note over CursorView: Verweildauer (3.0s) & Rückflug zum Mauszeiger
    CursorView->>CursorView: DispatchQueue.main.asyncAfter(deadline: .now() + 3.0)
    CursorView->>CursorView: showTargetHighlight = false, navigationBubbleOpacity = 0.0
    CursorView->>CursorView: startFlyingBackToCursor() (evaluateStaticFlightStep zum echten Mauszeiger)
    CursorView->>CursorView: buddyNavigationMode = .followingCursor
    deactivate CursorView
```

### Technische Erläuterung & Mathematische Modelle

1. **Apple Vision OCR Snapping (`VNRecognizeTextRequest`)**:
   - Da Vision-LLMs Koordinaten mit einer gewissen Varianz schätzen, nutzt Clicky das native Apple Vision Framework für eine pixelgenaue Justierung:
   - **Region of Interest (ROI)**: Eingrenzung auf $\pm 20\%$ der Displayabmessungen um den Schätzwert, um Rechenzeit zu minimieren.
   - **Vertikal gewichtete Distanzfunktion**:
     $$d_{\text{eff}} = \sqrt{(0.5 \cdot \Delta x)^2 + (3.0 \cdot \Delta y)^2}$$
     *Hintergrund*: In modernen UIs (Menüs, Listen, Symbolleisten) liegen Elemente vertikal dicht beieinander (oft nur 20–30 pt Zeilenhöhe). Eine vertikale Abweichung führt leicht zum falschen UI-Element, während eine horizontale Abweichung meist innerhalb desselben Buttons liegt.
   - **Harte Schranken**: Kandidaten weiter als 140 pt horizontal oder 70 pt vertikal werden strikt ignoriert (`guard effectiveDistance <= 120.0`).

2. **Bezier-Flugkurven-Physik (`CursorFlightAnimator`)**:
   - **Hermite-Interpolation (Smoothstep)**:
     $$S(t) = 3t^2 - 2t^3 \quad \text{mit } t = \frac{\text{frame}}{\text{totalFrames}}$$
   - **Dynamische quadratische Bezier-Kurve**:
     $$B(t) = (1-t)^2 P_0 + 2(1-t)t P_1 + t^2 P_2$$
     Wobei $P_0$ der (während des Flugs mitbewegte) Mausursprung ist, $P_2$ der Zielpunkt und $P_1$ der Kontrollpunkt mit adaptiver Bogenhöhe:
     $$h_{\text{arc}} = \min(0.2 \cdot \text{distance}, 80.0\text{ pt})$$
   - **Ausrichtung (Tangentenrotation)**:
     $$\theta = \text{atan2}(B'_y(t), B'_x(t)) \cdot \frac{180^\circ}{\pi} + 90^\circ$$
     Das blaue Dreieck richtet seine Spitze exakt entlang des Flugvektors aus.
   - **Skalierungs-Puls (Flugdynamik)**:
     $$s(t) = 1.0 + 0.3 \cdot \sin(t \cdot \pi)$$
     Verleiht dem Cursor beim Scheitelpunkt einen dreidimensionalen "Sprung"-Effekt ($1.3\times$).

---

## Pipeline 5: Barge-In Interruption & Error Handling

### Übersicht
Clicky unterstützt ein sofortiges Unterbrechen laufender Prozesse (Barge-In): Sobald der Benutzer die Push-to-Talk-Taste drückt, während noch Text generiert, Sprache wiedergegeben oder ein Zeigevorgang animiert wird, werden alle Netzwerk- und Audio-Tasks sofort abgebrochen. Ebenso existieren robuste Fallback-Ketten für Serverausfälle (Ollama, MLX Audio).

```mermaid
sequenceDiagram
    autonumber
    actor User as Benutzer
    participant Coord as CompanionCoordinator (@MainActor)
    participant ResponseTask as currentResponseTask (Task<Void, Never>)
    participant MLXClient as MLXAudioQwenTTSClient (@MainActor)
    participant AppleTTS as AppleTTSClient (AVSpeechSynthesizer Fallback)
    participant Player as AVAudioPlayer
    participant CursorView as BlueCursorView (UI Overlay)
    participant Dict as BuddyDictationManager (@MainActor)

    %% SZenario 1: Barge-In
    rect rgb(240, 248, 255)
        Note over User,Dict: Szenario A: Barge-In (Nutzer spricht während Sprachausgabe / Flug)
        User->>Coord: PTT Shortcut gedrückt (handleShortcutTransition(.pressed))
        activate Coord
        
        Note over Coord: Sofortiger Abbruch aktiver Tasks
        Coord->>ResponseTask: cancel() (Beendet Ollama Streaming-Loop & Task)
        Coord->>MLXClient: stopPlayback()
        activate MLXClient
        MLXClient->>MLXClient: Breche alle aktiven Synthese-Tasks ab (activeSynthesisTasksByIndex)
        MLXClient->>Player: stop()
        MLXClient->>MLXClient: currentSpeechSessionIdentifier = nil, leere Puffer
        deactivate MLXClient

        Coord->>Coord: clearDetectedElementLocation()
        Coord-->>CursorView: detectedElementScreenLocation = nil
        activate CursorView
        CursorView->>CursorView: cancelNavigationAndResumeFollowing()
        CursorView->>CursorView: Timer invalidieren, Bounding-Box ausblenden, Drehung zurücksetzen
        deactivate CursorView

        Coord->>Coord: voiceState = .processing, processingStepText = "Mikrofon vorbereiten..."
        Coord->>Dict: startPushToTalkFromKeyboardShortcut(...)
        Note over Coord,Dict: Nahtloser Übergang in neue Aufnahme (Pipeline 1)
        deactivate Coord
    end

    %% Szenario 2: Ollama Ausfall
    rect rgb(255, 245, 245)
        Note over Coord,AppleTTS: Szenario B: Ollama Server-Fehler oder Verbindungsabbruch
        activate Coord
        Coord->>Coord: sendTranscriptToVisionModelWithScreenshot(...)
        Note over Coord: ollamaAPI.analyzeImageStreaming wirft Fehler (z.B. Connection Refused)
        Coord->>Coord: catch error (Ollama offline)
        Coord->>MLXClient: stopPlayback()
        Coord->>Coord: ClickyAnalytics.trackResponseError(error)
        Coord->>Coord: speakLocalErrorFallback("Ollama is not running or encountered an error...")
        Coord->>MLXClient: speakCompleteText(errorMessage, onFirstAudioStarted, onPlaybackFinished)
        activate MLXClient
        Note over MLXClient: Lokale Fehlermeldung wird gesprochen
        MLXClient-->>Coord: onPlaybackFinished()
        deactivate MLXClient
        Coord->>Coord: voiceState = .idle, scheduleTransientHideIfNeeded()
        deactivate Coord
    end

    %% Szenario 3: MLX Audio Ausfall -> Apple TTS Fallback
    rect rgb(255, 250, 240)
        Note over MLXClient,AppleTTS: Szenario C: mlx_audio.server schlägt fehl -> Apple TTS Fallback
        activate MLXClient
        MLXClient->>MLXClient: requestAudioDataFromServer wirft Fehler (HTTP 500 / Timeout)
        MLXClient->>MLXClient: handleSynthesisFailure(sentenceIndex, failedSentenceText)
        MLXClient->>MLXClient: isUsingFallbackProviderForCurrentSession = true
        MLXClient->>AppleTTS: beginSpeechSession(...)
        activate AppleTTS
        MLXClient->>AppleTTS: enqueueSentenceForSpeech(failedSentenceText)
        MLXClient->>AppleTTS: enqueueSentenceForSpeech(weitere verbleibende Sätze...)
        AppleTTS->>AppleTTS: AVSpeechSynthesizer.speak(AVSpeechUtterance)
        AppleTTS-->>MLXClient: onFirstAudioStarted() / onPlaybackFinished()
        deactivate AppleTTS
        deactivate MLXClient
    end
```

### Technische Erläuterung & Sicherheitsgarantien

1. **Barge-In Koordination**:
   - Durch das Zuweisen von `currentResponseTask = Task { ... }` in `CompanionCoordinator` kann die gesamte Generierungskette jederzeit via `currentResponseTask?.cancel()` cooperativ abgebrochen werden.
   - Alle Loops in `OllamaAPI`, `CompanionScreenCaptureUtility` und `SpeechSentenceSegmenter` prüfen regelmäßig `guard !Task.isCancelled else { return }`.
   - `MLXAudioQwenTTSClient.stopPlayback()` bricht laufende `URLSession`-Tasks über ein Dictionary ab (`activeSynthesisTasksByIndex`) und stoppt den `AVAudioPlayer` unmittelbar.
   - `BlueCursorView` invalidiert seinen `navigationAnimationTimer` und versetzt das System ohne Animationsartefakte zurück in den Modus `.followingCursor`.

2. **Mehrstufige Fallback-Strategie für Sprachausgabe (TTS)**:
   - **Stufe 1 (Lokal / High Quality)**: Qwen3-TTS via `mlx_audio.server` (0.6B / 1.7B Parameter, Apple Silicon Metal-optimiert).
   - **Stufe 2 (System-Fallback)**: Sollte der lokale MLX-Server abstürzen, nicht gestartet sein oder ein Satz-Timeout auftreten, schaltet `MLXAudioQwenTTSClient.handleSynthesisFailure` mitten in der Sitzung transparent auf `AppleTTSClient` (`AVSpeechSynthesizer`) um.
   - Der Benutzer erhält die Antwort unterbrechungsfrei über die native Systemstimme von macOS.

3. **Deterministisches Aufräumen (Resource Leak Prevention)**:
   - Alle `AVAudioEngine`-Taps, `CFMachPort`-Event-Taps, temporäre WAV-Dateien (`defer { removeItem(...) }`) und `Combine`-Subscriptions (`AnyCancellable`) sind an den App- und Session-Lebenszyklus gebunden, um Memory Leaks und verwaiste Audio-Ressourcen im System vollständig auszuschließen.
