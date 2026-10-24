import Foundation

/// Shared local AI connection interface. Every Sawti feature uses the same
/// selected provider and credentials, while supplying a feature-specific prompt.
protocol AITextGenerating: Sendable {
    var supportsImageInput: Bool { get }
    func generateText(systemPrompt: String, userPrompt: String) async throws -> String
    func generateText(systemPrompt: String, userPrompt: String, imageData: Data?) async throws -> String
}

extension AITextGenerating {
    var supportsImageInput: Bool {
        false
    }

    func generateText(systemPrompt: String, userPrompt: String, imageData: Data?) async throws -> String {
        guard imageData == nil else { throw AITextGenerationError.imageInputUnavailable }
        return try await generateText(systemPrompt: systemPrompt, userPrompt: userPrompt)
    }
}

enum AITextGenerationError: LocalizedError {
    case imageInputUnavailable

    var errorDescription: String? {
        switch self {
        case .imageInputUnavailable:
            "The selected AI provider does not support screen images. Choose a vision-capable OpenAI or local model."
        }
    }
}
