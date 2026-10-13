//
//  MockScreenCaptureUtility.swift
//  leanring-buddyTests
//
//  Mock implementation of ScreenCapturing returning configurable dummy captures.
//

import CoreGraphics
import Foundation
@testable import leanring_buddy

final class MockScreenCaptureUtility: ScreenCapturing, @unchecked Sendable {
    var capturesToReturn: [CompanionScreenCapture]
    var shouldThrowError: Bool = false
    var errorToThrow: Error? = nil
    var captureScreensCallCount: Int = 0

    init(capturesToReturn: [CompanionScreenCapture]? = nil) {
        if let capturesToReturn {
            self.capturesToReturn = capturesToReturn
        } else {
            self.capturesToReturn = [
                CompanionScreenCapture(
                    imageData: Data(),
                    cgImage: nil,
                    label: "Mock Display 1",
                    isCursorScreen: true,
                    cursorLocationOnScreen: CGPoint(x: 100, y: 100),
                    globalCursorLocationAtCapture: CGPoint(x: 100, y: 100),
                    displayWidthInPoints: 1920,
                    displayHeightInPoints: 1080,
                    displayFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                    screenshotWidthInPixels: 3840,
                    screenshotHeightInPixels: 2160
                )
            ]
        }
    }

    func captureScreens() async throws -> [CompanionScreenCapture] {
        captureScreensCallCount += 1

        if shouldThrowError {
            let error = errorToThrow ?? NSError(
                domain: "MockScreenCaptureUtility",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Simulated screen capture failure"]
            )
            throw error
        }

        return capturesToReturn
    }
}
