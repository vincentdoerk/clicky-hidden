//
//  PointingParserTests.swift
//  leanring-buddyTests
//
//  Unit tests for PointingCoordinateParser and PointingParseResult:
//  normalized coordinates, screen numbers, bounding boxes, OCR keywords,
//  and graceful handling of malformed tags.
//

import CoreGraphics
import Foundation
import Testing
@testable import leanring_buddy

@Suite("PointingParser Tests")
struct PointingParserTests {

    // MARK: - Standard Coordinate Parsing Tests

    @Test func regularCoordinatesWithScreenAndLabelParseCorrectly() async throws {
        let response = "Klicke auf das Zahnrad oben rechts. [POINT:500,200:Zahnrad:screen1]"
        let parseResult = PointingCoordinateParser.parsePointingCoordinates(from: response)

        #expect(parseResult.spokenText == "Klicke auf das Zahnrad oben rechts.")
        #expect(parseResult.coordinate?.x == 500)
        #expect(parseResult.coordinate?.y == 200)
        #expect(parseResult.elementLabel == "Zahnrad")
        #expect(parseResult.screenNumber == 1)
        #expect(parseResult.size == nil)
    }

    @Test func coordinatesWithoutScreenDefaultToNilScreenNumber() async throws {
        let response = "Hier ist der rote Stop-Knopf. [POINT:120,45:Stop]"
        let parseResult = PointingCoordinateParser.parsePointingCoordinates(from: response)

        #expect(parseResult.spokenText == "Hier ist der rote Stop-Knopf.")
        #expect(parseResult.coordinate?.x == 120)
        #expect(parseResult.coordinate?.y == 45)
        #expect(parseResult.elementLabel == "Stop")
        #expect(parseResult.screenNumber == nil)
        #expect(parseResult.size == nil)
    }

    @Test func fullTagWithExplicitBoundingBoxSizeAndScreen() async throws {
        let response = "Hier ist das Terminal drüben auf dem zweiten Monitor. [POINT:450,300:120,40:terminal:screen2]"
        let parseResult = PointingCoordinateParser.parsePointingCoordinates(from: response)

        #expect(parseResult.spokenText == "Hier ist das Terminal drüben auf dem zweiten Monitor.")
        #expect(parseResult.coordinate?.x == 450)
        #expect(parseResult.coordinate?.y == 300)
        #expect(parseResult.size?.width == 120)
        #expect(parseResult.size?.height == 40)
        #expect(parseResult.elementLabel == "terminal")
        #expect(parseResult.screenNumber == 2)
    }

    @Test func combinedFourNumberCoordinateTokenParsesCenterAndSize() async throws {
        let response = "Hier befindet sich der Menüeintrag. [POINT:300,150,80,25:Menü:screen1]"
        let parseResult = PointingCoordinateParser.parsePointingCoordinates(from: response)

        #expect(parseResult.spokenText == "Hier befindet sich der Menüeintrag.")
        #expect(parseResult.coordinate?.x == 300)
        #expect(parseResult.coordinate?.y == 150)
        #expect(parseResult.size?.width == 80)
        #expect(parseResult.size?.height == 25)
        #expect(parseResult.elementLabel == "Menü")
        #expect(parseResult.screenNumber == 1)
    }

    @Test func pointNoneTagIndicatesNoTargetElement() async throws {
        let response = "Swift ist eine typsichere Programmiersprache für Apple-Plattformen. [POINT:none]"
        let parseResult = PointingCoordinateParser.parsePointingCoordinates(from: response)

        #expect(parseResult.spokenText == "Swift ist eine typsichere Programmiersprache für Apple-Plattformen.")
        #expect(parseResult.coordinate == nil)
        #expect(parseResult.size == nil)
        #expect(parseResult.elementLabel == "none")
        #expect(parseResult.screenNumber == nil)
    }

    @Test func plainTextWithoutAnyTagReturnsCleanResult() async throws {
        let responseWithoutTag = "Guten Tag, wie kann ich dir heute auf deinem Mac helfen?"
        let parseResult = PointingCoordinateParser.parsePointingCoordinates(from: responseWithoutTag)

        #expect(parseResult.spokenText == responseWithoutTag)
        #expect(parseResult.coordinate == nil)
        #expect(parseResult.size == nil)
        #expect(parseResult.elementLabel == nil)
        #expect(parseResult.screenNumber == nil)
    }

    // MARK: - Multi-Monitor Screen Number Parsing Tests

    @Test func screenNumberFormatsAreParsedCorrectly() async throws {
        let screenTestCases: [(tag: String, expectedScreen: Int)] = [
            ("[POINT:100,200:icon:screen1]", 1),
            ("[POINT:100,200:icon:screen2]", 2),
            ("[POINT:100,200:icon:screen 3]", 3),
            ("[POINT:100,200:icon:SCREEN4]", 4)
        ]

        for testCase in screenTestCases {
            let response = "Klicke hier. \(testCase.tag)"
            let parseResult = PointingCoordinateParser.parsePointingCoordinates(from: response)
            #expect(parseResult.screenNumber == testCase.expectedScreen)
        }
    }

    // MARK: - Candidate OCR Keywords Extraction Tests

    @Test func candidateKeywordsExtractionBuildsExpectedList() async throws {
        let keywords = PointingCoordinateParser.buildCandidateKeywords(label: "GitLab docs Logo")

        #expect(keywords.contains("GitLab docs Logo"))
        #expect(keywords.contains("GitLab"))
        #expect(keywords.contains("docs"))
        #expect(keywords.contains("Logo"))

        // De-duplication check: elements should be unique
        let uniqueKeywords = Set(keywords)
        #expect(keywords.count == uniqueKeywords.count)
    }

    @Test func candidateKeywordsWithNoneOrEmptyReturnsEmptyArray() async throws {
        #expect(PointingCoordinateParser.buildCandidateKeywords(label: "none").isEmpty)
        #expect(PointingCoordinateParser.buildCandidateKeywords(label: "NONE").isEmpty)
        #expect(PointingCoordinateParser.buildCandidateKeywords(label: nil).isEmpty)
        #expect(PointingCoordinateParser.buildCandidateKeywords(label: "   ").isEmpty)
    }

    @Test func candidateKeywordsIgnoresSingleCharacterWords() async throws {
        let keywords = PointingCoordinateParser.buildCandidateKeywords(label: "C und C++ Compiler")
        // "und" and "Compiler" are >= 2 chars; "C" is 1 char so excluded as individual word
        #expect(keywords.contains("C und C++ Compiler"))
        #expect(keywords.contains("und"))
        #expect(keywords.contains("Compiler"))
        #expect(!keywords.contains("C"))
    }

    // MARK: - Robust Fallback & Malformed Tag Tests

    @Test func malformedTagWithoutCoordinatesDoesNotCrashAndProvidesCleanFallback() async throws {
        let responseWithMalformedTag = "Klicke auf den Knopf. [POINT:not_a_coordinate:test]"
        let parseResult = PointingCoordinateParser.parsePointingCoordinates(from: responseWithMalformedTag)

        #expect(parseResult.spokenText == "Klicke auf den Knopf.")
        #expect(parseResult.coordinate == nil)
        #expect(parseResult.size == nil)
    }

    @Test func incompleteTagWithOnlyOneNumberDoesNotAssignCoordinate() async throws {
        let responseWithIncompleteCoordinate = "Hier ist etwas. [POINT:500:label]"
        let parseResult = PointingCoordinateParser.parsePointingCoordinates(from: responseWithIncompleteCoordinate)

        #expect(parseResult.spokenText == "Hier ist etwas.")
        #expect(parseResult.coordinate == nil)
    }

    @Test func unclosedBracketTagIsLeftIntactWithoutCrashing() async throws {
        let responseWithUnclosedTag = "Hier ist die Schaltfläche [POINT:500,200:unclosed tag"
        let parseResult = PointingCoordinateParser.parsePointingCoordinates(from: responseWithUnclosedTag)

        // Without closing bracket, regex won't match, full text is preserved as spokenText
        #expect(parseResult.spokenText == responseWithUnclosedTag)
        #expect(parseResult.coordinate == nil)
    }

    @Test func multipleTagsInResponseParsesLastMatch() async throws {
        let responseWithMultipleTags = "Erster Schritt [POINT:100,100:eins] und zweiter Schritt [POINT:800,400:zwei:screen2]"
        let parseResult = PointingCoordinateParser.parsePointingCoordinates(from: responseWithMultipleTags)

        #expect(parseResult.coordinate?.x == 800)
        #expect(parseResult.coordinate?.y == 400)
        #expect(parseResult.elementLabel == "zwei")
        #expect(parseResult.screenNumber == 2)
    }

    @Test func convenienceHelperOnPointingParseResultDelegatesCorrectly() async throws {
        let response = "Klicke hier. [POINT:100,200:icon]"
        let parseResult = PointingParseResult.parse(from: response)

        #expect(parseResult.spokenText == "Klicke hier.")
        #expect(parseResult.coordinate?.x == 100)
        #expect(parseResult.coordinate?.y == 200)
        #expect(parseResult.elementLabel == "icon")
    }
}
