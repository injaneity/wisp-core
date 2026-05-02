import Foundation
import WispCore

@MainActor
final class WispAppSettings: ObservableObject {
    private enum Keys {
        static let selectedSetup = "selectedSetup"
        static let openAIModel = "openAIModel"
        static let tailscaleBaseURL = "tailscaleBaseURL"
        static let tailscaleModel = "tailscaleModel"
        static let openAIAPIKey = "openAIAPIKey"
        static let tailscaleBearerToken = "tailscaleBearerToken"
    }

    @Published var selectedSetup: WispInferenceSetup {
        didSet {
            UserDefaults.standard.set(selectedSetup.rawValue, forKey: Keys.selectedSetup)
        }
    }

    @Published var openAIModel: String {
        didSet {
            UserDefaults.standard.set(openAIModel, forKey: Keys.openAIModel)
        }
    }

    @Published var openAIAPIKey: String {
        didSet {
            WispCredentialStore.save(trimmed(openAIAPIKey), account: Keys.openAIAPIKey)
        }
    }

    @Published var tailscaleBaseURL: String {
        didSet {
            UserDefaults.standard.set(tailscaleBaseURL, forKey: Keys.tailscaleBaseURL)
        }
    }

    @Published var tailscaleModel: String {
        didSet {
            UserDefaults.standard.set(tailscaleModel, forKey: Keys.tailscaleModel)
        }
    }

    @Published var tailscaleBearerToken: String {
        didSet {
            WispCredentialStore.save(trimmed(tailscaleBearerToken), account: Keys.tailscaleBearerToken)
        }
    }

    @Published var onDeviceConfiguration: WispOnDeviceLlamaConfiguration?

    init() {
        let storedSetup = UserDefaults.standard.string(forKey: Keys.selectedSetup)
        selectedSetup = storedSetup.flatMap(WispInferenceSetup.init(rawValue:)) ?? .openAIAPI
        openAIModel = UserDefaults.standard.string(forKey: Keys.openAIModel) ?? "gpt-5.4"
        openAIAPIKey = WispCredentialStore.read(account: Keys.openAIAPIKey)
        tailscaleBaseURL = UserDefaults.standard.string(forKey: Keys.tailscaleBaseURL) ?? "https://wisp-mac.tailnet.ts.net/v1"
        tailscaleModel = UserDefaults.standard.string(forKey: Keys.tailscaleModel) ?? "gemma4"
        tailscaleBearerToken = WispCredentialStore.read(account: Keys.tailscaleBearerToken)
    }

    var configuredRemoteBackend: WispModelBackend? {
        switch selectedSetup {
        case .openAIAPI:
            WispModelBackend.openAIAPI(
                model: trimmed(openAIModel).isEmpty ? "gpt-5.4" : trimmed(openAIModel),
                apiKey: trimmed(openAIAPIKey)
            )
        case .tailscaleMac:
            WispModelBackend.tailscaleMac(
                baseURL: trimmed(tailscaleBaseURL),
                model: trimmed(tailscaleModel).isEmpty ? "gemma4" : trimmed(tailscaleModel),
                bearerToken: trimmed(tailscaleBearerToken)
            )
        case .onDeviceLlamaCPP:
            nil
        }
    }

    var canStartChat: Bool {
        switch selectedSetup {
        case .openAIAPI:
            !trimmed(openAIAPIKey).isEmpty && !trimmed(openAIModel).isEmpty
        case .onDeviceLlamaCPP:
            onDeviceConfiguration != nil
        case .tailscaleMac:
            URL(string: trimmed(tailscaleBaseURL)) != nil && !trimmed(tailscaleModel).isEmpty
        }
    }

    var chatConfiguration: WispChatConfiguration? {
        guard canStartChat else {
            return nil
        }

        switch selectedSetup {
        case .openAIAPI:
            return .openAIAPI(
                model: trimmed(openAIModel).isEmpty ? "gpt-5.4" : trimmed(openAIModel),
                apiKey: trimmed(openAIAPIKey)
            )
        case .onDeviceLlamaCPP:
            guard let onDeviceConfiguration else { return nil }
            return .onDeviceLlama(onDeviceConfiguration)
        case .tailscaleMac:
            return .tailscaleMac(
                baseURL: trimmed(tailscaleBaseURL),
                model: trimmed(tailscaleModel).isEmpty ? "gemma4" : trimmed(tailscaleModel),
                bearerToken: trimmed(tailscaleBearerToken)
            )
        }
    }

    func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
