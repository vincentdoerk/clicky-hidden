//
//  CompanionVoiceState.swift
//  leanring-buddy
//
//  Lifecycle state of the companion voice interaction.
//

import Foundation

public enum CompanionVoiceState: String, CaseIterable, Sendable, Equatable {
    case idle
    case listening
    case processing
    case responding
}
