import Foundation

public enum WispModelProvider: String, Codable, Sendable, Equatable {
    case codex
    case openAICompatible = "openai_compatible"
    case ollama
    case lmStudio = "lmstudio"
    case llamaCPP = "llamacpp"

    public init(configValue: String?) {
        let normalized = (configValue ?? "codex")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")

        switch normalized {
        case "ollama":
            self = .ollama
        case "lmstudio", "lm_studio", "lm studio":
            self = .lmStudio
        case "llamacpp", "llama_cpp", "llama.cpp":
            self = .llamaCPP
        case "openai", "openai_compatible", "openai-compatible":
            self = .openAICompatible
        default:
            self = .codex
        }
    }

    public var isLocal: Bool {
        switch self {
        case .ollama, .lmStudio, .llamaCPP:
            true
        case .codex, .openAICompatible:
            false
        }
    }
}

public struct WispModelBackend: Sendable, Equatable {
    public var provider: WispModelProvider
    public var baseURL: String
    public var model: String
    public var reasoningEffort: String?
    public var authFile: URL?
    public var apiKeyEnvironmentVariable: String?

    public init(
        provider: WispModelProvider,
        baseURL: String? = nil,
        model: String,
        reasoningEffort: String? = nil,
        authFile: URL? = nil,
        apiKeyEnvironmentVariable: String? = nil
    ) {
        self.provider = provider
        self.baseURL = baseURL ?? Self.defaultBaseURL(for: provider)
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.authFile = authFile
        self.apiKeyEnvironmentVariable = apiKeyEnvironmentVariable
    }

    public static func defaultCodex(homeDirectory: URL, model: String = "gpt-5.4", reasoningEffort: String = "medium", baseURL: String? = nil) -> Self {
        Self(
            provider: .codex,
            baseURL: baseURL,
            model: model,
            reasoningEffort: reasoningEffort,
            authFile: homeDirectory.appendingPathComponent(".codex/auth.json")
        )
    }

    public static func localGemmaViaOllama(model: String = "gemma4") -> Self {
        Self(provider: .ollama, model: model)
    }

    public static func defaultBaseURL(for provider: WispModelProvider) -> String {
        switch provider {
        case .codex:
            "https://chatgpt.com/backend-api/codex"
        case .openAICompatible, .ollama:
            "http://localhost:11434/v1"
        case .lmStudio:
            "http://localhost:1234/v1"
        case .llamaCPP:
            "http://localhost:8000/v1"
        }
    }

    public var usesCodexOAuth: Bool {
        provider == .codex
    }

    public var sendsCodexOnlyRequestFields: Bool {
        provider == .codex
    }

    public func responsesURL() throws -> URL {
        switch provider {
        case .codex:
            try Self.resolveCodexResponsesURL(baseURL: baseURL)
        case .openAICompatible, .ollama, .lmStudio, .llamaCPP:
            try Self.resolveOpenAICompatibleResponsesURL(baseURL: baseURL)
        }
    }

    private static func resolveCodexResponsesURL(baseURL: String) throws -> URL {
        let normalized = normalizedBaseURL(baseURL)
        let urlString: String
        if normalized.hasSuffix("/codex/responses") {
            urlString = normalized
        } else if normalized.hasSuffix("/codex") {
            urlString = normalized + "/responses"
        } else {
            urlString = normalized + "/codex/responses"
        }
        guard let url = URL(string: urlString) else {
            throw WispCoreError.invalidBaseURL(baseURL)
        }
        return url
    }

    private static func resolveOpenAICompatibleResponsesURL(baseURL: String) throws -> URL {
        let normalized = normalizedBaseURL(baseURL)
        let urlString = normalized.hasSuffix("/responses") ? normalized : normalized + "/responses"
        guard let url = URL(string: urlString) else {
            throw WispCoreError.invalidBaseURL(baseURL)
        }
        return url
    }

    private static func normalizedBaseURL(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }
}
