//
//  Metrics.swift
//  leanring-buddy
//
//  Layout metrics, corner radii, spacing, animation constants, and shadow tokens.
//

import SwiftUI

extension DS {
    // MARK: - Spacing

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    // MARK: - Corner Radii

    enum CornerRadius {
        /// Small elements like tags, badges.
        static let small: CGFloat = 6
        /// Buttons, input fields, small cards.
        static let medium: CGFloat = 8
        /// Cards, dialogs, chat bubbles.
        static let large: CGFloat = 10
        /// Large panels, permission cards.
        static let extraLarge: CGFloat = 12
        /// Pill-shaped buttons (the continue button).
        static let pill: CGFloat = .infinity
    }

    // MARK: - Animation Durations

    enum Animation {
        /// Quick state changes — hover in/out, press feedback.
        static let fast: Double = 0.15
        /// Standard transitions — content reveal, button state changes.
        static let normal: Double = 0.25
        /// Slower, more dramatic — fade-ins, celebration screen elements.
        static let slow: Double = 0.4
    }

    // MARK: - State Layer Opacities
    // Based on Material Design 3's state layer system.
    // A "state layer" overlays the button's content color at these opacities.

    enum StateLayer {
        /// Hover: subtle highlight to indicate interactivity.
        static let hover: Double = 0.08
        /// Focus: keyboard navigation indicator (slightly stronger than hover).
        static let focus: Double = 0.12
        /// Pressed: active press feedback (same strength as focus).
        static let pressed: Double = 0.12
        /// Dragged: strongest overlay (rarely used).
        static let dragged: Double = 0.16
    }

    // MARK: - Shadows

    enum Shadows {
        /// Subtle shadow for small cards or elevated buttons
        static let subtle = Color.black.opacity(0.15)
        /// Medium shadow for floating cards and dropdown menus
        static let medium = Color.black.opacity(0.26)
        /// Prominent shadow for dialogs, panels, and floating windows
        static let prominent = Color.black.opacity(0.42)
    }
}
