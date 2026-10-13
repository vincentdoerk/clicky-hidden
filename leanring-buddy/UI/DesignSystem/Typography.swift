//
//  Typography.swift
//  leanring-buddy
//
//  Standard typography tokens and font styles for the design system.
//

import SwiftUI

extension DS {
    // MARK: - Typography Tokens

    enum Typography {
        /// Large title or main modal header
        static let title = Font.system(size: 16, weight: .semibold)

        /// Section headers and major card titles
        static let headline = Font.system(size: 14, weight: .semibold)

        /// Sub-section headers, list item titles
        static let subheadline = Font.system(size: 13, weight: .medium)

        /// Standard body text
        static let body = Font.system(size: 12, weight: .medium)

        /// Standard body text with regular weight
        static let bodyRegular = Font.system(size: 12, weight: .regular)

        /// Secondary information, descriptions, hints
        static let caption = Font.system(size: 11, weight: .medium)

        /// Regular weight caption for longer secondary text
        static let captionRegular = Font.system(size: 11, weight: .regular)

        /// Semibold caption for badges and tiny pills
        static let captionSemibold = Font.system(size: 11, weight: .semibold)

        /// Footnotes, sub-captions, timestamps
        static let footnote = Font.system(size: 10, weight: .medium)

        /// Uppercase section headers and micro-labels
        static let sectionHeader = Font.system(size: 10, weight: .semibold, design: .rounded)

        /// Micro text for small badges and tags
        static let micro = Font.system(size: 9, weight: .regular)

        /// Standard primary button font
        static let button = Font.system(size: 16, weight: .medium)

        /// Small button label font
        static let buttonSmall = Font.system(size: 12, weight: .medium)

        /// Monospaced font for inline code snippets
        static let code = Font.system(size: 11, weight: .regular, design: .monospaced)
    }
}
