//
//  SpeechSentenceSegmenterTests.swift
//  leanring-buddyTests
//
//  Unit tests for SpeechSentenceSegmenter: streaming chunks buffering,
//  German abbreviations preservation, tag stripping, and sentence flushing.
//

import Foundation
import Testing
@testable import leanring_buddy

@Suite("SpeechSentenceSegmenter Tests")
struct SpeechSentenceSegmenterTests {

    // MARK: - Streaming Chunks Buffering & Boundary Tests

    @Test func streamingChunksBufferingAcrossTokenBoundaries() async throws {
        let sentenceSegmenter = SpeechSentenceSegmenter()

        // Token 1: Incomplete fragment
        let chunk1 = "Klicke "
        let sentencesFromChunk1 = sentenceSegmenter.appendAccumulatedResponseText(chunk1)
        #expect(sentencesFromChunk1.isEmpty)

        // Token 2: Still incomplete sentence
        let chunk2 = chunk1 + "oben rechts "
        let sentencesFromChunk2 = sentenceSegmenter.appendAccumulatedResponseText(chunk2)
        #expect(sentencesFromChunk2.isEmpty)

        // Token 3: Completes the first sentence with trailing whitespace
        let chunk3 = chunk2 + "auf das Zahnrad. "
        let sentencesFromChunk3 = sentenceSegmenter.appendAccumulatedResponseText(chunk3)
        #expect(sentencesFromChunk3 == ["Klicke oben rechts auf das Zahnrad."])

        // Token 4: Begins second sentence
        let chunk4 = chunk3 + "Dann öffnen "
        let sentencesFromChunk4 = sentenceSegmenter.appendAccumulatedResponseText(chunk4)
        #expect(sentencesFromChunk4.isEmpty)

        // Token 5: Completes second sentence
        let chunk5 = chunk4 + "sich die Einstellungen. "
        let sentencesFromChunk5 = sentenceSegmenter.appendAccumulatedResponseText(chunk5)
        #expect(sentencesFromChunk5 == ["Dann öffnen sich die Einstellungen."])
    }

    @Test func punctuationAtEndOfChunkWaitsForNextChunkBeforeSplitting() async throws {
        let sentenceSegmenter = SpeechSentenceSegmenter()

        // When a period arrives at the very end of a chunk without trailing space,
        // it must wait to see if the next chunk continues it (e.g. "3." followed by "5").
        let chunkWithTerminalPeriodAtEnd = "Dies ist ein vollständiger Test."
        let sentencesBeforeNextChunk = sentenceSegmenter.appendAccumulatedResponseText(chunkWithTerminalPeriodAtEnd)
        #expect(sentencesBeforeNextChunk.isEmpty)

        // Once the subsequent chunk introduces whitespace, the boundary is confirmed
        let chunkWithFollowingSentence = chunkWithTerminalPeriodAtEnd + " Und hier folgt der zweite Satz."
        let sentencesAfterNextChunk = sentenceSegmenter.appendAccumulatedResponseText(chunkWithFollowingSentence)
        #expect(sentencesAfterNextChunk == ["Dies ist ein vollständiger Test."])

        let flushedSentences = sentenceSegmenter.flushRemainingSentences()
        #expect(flushedSentences == ["Und hier folgt der zweite Satz."])
    }

    // MARK: - German Abbreviations Preservation Tests

    @Test func germanAbbreviationsPreserveSentenceIntegrityWithoutFalseSplits() async throws {
        let textWithCommonGermanAbbreviations = "Klicke z. B. auf die Datei und warte ca. 5 Sekunden. Danach ist alles fertig."
        let extractedSentences = SpeechSentenceSegmenter.splitCompleteTextIntoSentences(textWithCommonGermanAbbreviations)

        #expect(extractedSentences.count == 2)
        #expect(extractedSentences.first == "Klicke z. B. auf die Datei und warte ca. 5 Sekunden.")
        #expect(extractedSentences.last == "Danach ist alles fertig.")
    }

    @Test func variousGermanAbbreviationsDoNotTriggerSentenceTerminators() async throws {
        let abbreviationTestCases = [
            ("Dr. Schmidt hat die Datei geöffnet. Bitte prüfe das.", 2),
            ("Wir benötigen bzw. aktualisieren die Daten. Bitte bestätigen.", 2),
            ("Es gibt Optionen wie Name, Alter usw. in der Tabelle. Sieh es dir an.", 2),
            ("Das Dokument ist d. h. vollständig importiert. Alles ist bereit.", 2),
            ("Siehe u. a. die Hinweise im Handbuch. Folge den Schritten.", 2)
        ]

        for (testText, expectedSentenceCount) in abbreviationTestCases {
            let sentences = SpeechSentenceSegmenter.splitCompleteTextIntoSentences(testText)
            #expect(
                sentences.count == expectedSentenceCount,
                "Expected \(expectedSentenceCount) sentences for: '\(testText)', but got: \(sentences)"
            )
        }
    }

    // MARK: - POINT Tag Stripping Tests

    @Test func pointTagsAreCompletelyStrippedFromEmittedSentences() async throws {
        let sentenceSegmenter = SpeechSentenceSegmenter()

        let chunk1 = "Klicke hier auf den Button. [POINT:500,200:zahnrad:screen1] "
        let sentences1 = sentenceSegmenter.appendAccumulatedResponseText(chunk1)
        #expect(sentences1 == ["Klicke hier auf den Button."])

        let chunk2 = chunk1 + "Das Fenster öffnet sich sofort. [POINT:none]"
        let sentences2 = sentenceSegmenter.appendAccumulatedResponseText(chunk2)
        let flushedSentences = sentenceSegmenter.flushRemainingSentences()

        let combinedSentences = sentences2 + flushedSentences
        #expect(combinedSentences == ["Das Fenster öffnet sich sofort."])
    }

    @Test func pointTagSpanningAcrossStreamingChunkBoundariesIsStrippedCleanly() async throws {
        let sentenceSegmenter = SpeechSentenceSegmenter()

        // Chunk 1 contains complete sentence plus opening of POINT tag
        let chunk1 = "Klicke auf das Terminal. [POINT:450,"
        let sentences1 = sentenceSegmenter.appendAccumulatedResponseText(chunk1)
        #expect(sentences1 == ["Klicke auf das Terminal."])

        // Chunk 2 finishes the POINT tag and adds a second sentence
        let chunk2 = chunk1 + "300:120,40:terminal:screen2] Jetzt tippe den Befehl ein. "
        let sentences2 = sentenceSegmenter.appendAccumulatedResponseText(chunk2)
        #expect(sentences2 == ["Jetzt tippe den Befehl ein."])

        let flushed = sentenceSegmenter.flushRemainingSentences()
        #expect(flushed.isEmpty)
    }

    @Test func markdownSymbolsAreStrippedFromSpeakableSentences() async throws {
        let textWithMarkdown = "Wähle **Einstellungen** im Menü und klicke auf `#Speichern`. Danach bist du fertig."
        let extractedSentences = SpeechSentenceSegmenter.splitCompleteTextIntoSentences(textWithMarkdown)

        #expect(extractedSentences.count == 2)
        #expect(extractedSentences.first == "Wähle Einstellungen im Menü und klicke auf Speichern.")
        #expect(extractedSentences.last == "Danach bist du fertig.")
    }

    // MARK: - Flushing & Short Sentence Handling Tests

    @Test func flushRemainingSentencesFlushesTextWithoutTrailingPeriod() async throws {
        let sentenceSegmenter = SpeechSentenceSegmenter()

        let chunkWithoutTrailingPeriod = "Dies ist ein wichtiger Hinweis ohne Satzzeichen am Ende"
        let sentencesFromAppend = sentenceSegmenter.appendAccumulatedResponseText(chunkWithoutTrailingPeriod)
        #expect(sentencesFromAppend.isEmpty)

        let flushedSentences = sentenceSegmenter.flushRemainingSentences()
        #expect(flushedSentences == ["Dies ist ein wichtiger Hinweis ohne Satzzeichen am Ende"])
    }

    @Test func shortSentencesAreHeldBackAndMergedWithSubsequentSentences() async throws {
        let sentenceSegmenter = SpeechSentenceSegmenter()

        // "Ja." has length 3, below minimumSentenceCharacterCount (12)
        let chunk1 = "Ja. "
        let sentencesFromChunk1 = sentenceSegmenter.appendAccumulatedResponseText(chunk1)
        #expect(sentencesFromChunk1.isEmpty)

        // Subsequent sentence gets merged with held-back short sentence
        let chunk2 = chunk1 + "Das ist genau die richtige Einstellung für deinen Mac. "
        let sentencesFromChunk2 = sentenceSegmenter.appendAccumulatedResponseText(chunk2)
        #expect(sentencesFromChunk2 == ["Ja. Das ist genau die richtige Einstellung für deinen Mac."])
    }

    @Test func heldBackShortSentenceIsFlushedIfNoSubsequentSentenceArrives() async throws {
        let sentenceSegmenter = SpeechSentenceSegmenter()

        let shortChunk = "Genau. "
        let sentencesFromAppend = sentenceSegmenter.appendAccumulatedResponseText(shortChunk)
        #expect(sentencesFromAppend.isEmpty)

        let flushedSentences = sentenceSegmenter.flushRemainingSentences()
        #expect(flushedSentences == ["Genau."])
    }

    @Test func emptyOrWhitespaceOnlyInputsProduceNoSentences() async throws {
        let emptySentences = SpeechSentenceSegmenter.splitCompleteTextIntoSentences("")
        #expect(emptySentences.isEmpty)

        let whitespaceSentences = SpeechSentenceSegmenter.splitCompleteTextIntoSentences("   \n\t   ")
        #expect(whitespaceSentences.isEmpty)
    }
}
