//
//  PanelTTSVoiceSection.swift
//  leanring-buddy
//
//  Text-to-Speech configuration section including TTS model, speech rate,
//  audition preview, language selector, and voice timbre selector.
//

import SwiftUI

struct PanelTTSVoiceSection: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(spacing: 8) {
            // Row 1: Label "TTS", Audio Preview, Speed, and Model Picker
            HStack(spacing: 6) {
                Text("TTS")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Button(action: {
                    if companionManager.isPlayingVoicePreview {
                        companionManager.stopVoicePreview()
                    } else {
                        companionManager.playVoicePreview()
                    }
                }) {
                    Image(systemName: companionManager.isPlayingVoicePreview ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(companionManager.isPlayingVoicePreview ? DS.Colors.accentText : DS.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help(companionManager.isPlayingVoicePreview ? "Stimmenvorschau stoppen" : "Stimme probehören")

                Menu {
                    ForEach(companionManager.availableSpeechRates, id: \.self) { rateValue in
                        Button(action: {
                            companionManager.setSpeechRateMultiplier(rateValue)
                        }) {
                            HStack {
                                Text(formatSpeedDisplayName(rateValue))
                                if abs(rateValue - companionManager.speechRateMultiplier) < 0.01 {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(formatSpeedDisplayName(companionManager.speechRateMultiplier))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .pointerCursor()
                .help("Sprechgeschwindigkeit anpassen")

                Spacer()

                Menu {
                    ForEach(companionManager.availableTTSModels) { ttsModelOption in
                        Button(action: {
                            companionManager.setSelectedTTSModel(ttsModelOption.id)
                        }) {
                            HStack {
                                Text(ttsModelOption.displayName)
                                if ttsModelOption.id == companionManager.selectedTTSModelId {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(companionManager.currentTTSModel.shortName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .pointerCursor()
                .help("Text-to-Speech Modell auswählen")
            }

            // Row 2: Language Picker and Voice Picker
            HStack(spacing: 8) {
                // Language Picker
                Menu {
                    ForEach(companionManager.availableLanguagesForCurrentModel) { langOption in
                        Button(action: {
                            companionManager.setSelectedTTSLanguage(langOption.code)
                        }) {
                            HStack {
                                Text(langOption.displayName)
                                if langOption.code == companionManager.selectedTTSLanguageCode {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                        Text(formatLanguageDisplayName(companionManager.selectedTTSLanguageCode))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
                }
                .menuStyle(.borderlessButton)
                .pointerCursor()
                .help("Sprache für die Sprachausgabe auswählen")

                // Voice Picker
                Menu {
                    ForEach(companionManager.availableVoices, id: \.self) { voiceName in
                        Button(action: {
                            companionManager.setSelectedVoice(voiceName)
                            companionManager.playVoicePreview(for: voiceName)
                        }) {
                            HStack {
                                Text(formatVoiceDisplayName(voiceName))
                                if voiceName == companionManager.selectedVoice {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.wave.2")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                        Text(formatVoiceDisplayName(companionManager.selectedVoice))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
                }
                .menuStyle(.borderlessButton)
                .pointerCursor()
                .help("Stimme für die Sprachausgabe auswählen")
            }
        }
        .padding(.vertical, 4)
    }

    private func formatSpeedDisplayName(_ rate: Double) -> String {
        if abs(rate - 1.0) < 0.01 {
            return "1.0×"
        } else if rate == Double(Int(rate)) {
            return "\(Int(rate)).0×"
        } else if abs(rate * 10 - Double(Int(rate * 10))) < 0.01 {
            return String(format: "%.1f×", rate)
        } else {
            return String(format: "%.2f×", rate)
        }
    }

    private func formatLanguageDisplayName(_ langCode: String) -> String {
        switch langCode.lowercased() {
        case "german", "de":
            return "Deutsch"
        case "english", "en", "a", "b":
            return "English"
        case "french", "fr":
            return "Français"
        case "spanish", "es":
            return "Español"
        case "italian", "it":
            return "Italiano"
        case "japanese", "ja":
            return "日本語"
        case "chinese", "zh":
            return "中文"
        default:
            return langCode.capitalized
        }
    }

    private func formatVoiceDisplayName(_ rawVoiceName: String) -> String {
        switch rawVoiceName {
        case "Serena":
            return "Serena (Female)"
        case "Vivian":
            return "Vivian (Female)"
        case "Ryan":
            return "Ryan (Male)"
        case "Aiden":
            return "Aiden (Male)"
        case "Uncle_Fu":
            return "Uncle Fu (Male)"
        case "Dylan":
            return "Dylan (Male)"
        case "Eric":
            return "Eric (Male)"
        case "Ono_Anna":
            return "Ono Anna (Female)"
        case "Sohee":
            return "Sohee (Female)"
        case "af_heart":
            return "Heart (Female)"
        case "af_bella":
            return "Bella (Female)"
        case "af_nicole":
            return "Nicole (Female)"
        case "af_sky":
            return "Sky (Female)"
        case "af_sarah":
            return "Sarah (Female)"
        case "am_adam":
            return "Adam (Male)"
        case "am_michael":
            return "Michael (Male)"
        case "am_eric":
            return "Eric (Male)"
        case "am_liam":
            return "Liam (Male)"
        case "bf_emma":
            return "Emma (British)"
        case "bf_isabella":
            return "Isabella (British)"
        case "bm_george":
            return "George (British)"
        case "bm_lewis":
            return "Lewis (British)"
        case "System":
            return "System Standard"
        default:
            return rawVoiceName.replacingOccurrences(of: "_", with: " ")
        }
    }
}
