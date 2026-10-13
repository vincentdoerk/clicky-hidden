//
//  TTSModelCatalog.swift
//  leanring-buddy
//
//  Unified catalog and configuration options for available local and native
//  Text-to-Speech (TTS) models. Defines supported models, default voice presets,
//  and compatible languages for Apple Silicon and macOS native synthesis.
//

import Foundation

/// Represents a spoken language supported by a text-to-speech backend.
struct TTSLanguageOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let code: String
}

/// Represents a configurable Text-to-Speech model.
struct TTSModelOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let shortName: String
    let modelRepo: String?
    let isLocalMLX: Bool
    let supportedLanguages: [TTSLanguageOption]
    let defaultLanguageCode: String
    let availableVoices: [String]
    let defaultVoice: String
}

enum TTSModelCatalog {
    // MARK: - Predefined Languages

    static let german = TTSLanguageOption(id: "de", displayName: "Deutsch", code: "German")
    static let english = TTSLanguageOption(id: "en", displayName: "English", code: "English")
    static let french = TTSLanguageOption(id: "fr", displayName: "Français", code: "French")
    static let spanish = TTSLanguageOption(id: "es", displayName: "Español", code: "Spanish")
    static let italian = TTSLanguageOption(id: "it", displayName: "Italiano", code: "Italian")
    static let japanese = TTSLanguageOption(id: "ja", displayName: "日本語", code: "Japanese")
    static let chinese = TTSLanguageOption(id: "zh", displayName: "中文", code: "Chinese")

    // MARK: - Supported Models

    /// Qwen3-TTS 0.6B: Fast, responsive 8-bit quantized model for Apple Silicon.
    static let qwen3_06B = TTSModelOption(
        id: "qwen3-0.6b",
        displayName: "Qwen3-TTS 0.6B (Schnell)",
        shortName: "Qwen3 0.6B",
        modelRepo: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit",
        isLocalMLX: true,
        supportedLanguages: [german, english, french, spanish, italian, japanese, chinese],
        defaultLanguageCode: "German",
        availableVoices: [
            "Serena",
            "Vivian",
            "Ryan",
            "Aiden",
            "Dylan",
            "Eric",
            "Uncle_Fu",
            "Ono_Anna",
            "Sohee"
        ],
        defaultVoice: "Serena"
    )

    /// Qwen3-TTS 1.7B: Higher quality 8-bit model for Apple Silicon.
    static let qwen3_17B = TTSModelOption(
        id: "qwen3-1.7b",
        displayName: "Qwen3-TTS 1.7B (High Quality)",
        shortName: "Qwen3 1.7B",
        modelRepo: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
        isLocalMLX: true,
        supportedLanguages: [german, english, french, spanish, italian, japanese, chinese],
        defaultLanguageCode: "German",
        availableVoices: [
            "Serena",
            "Vivian",
            "Ryan",
            "Aiden",
            "Dylan",
            "Eric",
            "Uncle_Fu",
            "Ono_Anna",
            "Sohee"
        ],
        defaultVoice: "Serena"
    )

    /// Kokoro-82M: Ultra-fast lightweight model (<50ms latency), multilingual (en, fr, es, it, ja, zh).
    static let kokoro_82M = TTSModelOption(
        id: "kokoro-82m",
        displayName: "Kokoro-82M (Ultra Fast)",
        shortName: "Kokoro 82M",
        modelRepo: "mlx-community/Kokoro-82M-bf16",
        isLocalMLX: true,
        supportedLanguages: [english, french, spanish, italian, japanese, chinese],
        defaultLanguageCode: "en",
        availableVoices: [
            "af_heart",
            "af_bella",
            "af_nicole",
            "af_sky",
            "af_sarah",
            "am_adam",
            "am_michael",
            "am_eric",
            "am_liam",
            "bf_emma",
            "bf_isabella",
            "bm_george",
            "bm_lewis"
        ],
        defaultVoice: "af_heart"
    )

    /// Apple Speech: Native macOS SpeechSynthesizer, 100% offline and instant.
    static let appleSpeech = TTSModelOption(
        id: "apple-speech",
        displayName: "Apple Speech (System TTS)",
        shortName: "Apple Speech",
        modelRepo: nil,
        isLocalMLX: false,
        supportedLanguages: [german, english, french, spanish, italian],
        defaultLanguageCode: "German",
        availableVoices: [
            "System"
        ],
        defaultVoice: "System"
    )

    /// All models exposed to the user in the panel picker.
    static let allModels: [TTSModelOption] = [
        qwen3_06B,
        qwen3_17B,
        kokoro_82M,
        appleSpeech
    ]

    /// Default model selection for new installs.
    static let defaultModelId: String = qwen3_06B.id

    /// Finds a model by its unique identifier.
    static func model(withId modelId: String) -> TTSModelOption {
        return allModels.first { $0.id == modelId } ?? qwen3_06B
    }
}
