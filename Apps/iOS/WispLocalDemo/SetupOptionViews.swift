import SwiftUI
import WispCore
import WispUI

struct OpenAISetupSection: View {
    @Binding var model: String
    @Binding var apiKey: String
    let health: WispBackendHealth?
    let isChecking: Bool
    let onTestConnection: () -> Void

    var body: some View {
        Section("OpenAI API") {
            TextField("Model", text: $model)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("API key", text: $apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            WispBackendConnectionView(
                health: health,
                isChecking: isChecking,
                onTestConnection: onTestConnection
            )
            .listRowInsets(EdgeInsets())
        }
    }
}

struct OnDeviceSetupSection: View {
    let configuration: WispOnDeviceLlamaConfiguration?
    let isImporting: Bool
    let importError: String?
    let onChooseModel: () -> Void

    var body: some View {
        Section("llama.cpp") {
            Button(action: onChooseModel) {
                if isImporting {
                    ProgressView()
                } else {
                    Label("Choose GGUF Model", systemImage: "doc.badge.plus")
                }
            }
            .disabled(isImporting)

            if let configuration {
                Label(configuration.modelName, systemImage: "cpu")
                OnDeviceModelDetails(configuration: configuration)
            } else {
                Label("No model selected", systemImage: "circle")
                    .foregroundStyle(.secondary)
            }

            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct TailscaleSetupSection: View {
    @Binding var baseURL: String
    @Binding var model: String
    @Binding var bearerToken: String
    let health: WispBackendHealth?
    let isChecking: Bool
    let onTestConnection: () -> Void

    var body: some View {
        Section("Tailscale Mac") {
            TextField("Base URL", text: $baseURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()

            TextField("Model", text: $model)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("Bearer token", text: $bearerToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            WispBackendConnectionView(
                health: health,
                isChecking: isChecking,
                onTestConnection: onTestConnection
            )
            .listRowInsets(EdgeInsets())
        }
    }
}

private struct OnDeviceModelDetails: View {
    let configuration: WispOnDeviceLlamaConfiguration

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                Text("Context")
                    .foregroundStyle(.secondary)
                Text("\(configuration.contextLength) tokens")
            }
            GridRow {
                Text("Limit")
                    .foregroundStyle(.secondary)
                Text("\(configuration.maxTokens) tokens")
            }
            GridRow {
                Text("File")
                    .foregroundStyle(.secondary)
                Text(configuration.modelURL.lastPathComponent)
                    .lineLimit(2)
            }
        }
        .font(.callout)
    }
}

extension WispInferenceSetup {
    var title: String {
        switch self {
        case .openAIAPI:
            "API key"
        case .onDeviceLlamaCPP:
            "llama.cpp"
        case .tailscaleMac:
            "Tailscale Mac"
        }
    }

    var symbol: String {
        switch self {
        case .openAIAPI:
            "key"
        case .onDeviceLlamaCPP:
            "iphone.gen3"
        case .tailscaleMac:
            "network"
        }
    }

    var usesRemoteBackend: Bool {
        switch self {
        case .openAIAPI, .tailscaleMac:
            true
        case .onDeviceLlamaCPP:
            false
        }
    }
}
