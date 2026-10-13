//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit
import Vision

/// Result of matching a UI text element in the screenshot via Apple Vision OCR.
struct ScreenTextMatch {
    let text: String
    let globalRect: CGRect
    let globalCenter: CGPoint
}

struct CompanionScreenCapture {
    let imageData: Data
    let cgImage: CGImage?
    let label: String
    let isCursorScreen: Bool
    let cursorLocationOnScreen: CGPoint?
    let globalCursorLocationAtCapture: CGPoint
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Captures all connected displays as JPEG data in a deterministic left-to-right order,
    /// recording the exact cursor location at the moment of capture.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocationAtCapture = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin).
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Deterministic sorting from left to right (origin.x) so screen 1 and screen 2
        // maintain stable identities regardless of where the cursor moves.
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            if frameA.origin.x != frameB.origin.x {
                return frameA.origin.x < frameB.origin.x
            }
            return frameA.origin.y < frameB.origin.y
        }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocationAtCapture)
            let cursorLocationOnScreen: CGPoint?
            if isCursorScreen {
                cursorLocationOnScreen = CGPoint(
                    x: mouseLocationAtCapture.x - displayFrame.origin.x,
                    y: mouseLocationAtCapture.y - displayFrame.origin.y
                )
            } else {
                cursorLocationOnScreen = nil
            }

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            // Always capture at the display's native resolution (e.g. 2560x1440 for 2K displays)
            // so pixel coordinates and Vision OCR text bounds match 1:1 with the actual monitor.
            configuration.width = max(1, display.width)
            configuration.height = max(1, display.height)

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
                continue
            }

            let screenLabel: String
            if sortedDisplays.count == 1 {
                if let localCursor = cursorLocationOnScreen {
                    let normCursorX = Int((localCursor.x / max(1.0, displayFrame.width)) * 1000)
                    let visionY = max(0.0, displayFrame.height - localCursor.y)
                    let normCursorY = Int((visionY / max(1.0, displayFrame.height)) * 1000)
                    screenLabel = "screen 1 — user's cursor is currently at [\(normCursorX),\(normCursorY)]"
                } else {
                    screenLabel = "screen 1"
                }
            } else if isCursorScreen, let localCursor = cursorLocationOnScreen {
                let normCursorX = Int((localCursor.x / max(1.0, displayFrame.width)) * 1000)
                let visionY = max(0.0, displayFrame.height - localCursor.y)
                let normCursorY = Int((visionY / max(1.0, displayFrame.height)) * 1000)
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — user's cursor is currently at [\(normCursorX),\(normCursorY)] on this screen"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count)"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                cgImage: cgImage,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                cursorLocationOnScreen: cursorLocationOnScreen,
                globalCursorLocationAtCapture: mouseLocationAtCapture,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: cgImage.width,
                screenshotHeightInPixels: cgImage.height
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }

    /// Uses Apple's local Vision framework (VNRecognizeTextRequest) to find the exact bounding
    /// box of a UI text element near the estimated location returned by the vision model.
    /// If a match is found, returns the pixel-precise location and bounding box; otherwise nil.
    static func snapToMatchingTextElement(
        primaryTargetLabel: String?,
        candidateKeywords: [String],
        near estimatedGlobalLocation: CGPoint,
        targetScreenCapture: CompanionScreenCapture
    ) -> ScreenTextMatch? {
        guard let cgImage = targetScreenCapture.cgImage else { return nil }

        let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
        let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
        let displayOrigin = targetScreenCapture.displayFrame.origin

        // Normalized location of estimate in AppKit coordinates (bottom-left origin)
        let localEstimatedX = (estimatedGlobalLocation.x - displayOrigin.x) / displayWidth
        let localEstimatedY = (estimatedGlobalLocation.y - displayOrigin.y) / displayHeight

        // Define Region of Interest (ROI) around estimated location (+-20% horizontal, +-20% vertical)
        let halfSpanX: CGFloat = 0.20
        let halfSpanY: CGFloat = 0.20
        let roiMinX = max(0.0, localEstimatedX - halfSpanX)
        let roiMaxX = min(1.0, localEstimatedX + halfSpanX)
        let roiMinY = max(0.0, localEstimatedY - halfSpanY)
        let roiMaxY = min(1.0, localEstimatedY + halfSpanY)
        let roi = CGRect(x: roiMinX, y: roiMinY, width: max(0.05, roiMaxX - roiMinX), height: max(0.05, roiMaxY - roiMinY))

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.regionOfInterest = roi

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results, !observations.isEmpty else { return nil }

        // Prepare normalized target phrase and words
        let rawTarget = primaryTargetLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedPrimaryTarget = normalizeTextForComparison(rawTarget)
        let primaryTargetWords = normalizedPrimaryTarget.components(separatedBy: " ").filter { $0.count >= 2 }

        // Clean candidate keywords (remove punctuation, lowercased, length >= 2)
        let cleanKeywords = candidateKeywords
            .map { normalizeTextForComparison($0) }
            .filter { $0.count >= 2 }

        guard !normalizedPrimaryTarget.isEmpty || !cleanKeywords.isEmpty else { return nil }

        var bestMatch: ScreenTextMatch? = nil
        var bestScore: Double = 0.0
        var bestMatchType: String = "none"
        var closestDistance: CGFloat = CGFloat.greatestFiniteMagnitude

        for observation in observations {
            guard let topCandidate = observation.topCandidates(1).first else { continue }
            let recognizedText = topCandidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !recognizedText.isEmpty else { continue }

            let normalizedObserved = normalizeTextForComparison(recognizedText)
            let observedWords = normalizedObserved.components(separatedBy: " ").filter { !$0.isEmpty }
            guard !observedWords.isEmpty else { continue }

            // Calculate global AppKit frame from ROI-relative observation box
            let roiBox = observation.boundingBox
            let normX = roi.origin.x + (roiBox.origin.x * roi.width)
            let normY = roi.origin.y + (roiBox.origin.y * roi.height)
            let normW = roiBox.width * roi.width
            let normH = roiBox.height * roi.height

            let elementDisplayX = normX * displayWidth
            let elementDisplayY = normY * displayHeight
            let elementWidth = normW * displayWidth
            let elementHeight = normH * displayHeight

            // Add comfortable padding around recognized text so the bounding box frames the full button/row
            let paddedWidth = max(elementWidth + 18.0, 75.0)
            let paddedHeight = max(elementHeight + 8.0, 28.0)
            let paddedDisplayX = max(0.0, elementDisplayX - 8.0)
            let paddedDisplayY = max(0.0, elementDisplayY - 4.0)

            let globalRect = CGRect(
                x: paddedDisplayX + displayOrigin.x,
                y: paddedDisplayY + displayOrigin.y,
                width: paddedWidth,
                height: paddedHeight
            )
            let globalCenter = CGPoint(x: globalRect.midX, y: globalRect.midY)

            // Clamped distances to the bounding box:
            let horizontalDistanceToBox: CGFloat
            if estimatedGlobalLocation.x < globalRect.minX {
                horizontalDistanceToBox = globalRect.minX - estimatedGlobalLocation.x
            } else if estimatedGlobalLocation.x > globalRect.maxX {
                horizontalDistanceToBox = estimatedGlobalLocation.x - globalRect.maxX
            } else {
                horizontalDistanceToBox = 0.0
            }

            let verticalDistanceToBox: CGFloat
            if estimatedGlobalLocation.y < globalRect.minY {
                verticalDistanceToBox = globalRect.minY - estimatedGlobalLocation.y
            } else if estimatedGlobalLocation.y > globalRect.maxY {
                verticalDistanceToBox = estimatedGlobalLocation.y - globalRect.maxY
            } else {
                verticalDistanceToBox = 0.0
            }

            // In GUI layouts (especially lists, sidebars, menus), items are stacked vertically.
            // A vertical difference of 30pt is a completely different item/row!
            // A horizontal difference is often just clicking further along the row or button.
            // Therefore, heavily penalize vertical distance compared to horizontal distance.
            let effectiveDistance = sqrt(pow(horizontalDistanceToBox * 0.5, 2) + pow(verticalDistanceToBox * 3.0, 2))

            // Strictly enforce maximum snapping radius: OCR text snapping is strictly intended
            // for local fine-tuning of an element the AI already pointed at. Any candidate further
            // than 140 points horizontally or 70 points vertically belongs to a different UI region
            // (e.g. menu bar or distant toolbars) and must NEVER hijack pointing!
            guard horizontalDistanceToBox <= 140.0 && verticalDistanceToBox <= 70.0 else {
                continue
            }
            guard effectiveDistance <= 120.0 else {
                continue
            }

            // Score match quality
            var textMatchScore: Double = 0.0
            var currentMatchType: String = "none"

            // 1. PRIMARY TARGET MATCHING (e.g. from Ollama's label: "dance playlist")
            if !normalizedPrimaryTarget.isEmpty {
                if normalizedObserved == normalizedPrimaryTarget {
                    // Exact full match (e.g. "Dance • Playlist" normalized equals "dance playlist")
                    textMatchScore = 10000.0
                    currentMatchType = "exact-full"
                } else if normalizedObserved.hasPrefix(normalizedPrimaryTarget + " ") {
                    // Starts with target phrase
                    textMatchScore = 8000.0
                    currentMatchType = "starts-with-target"
                } else if normalizedObserved.contains(normalizedPrimaryTarget) {
                    // Contains target phrase
                    textMatchScore = 6500.0
                    currentMatchType = "contains-target"
                } else if !primaryTargetWords.isEmpty {
                    // Token-based matching against primary target words
                    var matchedWordsCount = 0
                    for targetWord in primaryTargetWords {
                        if observedWords.contains(where: { areWordsEquivalentOrStems($0, targetWord) }) {
                            matchedWordsCount += 1
                        }
                    }

                    let coverage = Double(matchedWordsCount) / Double(primaryTargetWords.count)
                    if coverage > 0.0 {
                        var tokenScore = coverage * 4000.0

                        // Starts-with bonus: if first word matches
                        if let firstTarget = primaryTargetWords.first,
                           let firstObserved = observedWords.first,
                           areWordsEquivalentOrStems(firstObserved, firstTarget) {
                            tokenScore += 1500.0
                        }

                        // Precision / noise ratio
                        let precision = Double(matchedWordsCount) / Double(observedWords.count)
                        tokenScore += precision * 800.0

                        if tokenScore > textMatchScore {
                            textMatchScore = tokenScore
                            currentMatchType = "token-coverage(\(matchedWordsCount)/\(primaryTargetWords.count))"
                        }
                    }
                }
            }

            // 2. SECONDARY KEYWORD MATCHING (strictly local within 80pt)
            if textMatchScore < 3000.0 && effectiveDistance <= 80.0 {
                for keyword in cleanKeywords {
                    if keyword.isEmpty { continue }
                    if normalizedObserved == keyword {
                        let score = 3500.0
                        if score > textMatchScore {
                            textMatchScore = score
                            currentMatchType = "keyword-exact(\(keyword))"
                        }
                    } else if let firstObserved = observedWords.first, areWordsEquivalentOrStems(firstObserved, keyword) {
                        let score = 2500.0
                        if score > textMatchScore {
                            textMatchScore = score
                            currentMatchType = "keyword-prefix(\(keyword))"
                        }
                    } else if observedWords.contains(where: { areWordsEquivalentOrStems($0, keyword) }) {
                        let score = 1800.0
                        if score > textMatchScore {
                            textMatchScore = score
                            currentMatchType = "keyword-word(\(keyword))"
                        }
                    } else if normalizedObserved.contains(keyword) {
                        let score = 1200.0
                        if score > textMatchScore {
                            textMatchScore = score
                            currentMatchType = "keyword-substring(\(keyword))"
                        }
                    }
                }
            }

            // Threshold: require at least a solid match to justify moving the cursor
            guard textMatchScore >= 2000.0 else { continue }

            // Proximity bonus if vertically aligned with the target row
            var proximityScore: Double = -Double(effectiveDistance)
            if verticalDistanceToBox == 0.0 {
                proximityScore += 500.0
            }

            let combinedScore = textMatchScore + proximityScore

            if combinedScore > bestScore {
                bestScore = combinedScore
                bestMatchType = currentMatchType
                closestDistance = effectiveDistance
                bestMatch = ScreenTextMatch(
                    text: recognizedText,
                    globalRect: globalRect,
                    globalCenter: globalCenter
                )
            }
        }

        if let match = bestMatch {
            print("🎯 ScreenTextLocator: snapped to \"\(match.text)\" at (center: \(Int(match.globalCenter.x)), \(Int(match.globalCenter.y))), size: \(Int(match.globalRect.width))x\(Int(match.globalRect.height)) (score: \(Int(bestScore)), type: \(bestMatchType))")
        }

        return bestMatch
    }

    /// Normalizes text by lowercasing and replacing all non-alphanumeric characters with spaces,
    /// then collapsing consecutive spaces. Example: "Dance • Playlist" -> "dance playlist"
    private static func normalizeTextForComparison(_ text: String) -> String {
        let lowercasedText = text.lowercased()
        let words = lowercasedText.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return words.joined(separator: " ")
    }

    /// Checks if two words match or share a common stem (e.g. "dance" and "dancing", "suche" and "suchen", "playlist" and "playlists")
    private static func areWordsEquivalentOrStems(_ word1: String, _ word2: String) -> Bool {
        if word1 == word2 { return true }
        let minLength = min(word1.count, word2.count)
        if minLength >= 4 && (word1.hasPrefix(word2) || word2.hasPrefix(word1)) {
            return true
        }
        return false
    }
}
