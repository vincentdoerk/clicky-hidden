//
//  PointingDetection.swift
//  leanring-buddy
//
//  Models and parsing logic for vision model element pointing tags.
//

import CoreGraphics
import Foundation

/// Result of parsing a [POINT:...] tag from the model's response.
public struct PointingParseResult: Equatable, Sendable {
    /// The response text with the [POINT:...] tag removed — this is what gets spoken.
    public let spokenText: String
    /// The parsed center coordinate (normalized 0..1000), or nil if none found.
    public let coordinate: CGPoint?
    /// The parsed bounding box size (normalized 0..1000), or nil if not provided.
    public let size: CGSize?
    /// Short label describing the element (e.g. "gitlab logo"), or nil.
    public let elementLabel: String?
    /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
    public let screenNumber: Int?

    public init(
        spokenText: String,
        coordinate: CGPoint? = nil,
        size: CGSize? = nil,
        elementLabel: String? = nil,
        screenNumber: Int? = nil
    ) {
        self.spokenText = spokenText
        self.coordinate = coordinate
        self.size = size
        self.elementLabel = elementLabel
        self.screenNumber = screenNumber
    }
}

extension PointingParseResult {
    /// Convenience parser helper delegating to `PointingCoordinateParser`.
    public static func parse(from responseText: String) -> PointingParseResult {
        PointingCoordinateParser.parsePointingCoordinates(from: responseText)
    }
}

/// Parser for vision model [POINT:...] coordinate tags.
public enum PointingCoordinateParser {
    /// Parses a [POINT:x,y:w,h:label:screenN] or [POINT:x,y:label] or [POINT:none] tag from the model's response.
    /// Returns the spoken text (tag removed) along with coordinates, optional bounding box size, label, and screen number.
    public static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        let tagPattern = #"\[POINT\s*:\s*([^\]\n]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: tagPattern, options: [.caseInsensitive]) else {
            return PointingParseResult(spokenText: responseText, coordinate: nil, size: nil, elementLabel: nil, screenNumber: nil)
        }

        let fullRange = NSRange(responseText.startIndex..., in: responseText)
        let matches = regex.matches(in: responseText, options: [], range: fullRange)

        guard let lastMatch = matches.last,
              let fullMatchRange = Range(lastMatch.range, in: responseText),
              let innerMatchRange = Range(lastMatch.range(at: 1), in: responseText) else {
            return PointingParseResult(spokenText: responseText, coordinate: nil, size: nil, elementLabel: nil, screenNumber: nil)
        }

        var cleanSpokenText = responseText
        cleanSpokenText.removeSubrange(fullMatchRange)
        cleanSpokenText = cleanSpokenText.trimmingCharacters(in: .whitespacesAndNewlines)

        let innerTag = String(responseText[innerMatchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        if innerTag.lowercased() == "none" {
            return PointingParseResult(spokenText: cleanSpokenText, coordinate: nil, size: nil, elementLabel: "none", screenNumber: nil)
        }

        let tokens = innerTag.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !tokens.isEmpty else {
            return PointingParseResult(spokenText: cleanSpokenText, coordinate: nil, size: nil, elementLabel: nil, screenNumber: nil)
        }

        var parsedCoordinate: CGPoint? = nil
        var parsedSize: CGSize? = nil
        var parsedLabel: String? = nil
        var parsedScreenNumber: Int? = nil

        var remainingTokens = tokens

        func extractNumbers(from string: String) -> [Double] {
            string.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "x" })
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }

        // Check if token 0 has 2 or 4 numbers (e.g. "x,y" or "x,y,w,h")
        if !remainingTokens.isEmpty {
            let nums = extractNumbers(from: remainingTokens[0])
            if nums.count >= 4 {
                parsedCoordinate = CGPoint(x: nums[0], y: nums[1])
                parsedSize = CGSize(width: nums[2], height: nums[3])
                remainingTokens.removeFirst()
            } else if nums.count >= 2 {
                parsedCoordinate = CGPoint(x: nums[0], y: nums[1])
                remainingTokens.removeFirst()
            }
        }

        // Check if token 1 provides w,h size (e.g. "115,36")
        if parsedSize == nil && !remainingTokens.isEmpty {
            let nums = extractNumbers(from: remainingTokens[0])
            if nums.count >= 2 {
                parsedSize = CGSize(width: nums[0], height: nums[1])
                remainingTokens.removeFirst()
            }
        }

        // Check remaining tokens for screen number and label
        for token in remainingTokens {
            let lower = token.lowercased()
            if let screenMatch = lower.range(of: #"^screen\s*(\d+)$"#, options: [.regularExpression]) {
                let digits = lower[screenMatch].filter(\.isNumber)
                if let num = Int(digits) {
                    parsedScreenNumber = num
                }
            } else if !token.isEmpty {
                if parsedLabel == nil {
                    parsedLabel = token
                } else {
                    parsedLabel = (parsedLabel ?? "") + " " + token
                }
            }
        }

        return PointingParseResult(
            spokenText: cleanSpokenText,
            coordinate: parsedCoordinate,
            size: parsedSize,
            elementLabel: parsedLabel,
            screenNumber: parsedScreenNumber
        )
    }

    /// Extracts candidate keywords from the element label to search for via Apple Vision OCR.
    /// Stray words from the user's transcript are excluded so unrelated text on screen
    /// cannot hijack pointing away from the target element.
    public static func buildCandidateKeywords(label: String?) -> [String] {
        var candidates: [String] = []

        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty,
              label.lowercased() != "none" else {
            return []
        }

        candidates.append(label)
        let words = label.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        candidates.append(contentsOf: words)

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.lowercased()).inserted }
    }
}
