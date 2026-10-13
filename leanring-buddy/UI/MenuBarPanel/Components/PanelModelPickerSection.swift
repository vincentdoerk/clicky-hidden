//
//  PanelModelPickerSection.swift
//  leanring-buddy
//
//  Vision language model picker dropdown with model refresh action.
//

import SwiftUI

struct PanelModelPickerSection: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Text("VLM")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Button(action: {
                    Task {
                        await companionManager.refreshAvailableVisionModels()
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Refresh Ollama Vision Models")
            }

            Spacer()

            if companionManager.availableVisionModels.isEmpty {
                Text(formatModelDisplayName(companionManager.selectedModel))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            } else {
                Menu {
                    ForEach(companionManager.availableVisionModels, id: \.self) { visionModelName in
                        Button(action: {
                            companionManager.setSelectedModel(visionModelName)
                        }) {
                            HStack {
                                Text(visionModelName)
                                if visionModelName == companionManager.selectedModel {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(formatModelDisplayName(companionManager.selectedModel))
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
            }
        }
        .padding(.vertical, 4)
    }

    private func formatModelDisplayName(_ rawModelName: String) -> String {
        if rawModelName.hasSuffix(":latest") {
            return String(rawModelName.dropLast(7))
        }
        return rawModelName
    }
}
