import SwiftUI
import WispCore
import WispUI

struct WispRootView: View {
    @StateObject private var settings = WispAppSettings()
    @StateObject private var router = WispAppRouter.shared

    var body: some View {
        ConnectionDashboardView()
            .environmentObject(settings)
            .fullScreenCover(item: $router.fastCaptureRequest) { request in
                NavigationStack {
                    WispFastCaptureGateView(
                        settings: settings,
                        initialText: request.prefilledText
                    )
                }
                .environmentObject(settings)
            }
    }
}

private struct WispFastCaptureGateView: View {
    @ObservedObject var settings: WispAppSettings
    let initialText: String

    @StateObject private var connectionModel = WispBackendConnectionViewModel()

    var body: some View {
        Group {
            if !settings.canStartChat {
                FastCaptureSetupRequiredView()
            } else if let configuration = settings.chatConfiguration, !settings.selectedSetup.usesRemoteBackend {
                WispFastCaptureView(configuration: configuration, initialText: initialText)
            } else if let configuration = settings.chatConfiguration, isVerified {
                WispFastCaptureView(configuration: configuration, initialText: initialText)
            } else {
                FastCaptureValidationView(
                    health: connectionModel.health,
                    isChecking: connectionModel.isChecking,
                    onRetry: testConfiguredBackend
                )
            }
        }
        .onAppear {
            testConfiguredBackend()
        }
        .onChange(of: remoteConnectionFingerprint) {
            connectionModel.resetHealth()
            testConfiguredBackend()
        }
    }

    private var isVerified: Bool {
        guard let backend = settings.configuredRemoteBackend,
              let health = connectionModel.health else {
            return false
        }
        return health.status == .reachable && health.backend == backend
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

    private func testConfiguredBackend() {
        guard settings.selectedSetup.usesRemoteBackend,
              settings.canStartChat,
              let backend = settings.configuredRemoteBackend else {
            return
        }
        connectionModel.testConnection(to: backend)
    }
}

private struct FastCaptureValidationView: View {
    let health: WispBackendHealth?
    let isChecking: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            if isChecking {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            VStack(spacing: 8) {
                Text(isChecking ? "Testing backend" : "Backend not ready")
                    .font(.title2.bold())

                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if !isChecking {
                Button(action: onRetry) {
                    Label("Retry Test", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .navigationTitle("Fast Capture")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var message: String {
        if isChecking {
            return "Wisp is verifying the selected backend before opening Fast Capture."
        }

        if let health {
            return health.message
        }

        return "Wisp must verify the selected backend before opening Fast Capture."
    }
}

private struct FastCaptureSetupRequiredView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "bolt.badge.exclamationmark")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.orange)

            VStack(spacing: 8) {
                Text("Finish setup first")
                    .font(.title2.bold())
                Text("Fast Capture uses your selected Wisp backend. Add an API key, choose a local model, or configure Tailscale Mac before launching from the Action Button.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("Back to Setup") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .navigationTitle("Fast Capture")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    WispRootView()
}
