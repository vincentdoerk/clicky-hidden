//
//  ScreenCapturing.swift
//  leanring-buddy
//
//  Protocol abstraction for capturing screen contents across connected displays.
//

import Foundation

protocol ScreenCapturing: Sendable {
    func captureScreens() async throws -> [CompanionScreenCapture]
}
