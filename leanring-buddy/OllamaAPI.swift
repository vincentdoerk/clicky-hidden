//
//  OllamaAPI.swift
//  leanring-buddy
//
//  Local Vision and Chat API client communicating directly with Ollama.
//

import Foundation

/// Ollama API client providing local vision and chat inference with NDJSON streaming.
final class OllamaAPI {
    private let apiBaseURL: URL
    var selectedModelName: String
    private let urlSession: URLSession

    init(baseURLString: String = "http://127.0.0.1:11434", selectedModelName: String = "llama3.2-vision") {
        self.apiBaseURL = URL(string: baseURLString)!
        self.selectedModelName = selectedModelName

        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = 120
        sessionConfiguration.timeoutIntervalForResource = 300
        sessionConfiguration.waitsForConnectivity = false
        self.urlSession = URLSession(configuration: sessionConfiguration)
    }

    /// Fetches installed models from Ollama's /api/tags endpoint and filters for vision-capable models.
    func fetchAvailableVisionModels() async throws -> [String] {
        let tagsEndpointURL = apiBaseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: tagsEndpointURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        let (responseData, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw NSError(
                domain: "OllamaAPI",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to fetch tags from Ollama"]
            )
        }

        guard let jsonObject = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let modelsArray = jsonObject["models"] as? [[String: Any]] else {
            return []
        }

        var detectedVisionModelNames: [String] = []

        for modelDictionary in modelsArray {
            guard let modelName = modelDictionary["name"] as? String else { continue }

            var isVisionCapable = false

            // Check capabilities array reported by Ollama
            if let capabilitiesArray = modelDictionary["capabilities"] as? [String],
               capabilitiesArray.contains("vision") {
                isVisionCapable = true
            }

            // Fallback: check model name for common vision model naming patterns
            let lowercaseModelName = modelName.lowercased()
            if lowercaseModelName.contains("vision") ||
               lowercaseModelName.contains("-vl") ||
               lowercaseModelName.contains("llava") ||
               lowercaseModelName.contains("minicpm-v") {
                isVisionCapable = true
            }

            if isVisionCapable {
                detectedVisionModelNames.append(modelName)
            }
        }

        return detectedVisionModelNames
    }

    /// Sends a vision chat request to Ollama with NDJSON streaming.
    /// Calls `onTextChunk` on the main actor each time new text arrives so the UI updates progressively.
    /// Returns the full accumulated text and total duration when the stream completes.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let requestStartTime = Date()

        let chatEndpointURL = apiBaseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: chatEndpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var messagesArray: [[String: Any]] = []

        // System prompt
        messagesArray.append([
            "role": "system",
            "content": systemPrompt
        ])

        // Prior conversation history
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messagesArray.append(["role": "user", "content": userPlaceholder])
            messagesArray.append(["role": "assistant", "content": assistantResponse])
        }

        // Current user message: combine screen labels and user prompt
        var userMessageText = ""
        var base64EncodedImages: [String] = []

        for (screenImageIndex, screenImage) in images.enumerated() {
            base64EncodedImages.append(screenImage.data.base64EncodedString())
            userMessageText += "[Screen \(screenImageIndex + 1): \(screenImage.label)]\n"
        }

        if !userMessageText.isEmpty {
            userMessageText += "\n"
        }
        userMessageText += userPrompt

        var currentUserMessageDictionary: [String: Any] = [
            "role": "user",
            "content": userMessageText
        ]
        if !base64EncodedImages.isEmpty {
            currentUserMessageDictionary["images"] = base64EncodedImages
        }
        messagesArray.append(currentUserMessageDictionary)

        let requestBodyDictionary: [String: Any] = [
            "model": selectedModelName,
            "messages": messagesArray,
            "stream": true
        ]

        let requestBodyData = try JSONSerialization.data(withJSONObject: requestBodyDictionary)
        request.httpBody = requestBodyData

        let payloadMegabytes = Double(requestBodyData.count) / 1_048_576.0
        print("🌐 Ollama streaming request: \(String(format: "%.1f", payloadMegabytes))MB, \(images.count) image(s), model: \(selectedModelName)")

        let (byteStream, response) = try await urlSession.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "OllamaAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response from Ollama"]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyLines: [String] = []
            for try await line in byteStream.lines {
                errorBodyLines.append(line)
            }
            let completeErrorBody = errorBodyLines.joined(separator: "\n")
            throw NSError(
                domain: "OllamaAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Ollama API Error (\(httpResponse.statusCode)): \(completeErrorBody)"]
            )
        }

        var accumulatedResponseText = ""

        for try await responseLine in byteStream.lines {
            let trimmedLine = responseLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }

            guard let lineData = trimmedLine.data(using: .utf8),
                  let jsonPayload = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            if let messageDictionary = jsonPayload["message"] as? [String: Any],
               let contentChunk = messageDictionary["content"] as? String {
                accumulatedResponseText += contentChunk
                let currentAccumulatedText = accumulatedResponseText
                await onTextChunk(currentAccumulatedText)
            }

            if let isStreamDone = jsonPayload["done"] as? Bool, isStreamDone {
                break
            }
        }

        let totalDuration = Date().timeIntervalSince(requestStartTime)
        return (text: accumulatedResponseText, duration: totalDuration)
    }

    /// Non-streaming fallback for validation or batch requests.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        return try await analyzeImageStreaming(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            onTextChunk: { _ in }
        )
    }
}
