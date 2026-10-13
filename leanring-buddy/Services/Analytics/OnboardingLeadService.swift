//
//  OnboardingLeadService.swift
//  leanring-buddy
//
//  Handles lead capture during onboarding: identifies the user in PostHog
//  and sends their email address to FormSpark.
//

import Foundation
import PostHog

final class OnboardingLeadService {
    private static let defaultFormSparkEndpointURL = URL(string: "https://submit-form.com/RWbGJxmIs")!

    private let formSparkEndpointURL: URL
    private let urlSession: URLSession
    private let identifyUserHandler: (String) -> Void

    init(
        formSparkEndpointURL: URL = OnboardingLeadService.defaultFormSparkEndpointURL,
        urlSession: URLSession = .shared,
        identifyUserHandler: @escaping (String) -> Void = { email in
            PostHogSDK.shared.identify(email, userProperties: ["email": email])
        }
    ) {
        self.formSparkEndpointURL = formSparkEndpointURL
        self.urlSession = urlSession
        self.identifyUserHandler = identifyUserHandler
    }

    func submitLead(email: String) async throws {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        identifyUserHandler(trimmedEmail)

        var request = URLRequest(url: formSparkEndpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": trimmedEmail])

        _ = try await urlSession.data(for: request)
    }

    func submitLeadInBackground(email: String) {
        Task {
            do {
                try await submitLead(email: email)
            } catch {
                print("⚠️ OnboardingLeadService: Failed to submit email: \(error)")
            }
        }
    }
}
