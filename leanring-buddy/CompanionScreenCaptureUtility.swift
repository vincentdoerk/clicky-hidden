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
            let maxDimension = 1920
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                configuration.width = maxDimension
                configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
            } else {
                configuration.height = maxDimension
                configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
            }

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

        // Clean candidate keywords (remove punctuation, lowercased, length >= 2)
        let cleanKeywords = candidateKeywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.count >= 2 }

        guard !cleanKeywords.isEmpty else { return nil }

        var bestMatch: ScreenTextMatch? = nil
        var bestScore: Double = -1.0
        var closestDistance: CGFloat = CGFloat.greatestFiniteMagnitude

        for observation in observations {
            guard let topCandidate = observation.topCandidates(1).first else { continue }
            let recognizedText = topCandidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowerRecognized = recognizedText.lowercased()

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

            let distance = hypot(globalCenter.x - estimatedGlobalLocation.x, globalCenter.y - estimatedGlobalLocation.y)

            // Score match quality
            var matchQuality: Double = 0.0
            let recognizedWords = lowerRecognized.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }

            for keyword in cleanKeywords {
                if lowerRecognized == keyword {
                    matchQuality = max(matchQuality, 4.0) // Exact phrase match
                } else if recognizedWords.contains(keyword) {
                    matchQuality = max(matchQuality, 3.0) // Whole word match
                } else if lowerRecognized.contains(keyword) {
                    matchQuality = max(matchQuality, 2.2) // Substring match
                } else if keyword.contains(lowerRecognized) && lowerRecognized.count >= 3 {
                    matchQuality = max(matchQuality, 1.5)
                }
            }

            guard matchQuality > 0 else { continue }

            // Score combining match quality and proximity
            let combinedScore = matchQuality * 1000.0 - Double(distance)

            if combinedScore > bestScore {
                bestScore = combinedScore
                closestDistance = distance
                bestMatch = ScreenTextMatch(
                    text: recognizedText,
                    globalRect: globalRect,
                    globalCenter: globalCenter
                )
            }
        }

        if let match = bestMatch {
            print("🎯 ScreenTextLocator: snapped to \"\(match.text)\" at (center: \(Int(match.globalCenter.x)), \(Int(match.globalCenter.y))), size: \(Int(match.globalRect.width))x\(Int(match.globalRect.height)) (distance: \(Int(closestDistance))pt from estimate)")
        }

        return bestMatch
    }
}
