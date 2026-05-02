import SwiftUI
import UniformTypeIdentifiers
import WispCore
import WispUI

struct ConnectionDashboardView: View {
    private static let ggufType = UTType(filenameExtension: "gguf") ?? .data

    @EnvironmentObject private var settings: WispAppSettings
    @StateObject private var connectionModel = WispBackendConnectionViewModel()
    @State private var chatConfiguration: WispChatConfiguration?

    @State private var isShowingModelImporter = false
    @State private var isImportingModel = false
    @State private var modelImportError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Setup") {
                    Picker("Inference", selection: $settings.selectedSetup) {
                        ForEach(WispInferenceSetup.allCases) { setup in
                            Label(setup.title, systemImage: setup.symbol)
                                .tag(setup)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                selectedSetupSection

                Section {
                    Button(action: startFastCapture) {
                        Label("Fast Capture", systemImage: "bolt.fill")
                    }
                    .disabled(!canStartChat)
                } footer: {
                    Text("Use this to test the Action Button shortcut flow from inside the simulator.")
                }

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
                    if settings.selectedSetup.usesRemoteBackend {
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
        .onChange(of: settings.selectedSetup) {
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
        switch settings.selectedSetup {
        case .openAIAPI:
            OpenAISetupSection(
                model: $settings.openAIModel,
                apiKey: $settings.openAIAPIKey,
                health: connectionModel.health,
                isChecking: connectionModel.isChecking,
                onTestConnection: testConnection
            )
        case .onDeviceLlamaCPP:
            OnDeviceSetupSection(
                configuration: settings.onDeviceConfiguration,
                isImporting: isImportingModel,
                importError: modelImportError,
                onChooseModel: chooseModel
            )
        case .tailscaleMac:
            TailscaleSetupSection(
                baseURL: $settings.tailscaleBaseURL,
                model: $settings.tailscaleModel,
                bearerToken: $settings.tailscaleBearerToken,
                health: connectionModel.health,
                isChecking: connectionModel.isChecking,
                onTestConnection: testConnection
            )
        }
    }

    private var canStartChat: Bool {
        settings.canStartChat && !isImportingModel
    }

    private func testConnection() {
        guard let backend = settings.configuredRemoteBackend else {
            return
        }
        connectionModel.testConnection(to: backend)
    }

    private func startChat() {
        chatConfiguration = settings.chatConfiguration
    }

    private func startFastCapture() {
        WispAppRouter.shared.openFastCapture()
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
                settings.onDeviceConfiguration = imported
            } catch {
                modelImportError = String(describing: error)
            }
            isImportingModel = false
        }
    }
}

#Preview {
    ConnectionDashboardView()
        .environmentObject(WispAppSettings())
}
