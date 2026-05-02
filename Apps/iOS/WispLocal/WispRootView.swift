import SwiftUI

struct WispRootView: View {
    @StateObject private var settings = WispAppSettings()
    @StateObject private var router = WispAppRouter.shared

    var body: some View {
        ConnectionDashboardView()
            .environmentObject(settings)
            .fullScreenCover(item: $router.fastCaptureRequest) { request in
                NavigationStack {
                    if let configuration = settings.chatConfiguration {
                        WispFastCaptureView(
                            configuration: configuration,
                            initialText: request.prefilledText
                        )
                    } else {
                        FastCaptureSetupRequiredView()
                    }
                }
                .environmentObject(settings)
            }
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
