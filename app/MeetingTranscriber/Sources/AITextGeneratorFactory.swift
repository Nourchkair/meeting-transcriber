import Foundation

/// Builds the one configured AI connection used throughout Sawti. Meeting notes
/// and future live-assistant features select the same provider and credentials;
/// each feature supplies its own system and user prompts.
enum AITextGeneratorFactory {
    static func make(settings: AppSettings) -> (any AITextGenerating)? {
        switch settings.protocolProvider {
        #if !APPSTORE
            case .claudeCLI:
                ClaudeCLIProtocolGenerator(
                    claudeBin: settings.claudeBin,
                    language: settings.protocolLanguage,
                    thinkingEffort: settings.aiThinkingEffort,
                    anthropicAPIKey: settings.claudeAPIKey.isEmpty ? nil : settings.claudeAPIKey,
                )
        #endif

        case .openAICompatible:
            OpenAIProtocolGenerator(
                endpoint: URL(string: settings.openAIEndpoint)
                    // swiftlint:disable:next force_unwrapping
                    ?? URL(string: AppSettings.defaultOpenAIEndpoint)!,
                model: settings.openAIModel,
                language: settings.protocolLanguage,
                thinkingEffort: settings.aiThinkingEffort,
                apiKey: settings.openAIAPIKey.isEmpty ? nil : settings.openAIAPIKey,
            )

        case .chatGPTPlan:
            ChatGPTPlanResponsesGenerator(
                model: settings.chatGPTPlanModel,
                language: settings.protocolLanguage,
                credentialStore: settings.chatGPTPlanCredentialStore,
                thinkingEffort: settings.aiThinkingEffort,
            )

        case .none:
            nil
        }
    }
}
