import Foundation

/// A shared effort preference for AI features. Providers that do not expose a
/// compatible reasoning control keep their own default behavior.
enum AIThinkingEffort: String, CaseIterable, Identifiable {
    case automatic
    case low
    case medium
    case high
    case veryHigh
    case maximum

    var id: Self {
        self
    }

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .veryHigh: "Very High"
        case .maximum: "Maximum"
        }
    }

    var apiValue: String? {
        switch self {
        case .automatic: nil
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .veryHigh: "xhigh"
        case .maximum: "max"
        }
    }

    static func supportedOptions(provider: ProtocolProvider, model: String, endpoint: URL?) -> [Self] {
        guard supportsReasoningEffort(provider: provider, model: model, endpoint: endpoint) else { return [] }
        #if !APPSTORE
            if provider == .claudeCLI {
                return [.automatic, .low, .medium, .high]
            }
        #endif
        if model.lowercased().contains("-pro") {
            return [.automatic, .high]
        }
        var options: [Self] = [.automatic, .low, .medium, .high]
        if supportsVeryHighEffort(model) {
            options.append(.veryHigh)
        }
        if supportsMaximumEffort(model) {
            options.append(.maximum)
        }
        return options
    }

    static func requestValue(
        for effort: Self,
        model: String,
        provider: ProtocolProvider,
        endpoint: URL? = nil,
    ) -> String? {
        guard effort != .automatic,
              supportsReasoningEffort(provider: provider, model: model, endpoint: endpoint) else { return nil }
        #if !APPSTORE
            if provider == .claudeCLI {
                return [.low, .medium, .high].contains(effort) ? effort.apiValue : nil
            }
        #endif
        if model.lowercased().contains("-pro"), effort != .high { return nil }
        if effort == .veryHigh, !supportsVeryHighEffort(model) { return nil }
        if effort == .maximum, !supportsMaximumEffort(model) { return nil }
        return effort.apiValue
    }

    private static func supportsVeryHighEffort(_ model: String) -> Bool {
        let name = model.lowercased()
        return name.contains("codex-max")
            || name.hasPrefix("gpt-5.5")
            || name.hasPrefix("gpt-5.6")
            || name.hasPrefix("gpt-6")
    }

    private static func supportsMaximumEffort(_ model: String) -> Bool {
        let name = model.lowercased()
        return name.hasPrefix("gpt-5.6") || name.hasPrefix("gpt-6")
    }

    private static func supportsReasoningEffort(provider: ProtocolProvider, model: String, endpoint: URL?) -> Bool {
        switch provider {
        case .chatGPTPlan:
            return isReasoningModel(model)

        case .openAICompatible:
            return isReasoningModel(model) && endpoint?.host?.lowercased() == "api.openai.com"

        #if !APPSTORE
            case .claudeCLI:
                return true
        #endif

        case .none:
            return false
        }
    }

    private static func isReasoningModel(_ model: String) -> Bool {
        let name = model.lowercased()
        return ["gpt-5", "gpt-6", "o1", "o3", "o4"].contains(where: name.hasPrefix)
    }
}
