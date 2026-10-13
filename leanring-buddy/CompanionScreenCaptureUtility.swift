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

struct CompanionScreenCapture {
    let imageData: Data
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
            let maxDimension = 1280
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
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
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
}
