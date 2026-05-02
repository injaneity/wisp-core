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
    @State private var autoConnectionTestTask: Task<Void, Never>?

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
                        Label("Talk", systemImage: "waveform")
                    }
                    .disabled(!canEnterWisp)
                    .foregroundStyle(canEnterWisp ? .primary : .secondary)
                }

                Section {
                    Button(action: startChat) {
                        Label("Chat", systemImage: "message")
                    }
                    .disabled(!canEnterWisp)
                    .foregroundStyle(canEnterWisp ? .primary : .secondary)
                }
            }
            .navigationTitle("Wisp Setup")
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
        .onAppear {
            scheduleAutomaticConnectionTest()
        }
        .onChange(of: settings.selectedSetup) {
            connectionModel.resetHealth()
            scheduleAutomaticConnectionTest()
        }
        .onChange(of: remoteConnectionFingerprint) {
            connectionModel.resetHealth()
            scheduleAutomaticConnectionTest()
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
                isChecking: connectionModel.isChecking
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
                isChecking: connectionModel.isChecking
            )
        }
    }

    private var canEnterWisp: Bool {
        guard settings.canStartChat && !isImportingModel else {
            return false
        }

        if settings.selectedSetup.usesRemoteBackend {
            return verifiedRemoteBackend != nil
        }

        return true
    }

    private var verifiedRemoteBackend: WispModelBackend? {
        guard let backend = settings.configuredRemoteBackend,
              let health = connectionModel.health,
              health.status == .reachable,
              health.backend == backend else {
            return nil
        }
        return backend
    }

    private var remoteConnectionFingerprint: String {
        guard let backend = settings.configuredRemoteBackend else {
            return "none|\(settings.selectedSetup.rawValue)"
        }
        return [
            settings.selectedSetup.rawValue,
            backend.baseURL,
            backend.model,
            backend.authorizationHeader() ?? ""
        ].joined(separator: "|")
    }

    private func testConnection() {
        guard let backend = settings.configuredRemoteBackend else {
            return
        }
        connectionModel.testConnection(to: backend)
    }

    private func scheduleAutomaticConnectionTest() {
        autoConnectionTestTask?.cancel()

        guard settings.selectedSetup.usesRemoteBackend,
              let backend = settings.configuredRemoteBackend,
              settings.canStartChat else {
            return
        }

        autoConnectionTestTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else {
                return
            }
            connectionModel.testConnection(to: backend)
        }
    }

    private func startChat() {
        guard canEnterWisp else {
            return
        }
        chatConfiguration = settings.chatConfiguration
    }

    private func startFastCapture() {
        guard canEnterWisp else {
            return
        }
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
