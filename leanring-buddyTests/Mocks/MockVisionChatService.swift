//
//  MockVisionChatService.swift
//  leanring-buddyTests
//
//  Mock implementation of VisionChatService with configurable response streaming.
//

import Foundation
@testable import leanring_buddy

final class MockVisionChatService: VisionChatService {
    var availableModels: [String] = ["llama3.2-vision", "qwen2.5-vl"]
    var streamedResponseChunks: [String] = ["Hallo! ", "Klicke auf das Menü."]
    var shouldThrowErrorOnStreamChat: Bool = false
    var streamChatError: Error? = nil

    var streamChatCallCount: Int = 0
    var fetchAvailableModelsCallCount: Int = 0
    var recordedPrompts: [String] = []
    var recordedScreenCaptures: [[CompanionScreenCapture]] = []
    var recordedHistory: [[(user: String, assistant: String)]] = []

    func streamChat(
        prompt: String,
        screenCaptures: [CompanionScreenCapture],
        history: [(user: String, assistant: String)]
    ) async throws -> AsyncThrowingStream<String, Error> {
        streamChatCallCount += 1
        recordedPrompts.append(prompt)
        recordedScreenCaptures.append(screenCaptures)
        recordedHistory.append(history)

        if shouldThrowErrorOnStreamChat {
            let errorToThrow = streamChatError ?? NSError(
                domain: "MockVisionChatService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Simulated stream chat error"]
            )
            throw errorToThrow
        }

        let chunksToYield = streamedResponseChunks
        return AsyncThrowingStream { continuation in
            for chunk in chunksToYield {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    func fetchAvailableModels() async throws -> [String] {
        fetchAvailableModelsCallCount += 1
        return availableModels
    }
}
