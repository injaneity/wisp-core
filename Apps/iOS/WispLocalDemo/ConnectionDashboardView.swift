import SwiftUI
import UniformTypeIdentifiers
import WispCore
import WispUI

struct ConnectionDashboardView: View {
    private static let defaultSetup: WispInferenceSetup = .openAIAPI
    private static let ggufType = UTType(filenameExtension: "gguf") ?? .data

    @StateObject private var connectionModel = WispBackendConnectionViewModel()
    @State private var selectedSetup = Self.defaultSetup
    @State private var chatConfiguration: WispChatConfiguration?

    @State private var openAIAPIKey = ""
    @State private var openAIModel = "gpt-5.4"

    @State private var tailscaleBaseURL = "https://wisp-mac.tailnet.ts.net/v1"
    @State private var tailscaleModel = "gemma4"
    @State private var tailscaleBearerToken = ""

    @State private var onDeviceConfiguration: WispOnDeviceLlamaConfiguration?
    @State private var isShowingModelImporter = false
    @State private var isImportingModel = false
    @State private var modelImportError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Setup") {
                    Picker("Inference", selection: $selectedSetup) {
                        ForEach(WispInferenceSetup.allCases) { setup in
                            Label(setup.title, systemImage: setup.symbol)
                                .tag(setup)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                selectedSetupSection

                Section {
                    Button(action: startChat) {
                        Label("Continue to Chat", systemImage: "message")
                    }
                    .disabled(!canStartChat)
                }
            }
            .navigationTitle("Wisp Setup")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if selectedSetup.usesRemoteBackend {
                        Button(action: testConnection) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Test Connection")
                        .disabled(connectionModel.isChecking)
                    }
                }
            }
            .navigationDestination(isPresented: isChatPresented) {
                if let chatConfiguration {
                    WispChatView(configuration: chatConfiguration)
                }
            }
        }
        .fileImporter(
            isPresented: $isShowingModelImporter,
            allowedContentTypes: [Self.ggufType],
            allowsMultipleSelection: false,
            onCompletion: importModel
        )
        .onChange(of: selectedSetup) {
            connectionModel.resetHealth()
        }
    }

    private var isChatPresented: Binding<Bool> {
        Binding(
            get: { chatConfiguration != nil },
            set: { isPresented in
                if !isPresented {
                    chatConfiguration = nil
                }
            }
        )
    }

    @ViewBuilder
    private var selectedSetupSection: some View {
        switch selectedSetup {
        case .openAIAPI:
            OpenAISetupSection(
                model: $openAIModel,
                apiKey: $openAIAPIKey,
                health: connectionModel.health,
                isChecking: connectionModel.isChecking,
                onTestConnection: testConnection
            )
        case .onDeviceLlamaCPP:
            OnDeviceSetupSection(
                configuration: onDeviceConfiguration,
                isImporting: isImportingModel,
                importError: modelImportError,
                onChooseModel: chooseModel
            )
        case .tailscaleMac:
            TailscaleSetupSection(
                baseURL: $tailscaleBaseURL,
                model: $tailscaleModel,
                bearerToken: $tailscaleBearerToken,
                health: connectionModel.health,
                isChecking: connectionModel.isChecking,
                onTestConnection: testConnection
            )
        }
    }

    private var configuredRemoteBackend: WispModelBackend? {
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

    private var canStartChat: Bool {
        switch selectedSetup {
        case .openAIAPI:
            !trimmed(openAIAPIKey).isEmpty && !trimmed(openAIModel).isEmpty
        case .onDeviceLlamaCPP:
            onDeviceConfiguration != nil && !isImportingModel
        case .tailscaleMac:
            URL(string: trimmed(tailscaleBaseURL)) != nil && !trimmed(tailscaleModel).isEmpty
        }
    }

    private func testConnection() {
        guard let configuredRemoteBackend else {
            return
        }
        connectionModel.testConnection(to: configuredRemoteBackend)
    }

    private func startChat() {
        switch selectedSetup {
        case .openAIAPI:
            chatConfiguration = .openAIAPI(
                model: trimmed(openAIModel).isEmpty ? "gpt-5.4" : trimmed(openAIModel),
                apiKey: trimmed(openAIAPIKey)
            )
        case .onDeviceLlamaCPP:
            guard let onDeviceConfiguration else { return }
            chatConfiguration = .onDeviceLlama(onDeviceConfiguration)
        case .tailscaleMac:
            chatConfiguration = .tailscaleMac(
                baseURL: trimmed(tailscaleBaseURL),
                model: trimmed(tailscaleModel).isEmpty ? "gemma4" : trimmed(tailscaleModel),
                bearerToken: trimmed(tailscaleBearerToken)
            )
        }
    }

    private func chooseModel() {
        modelImportError = nil
        isShowingModelImporter = true
    }

    private func importModel(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            if case .failure(let error) = result {
                modelImportError = String(describing: error)
            }
            return
        }

        isImportingModel = true
        modelImportError = nil
        Task {
            do {
                let imported = try await Task.detached {
                    try WispOnDeviceModelStore().importModel(from: url)
                }.value
                onDeviceConfiguration = imported
            } catch {
                modelImportError = String(describing: error)
            }
            isImportingModel = false
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#Preview {
    ConnectionDashboardView()
}
