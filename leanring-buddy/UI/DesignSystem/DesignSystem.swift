//
//  DesignSystem.swift
//  leanring-buddy
//
//  Centralized design system root namespace.
//  Submodules:
//  - Colors.swift: Color tokens, gradients, hex parser
//  - Typography.swift: Font styles
//  - Metrics.swift: Spacing, corner radii, animations, state layers, shadows
//  - ButtonStyles.swift: Button styles and convenience view extensions
//  - AppKitBridges.swift: Cursor handling and AppKit bridges
//

import SwiftUI
import AppKit

// MARK: - Design System Namespace

/// The top-level namespace for all design system tokens.
/// Usage: `DS.Colors.background`, `DS.Typography.body`, `DS.Spacing.md`, `DS.CornerRadius.medium`, etc.
enum DS {}
