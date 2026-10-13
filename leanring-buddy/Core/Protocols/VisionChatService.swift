//
//  VisionChatService.swift
//  leanring-buddy
//
//  Protocol abstraction for multimodal vision chat services with streaming responses.
//

import Foundation

protocol VisionChatService: AnyObject {
    func streamChat(
        prompt: String,
        screenCaptures: [CompanionScreenCapture],
        history: [(user: String, assistant: String)]
    ) async throws -> AsyncThrowingStream<String, Error>

    func fetchAvailableModels() async throws -> [String]
}
