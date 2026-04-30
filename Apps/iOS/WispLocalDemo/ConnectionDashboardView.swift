import SwiftUI
import WispCore
import WispUI

struct ConnectionDashboardView: View {
    private static let defaultProvider: WispModelProvider = .openAICompatible

    @StateObject private var connectionModel = WispBackendConnectionViewModel()
    @State private var provider = Self.defaultProvider
    @State private var baseURL = WispModelBackend.defaultBaseURL(for: Self.defaultProvider)
    @State private var modelName = Self.defaultModel(for: Self.defaultProvider)
    @State private var bearerToken = ""
    @State private var prompt = "Summarize what Wisp should do next in one sentence."
    @State private var responseText = ""
    @State private var responseError: String?
    @State private var isSendingPrompt = false

    private let responsesClient = WispResponsesClient()

    private let providerOptions: [WispModelProvider] = [
        .openAICompatible,
        .ollama,
        .lmStudio,
        .llamaCPP
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    Picker("Provider", selection: $provider) {
                        ForEach(providerOptions, id: \.self) { option in
                            Text(label(for: option))
                                .tag(option)
                        }
                    }

                    TextField("Backend URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()

                    TextField("Model", text: $modelName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("Bearer token", text: $bearerToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Status") {
                    WispBackendConnectionView(
                        health: connectionModel.health,
                        isChecking: connectionModel.isChecking,
                        onTestConnection: testConnection
                    )
                    .listRowInsets(EdgeInsets())
                }

                Section("Prompt") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 96)
                        .textInputAutocapitalization(.sentences)
                        .autocorrectionDisabled()

                    Button(action: sendPrompt) {
                        if isSendingPrompt {
                            ProgressView()
                        } else {
                            Label("Send", systemImage: "paperplane")
                        }
                    }
                    .disabled(isSendingPrompt || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let responseError {
                        Label(responseError, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }

                    if !responseText.isEmpty {
                        Text(responseText)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }

                Section("Bonjour") {
                    Button(action: discoverBackends) {
                        if connectionModel.isDiscovering {
                            ProgressView()
                        } else {
                            Label("Discover Servers", systemImage: "dot.radiowaves.left.and.right")
                        }
                    }
                    .disabled(connectionModel.isDiscovering)

                    ForEach(connectionModel.discoveredBackends) { backend in
                        Button(action: { apply(backend) }) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(backend.name)
                                    .font(.body)
                                Text(backend.baseURL)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Wisp Local")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: testConnection) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Test Connection")
                    .disabled(connectionModel.isChecking)
                }
            }
        }
        .onChange(of: provider) { oldValue, newValue in
            let previousDefaultModel = Self.defaultModel(for: oldValue)
            let shouldUseProviderDefaultModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || modelName == previousDefaultModel
            baseURL = WispModelBackend.defaultBaseURL(for: newValue)
            if shouldUseProviderDefaultModel {
                modelName = Self.defaultModel(for: newValue)
            }
        }
    }

    private var configuredBackend: WispModelBackend {
        let token = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return WispModelBackend(
            provider: provider,
            baseURL: baseURL,
            model: modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.defaultModel(for: provider) : modelName,
            authentication: token.isEmpty ? .none : .bearerToken(token)
        )
    }

    private func testConnection() {
        connectionModel.testConnection(to: configuredBackend)
    }

    private func discoverBackends() {
        connectionModel.discover()
    }

    private func sendPrompt() {
        isSendingPrompt = true
        responseError = nil
        responseText = ""

        let backend = configuredBackend
        let promptToSend = prompt
        Task {
            do {
                let response = try await responsesClient.respond(to: promptToSend, using: backend)
                responseText = response.text
            } catch {
                responseError = String(describing: error)
            }
            isSendingPrompt = false
        }
    }

    private func apply(_ backend: WispDiscoveredBackend) {
        provider = backend.provider
        baseURL = backend.baseURL
        modelName = backend.model
        if !backend.requiresBearerToken {
            bearerToken = ""
        }
    }

    private func label(for provider: WispModelProvider) -> String {
        switch provider {
        case .ollama:
            return "Ollama"
        case .lmStudio:
            return "LM Studio"
        case .llamaCPP:
            return "llama.cpp"
        case .openAICompatible:
            return "OpenAI API"
        case .codex:
            return "Codex API"
        }
    }

    private static func defaultModel(for provider: WispModelProvider) -> String {
        switch provider {
        case .codex, .openAICompatible:
            return "gpt-5.4"
        case .ollama:
            return "gemma4"
        case .lmStudio, .llamaCPP:
            return "local-model"
        }
    }
}

#Preview {
    ConnectionDashboardView()
}
