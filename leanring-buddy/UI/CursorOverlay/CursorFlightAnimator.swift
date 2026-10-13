//
//  CursorFlightAnimator.swift
//  leanring-buddy
//
//  Coordinate conversions, bounding-box geometry, and bezier arc flight calculations
//  for the companion cursor flight animations.
//

import SwiftUI
import AppKit

/// Represents the evaluated cursor transformation at a single animation frame during flight.
struct CursorFlightTrajectoryStep {
    /// The screen position for the cursor at this frame.
    let position: CGPoint

    /// Tangent rotation angle in degrees, or nil if movement is negligible.
    let rotationDegrees: Double?

    /// Swoop scale factor (expands up to ~1.3x at flight midpoint).
    let scale: CGFloat
}

/// Helper and calculator for bezier flight curves and multi-screen coordinate mapping.
enum CursorFlightAnimator {

    // MARK: - Coordinate Mapping

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to the specified screen's overlay window.
    static func convertScreenPointToSwiftUICoordinates(
        _ screenPoint: CGPoint,
        screenFrame: CGRect
    ) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    /// Computes SwiftUI coordinates for the mouse position, clamped to screen edges
    /// if the mouse is currently on another display.
    static func getLiveMouseOrigin(
        from mouseLocation: CGPoint,
        screenFrame: CGRect
    ) -> CGPoint {
        if screenFrame.contains(mouseLocation) {
            let mouseInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation, screenFrame: screenFrame)
            return CGPoint(x: mouseInSwiftUI.x + 35, y: mouseInSwiftUI.y + 25)
        } else {
            let rawMouseInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation, screenFrame: screenFrame)
            let clampedEdgeX = max(20, min(rawMouseInSwiftUI.x, screenFrame.width - 20))
            let clampedEdgeY = max(20, min(rawMouseInSwiftUI.y, screenFrame.height - 20))
            return CGPoint(x: clampedEdgeX, y: clampedEdgeY)
        }
    }

    // MARK: - Target Bounding Box & Landing Point

    /// Calculates the highlighted bounding box and the destination landing corner for an element.
    static func calculateElementHighlightAndLanding(
        screenLocation: CGPoint,
        highlightSize: CGSize?,
        screenFrame: CGRect
    ) -> (highlightRect: CGRect, landingPoint: CGPoint) {
        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation, screenFrame: screenFrame)

        let boxSize = highlightSize ?? CGSize(width: 140, height: 38)
        let boxWidth = boxSize.width
        let boxHeight = boxSize.height

        // Calculate bounding box centered around the target element, clamped inside screen frame
        let rawBoxOrigin = CGPoint(
            x: targetInSwiftUI.x - boxWidth / 2.0,
            y: targetInSwiftUI.y - boxHeight / 2.0
        )
        let clampedBoxX = max(10, min(rawBoxOrigin.x, screenFrame.width - boxWidth - 10))
        let clampedBoxY = max(10, min(rawBoxOrigin.y, screenFrame.height - boxHeight - 10))
        let finalBoxRect = CGRect(x: clampedBoxX, y: clampedBoxY, width: boxWidth, height: boxHeight)

        // Clicky lands at the bottom-right corner of the highlighted box with (+6, +7) offset
        let targetCornerX = finalBoxRect.maxX + 6
        let targetCornerY = finalBoxRect.maxY + 7

        let clampedTarget = CGPoint(
            x: max(20, min(targetCornerX, screenFrame.width - 20)),
            y: max(20, min(targetCornerY, screenFrame.height - 20))
        )

        return (highlightRect: finalBoxRect, landingPoint: clampedTarget)
    }

    // MARK: - Flight Timing

    /// Flight duration scales with initial distance: short hops are quick, long
    /// flights are more dramatic. Clamped to 0.6s–1.4s.
    static func calculateFlightDuration(distance: CGFloat) -> Double {
        return min(max(distance / 800.0, 0.6), 1.4)
    }

    /// Total frames required for the flight at the specified frame interval (default: 60 FPS).
    static func calculateTotalFrames(duration: Double, frameInterval: Double = 1.0 / 60.0) -> Int {
        return max(1, Int(duration / frameInterval))
    }

    // MARK: - Dynamic Trajectory (Forward Flight with Moving Mouse Origin)

    /// Evaluates dynamic quadratic bezier trajectory at frame `currentFrame` / `totalFrames`.
    /// Origin vector adapts dynamically to live mouse coordinates while converging onto `destination`.
    static func evaluateDynamicFlightStep(
        currentFrame: Int,
        totalFrames: Int,
        currentLiveOrigin: CGPoint,
        destination: CGPoint
    ) -> CursorFlightTrajectoryStep {
        let linearProgress = Double(currentFrame) / Double(totalFrames)

        // Smoothstep easeInOut: 3t² - 2t³ (Hermite interpolation)
        let t = linearProgress * linearProgress * (3.0 - 2.0 * linearProgress)

        let currentDeltaX = destination.x - currentLiveOrigin.x
        let currentDeltaY = destination.y - currentLiveOrigin.y
        let currentDistance = hypot(currentDeltaX, currentDeltaY)

        let midPoint = CGPoint(
            x: (currentLiveOrigin.x + destination.x) / 2.0,
            y: (currentLiveOrigin.y + destination.y) / 2.0
        )
        let arcHeight = min(currentDistance * 0.2, 80.0)
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y - arcHeight)

        // Dynamic quadratic bezier: B(t) = (1-t)²·P0 + 2(1-t)t·P1 + t²·P2
        let oneMinusT = 1.0 - t
        let bezierX = oneMinusT * oneMinusT * currentLiveOrigin.x
                    + 2.0 * oneMinusT * t * controlPoint.x
                    + t * t * destination.x
        let bezierY = oneMinusT * oneMinusT * currentLiveOrigin.y
                    + 2.0 * oneMinusT * t * controlPoint.y
                    + t * t * destination.y

        // Tangent: B'(t) = 2(1-t)(P1-P0) + 2t(P2-P1)
        let tangentX = 2.0 * oneMinusT * (controlPoint.x - currentLiveOrigin.x)
                     + 2.0 * t * (destination.x - controlPoint.x)
        let tangentY = 2.0 * oneMinusT * (controlPoint.y - currentLiveOrigin.y)
                     + 2.0 * t * (destination.y - controlPoint.y)

        let rotation: Double?
        if hypot(tangentX, tangentY) > 0.001 {
            rotation = atan2(tangentY, tangentX) * (180.0 / .pi) + 90.0
        } else {
            rotation = nil
        }

        let scalePulse = sin(linearProgress * .pi)
        let flightScale = 1.0 + scalePulse * 0.3

        return CursorFlightTrajectoryStep(
            position: CGPoint(x: bezierX, y: bezierY),
            rotationDegrees: rotation,
            scale: flightScale
        )
    }

    // MARK: - Static Trajectory (Return Flight Arc)

    /// Evaluates quadratic bezier trajectory from static startPosition to destination.
    static func evaluateStaticFlightStep(
        currentFrame: Int,
        totalFrames: Int,
        startPosition: CGPoint,
        destination: CGPoint
    ) -> CursorFlightTrajectoryStep {
        let linearProgress = Double(currentFrame) / Double(totalFrames)

        // Smoothstep easeInOut: 3t² - 2t³ (Hermite interpolation)
        let t = linearProgress * linearProgress * (3.0 - 2.0 * linearProgress)

        let deltaX = destination.x - startPosition.x
        let deltaY = destination.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        let midPoint = CGPoint(
            x: (startPosition.x + destination.x) / 2.0,
            y: (startPosition.y + destination.y) / 2.0
        )
        let arcHeight = min(distance * 0.2, 80.0)
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y - arcHeight)

        let oneMinusT = 1.0 - t
        let bezierX = oneMinusT * oneMinusT * startPosition.x
                    + 2.0 * oneMinusT * t * controlPoint.x
                    + t * t * destination.x
        let bezierY = oneMinusT * oneMinusT * startPosition.y
                    + 2.0 * oneMinusT * t * controlPoint.y
                    + t * t * destination.y

        let tangentX = 2.0 * oneMinusT * (controlPoint.x - startPosition.x)
                     + 2.0 * t * (destination.x - controlPoint.x)
        let tangentY = 2.0 * oneMinusT * (controlPoint.y - startPosition.y)
                     + 2.0 * t * (destination.y - controlPoint.y)

        let rotation: Double?
        if hypot(tangentX, tangentY) > 0.001 {
            rotation = atan2(tangentY, tangentX) * (180.0 / .pi) + 90.0
        } else {
            rotation = nil
        }

        let scalePulse = sin(linearProgress * .pi)
        let flightScale = 1.0 + scalePulse * 0.3

        return CursorFlightTrajectoryStep(
            position: CGPoint(x: bezierX, y: bezierY),
            rotationDegrees: rotation,
            scale: flightScale
        )
    }
}
