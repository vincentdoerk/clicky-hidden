//
//  SpeechSentenceSegmenter.swift
//  leanring-buddy
//
//  Splits streamed LLM response text into complete, speakable sentences so
//  text-to-speech can start talking while the model is still generating.
//  Bracketed tags like [POINT:...] are removed because they are control
//  data for the cursor overlay, not something that should be read aloud.
//

import Foundation

final class SpeechSentenceSegmenter {
    /// Sentences shorter than this are merged with the following sentence.
    /// Very short fragments ("ok.", "ja!") sound choppy when synthesized as
    /// separate requests and add per-request latency without benefit.
    private let minimumSentenceCharacterCount = 12

    /// If a run-on sentence grows beyond this length without a sentence
    /// terminator, it gets split at the last comma so speech can start
    /// without waiting for the whole paragraph.
    private let maximumPendingCharacterCountBeforeCommaSplit = 220

    /// Common German and English abbreviations that end with a period but do
    /// not end a sentence. Compared lowercased and without the trailing period.
    private static let abbreviationsThatDoNotEndSentences: Set<String> = [
        "z", "b", "d", "h", "u", "a", "s", "o", "e", "i", "ca", "bzw", "usw", "etc",
        "evtl", "ggf", "inkl", "exkl", "nr", "dr", "prof", "hr", "fr", "vgl", "bspw",
        "mio", "mrd", "max", "min", "sek", "std", "mr", "mrs", "ms", "vs", "e.g", "i.e",
        "z.b", "d.h", "u.a", "o.ä", "s.o", "s.u"
    ]

    private static let sentenceTerminatorCharacters: Set<Character> = [".", "!", "?", "…"]

    /// Characters that can follow a terminator but still belong to the same
    /// sentence, e.g. the closing quote in `er sagte "hallo."`.
    private static let trailingClosingCharacters: Set<Character> = ["\"", "'", "”", "’", "»", "«", ")"]

    /// Markdown symbols that some models emit despite the system prompt and
    /// that would otherwise be read aloud as "Sternchen" or produce noise.
    private static let markdownSymbolsToRemove: Set<Character> = ["*", "#", "`"]

    /// How many unicode scalars of the accumulated response text were already processed.
    private var processedAccumulatedTextScalarCount = 0

    /// Speakable text that has been received but not yet emitted as a sentence.
    private var pendingSpeakableText = ""

    /// True while the incoming text is inside a `[...]` tag that must not be spoken.
    private var isInsideBracketedTag = false

    /// A sentence that was too short to emit on its own, waiting to be merged
    /// with the next sentence.
    private var heldBackShortSentence: String?

    // MARK: - Streaming API

    /// Feed the full accumulated response text received so far (as delivered
    /// by `OllamaAPI.analyzeImageStreaming`). Only the newly appended part is
    /// processed. Returns all sentences that became complete with this update.
    func appendAccumulatedResponseText(_ accumulatedResponseText: String) -> [String] {
        let accumulatedTextScalars = accumulatedResponseText.unicodeScalars
        guard accumulatedTextScalars.count > processedAccumulatedTextScalarCount else {
            return []
        }

        let newlyAppendedScalars = accumulatedTextScalars.dropFirst(processedAccumulatedTextScalarCount)
        processedAccumulatedTextScalarCount = accumulatedTextScalars.count
        appendNewTextRemovingBracketedTags(String(String.UnicodeScalarView(newlyAppendedScalars)))

        return extractCompleteSentencesFromPendingText()
    }

    /// Call once the response stream has finished. Returns whatever text is
    /// still pending (including a held-back short sentence) as final sentences.
    func flushRemainingSentences() -> [String] {
        var finalSentences = extractCompleteSentencesFromPendingText()

        let remainingText = Self.normalizeWhitespace(pendingSpeakableText)
        pendingSpeakableText = ""

        let combinedRemainingText = [heldBackShortSentence, remainingText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        heldBackShortSentence = nil

        if !combinedRemainingText.isEmpty {
            finalSentences.append(combinedRemainingText)
        }

        return finalSentences
    }

    // MARK: - One-Shot API

    /// Splits an already complete text into speakable sentences.
    static func splitCompleteTextIntoSentences(_ completeText: String) -> [String] {
        let sentenceSegmenter = SpeechSentenceSegmenter()
        let sentencesFromStreaming = sentenceSegmenter.appendAccumulatedResponseText(completeText)
        return sentencesFromStreaming + sentenceSegmenter.flushRemainingSentences()
    }

    // MARK: - Internals

    private func appendNewTextRemovingBracketedTags(_ newText: String) {
        for character in newText {
            if isInsideBracketedTag {
                if character == "]" {
                    isInsideBracketedTag = false
                }
                continue
            }

            if character == "[" {
                isInsideBracketedTag = true
                continue
            }

            if Self.markdownSymbolsToRemove.contains(character) {
                continue
            }

            pendingSpeakableText.append(character)
        }
    }

    /// Scans the pending text for sentence boundaries and returns every
    /// complete sentence. Text after the last boundary stays pending.
    private func extractCompleteSentencesFromPendingText() -> [String] {
        var completeSentences: [String] = []

        while let sentenceEndIndex = findFirstSentenceEndIndex(in: pendingSpeakableText) {
            let rawSentence = String(pendingSpeakableText[..<sentenceEndIndex])
            pendingSpeakableText = String(pendingSpeakableText[sentenceEndIndex...])

            if let sentenceReadyToEmit = mergeWithHeldBackShortSentence(Self.normalizeWhitespace(rawSentence)) {
                completeSentences.append(sentenceReadyToEmit)
            }
        }

        if let commaSplitSentence = splitOverlyLongPendingTextAtLastComma(),
           let sentenceReadyToEmit = mergeWithHeldBackShortSentence(commaSplitSentence) {
            completeSentences.append(sentenceReadyToEmit)
        }

        return completeSentences
    }

    /// Returns the index directly after a sentence terminator (and any closing
    /// quotes) if that terminator is followed by whitespace. A terminator at the
    /// very end of the pending text is not treated as a boundary yet, because
    /// the next chunk might continue it (e.g. "3." followed by "5 sekunden").
    private func findFirstSentenceEndIndex(in text: String) -> String.Index? {
        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            let currentCharacter = text[currentIndex]

            if currentCharacter == "\n" {
                let textBeforeNewline = text[..<currentIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                if !textBeforeNewline.isEmpty {
                    return text.index(after: currentIndex)
                }
            }

            if Self.sentenceTerminatorCharacters.contains(currentCharacter) {
                // Consume repeated terminators ("?!", "...") and closing quotes.
                var indexAfterTerminator = text.index(after: currentIndex)
                while indexAfterTerminator < text.endIndex,
                      Self.sentenceTerminatorCharacters.contains(text[indexAfterTerminator])
                        || Self.trailingClosingCharacters.contains(text[indexAfterTerminator]) {
                    indexAfterTerminator = text.index(after: indexAfterTerminator)
                }

                guard indexAfterTerminator < text.endIndex else {
                    // Terminator is at the end of the received text — wait for more.
                    return nil
                }

                let characterAfterTerminator = text[indexAfterTerminator]
                let isFollowedByWhitespace = characterAfterTerminator.isWhitespace
                let isPeriodOfAbbreviationOrNumber = currentCharacter == "."
                    && isPeriodPartOfAbbreviationOrNumber(in: text, periodIndex: currentIndex)

                if isFollowedByWhitespace && !isPeriodOfAbbreviationOrNumber {
                    return indexAfterTerminator
                }

                currentIndex = indexAfterTerminator
                continue
            }

            currentIndex = text.index(after: currentIndex)
        }

        return nil
    }

    /// True if the word directly before the period is a known abbreviation
    /// (like "z.B." or "ca.") or a number (like German ordinals "1.").
    private func isPeriodPartOfAbbreviationOrNumber(in text: String, periodIndex: String.Index) -> Bool {
        var wordStartIndex = periodIndex
        while wordStartIndex > text.startIndex {
            let previousIndex = text.index(before: wordStartIndex)
            if text[previousIndex].isWhitespace {
                break
            }
            wordStartIndex = previousIndex
        }

        let wordBeforePeriod = String(text[wordStartIndex..<periodIndex])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'(«»“”„"))
            .lowercased()

        guard !wordBeforePeriod.isEmpty else { return false }

        if wordBeforePeriod.allSatisfy(\.isNumber) {
            return true
        }

        return Self.abbreviationsThatDoNotEndSentences.contains(wordBeforePeriod)
    }

    /// Splits a very long pending run-on sentence at its last comma so the
    /// first part can already be spoken.
    private func splitOverlyLongPendingTextAtLastComma() -> String? {
        guard pendingSpeakableText.count > maximumPendingCharacterCountBeforeCommaSplit,
              let lastCommaRange = pendingSpeakableText.range(of: ",", options: .backwards) else {
            return nil
        }

        let textUpToAndIncludingComma = String(pendingSpeakableText[..<lastCommaRange.upperBound])
        guard textUpToAndIncludingComma.count >= minimumSentenceCharacterCount else {
            return nil
        }

        pendingSpeakableText = String(pendingSpeakableText[lastCommaRange.upperBound...])
        return Self.normalizeWhitespace(textUpToAndIncludingComma)
    }

    /// Combines a new sentence with a previously held-back short sentence.
    /// Returns nil if the combined text is still too short and is held back.
    private func mergeWithHeldBackShortSentence(_ newSentence: String) -> String? {
        let combinedSentence = [heldBackShortSentence, newSentence]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !combinedSentence.isEmpty else { return nil }

        if combinedSentence.count < minimumSentenceCharacterCount {
            heldBackShortSentence = combinedSentence
            return nil
        }

        heldBackShortSentence = nil
        return combinedSentence
    }

    /// Collapses newlines and repeated spaces into single spaces and trims.
    private static func normalizeWhitespace(_ text: String) -> String {
        return text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
