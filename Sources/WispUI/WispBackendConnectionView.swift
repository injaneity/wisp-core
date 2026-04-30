import SwiftUI
import WispCore

@MainActor
public final class WispBackendConnectionViewModel: ObservableObject {
    @Published public private(set) var health: WispBackendHealth?
    @Published public private(set) var discoveredBackends: [WispDiscoveredBackend] = []
    @Published public private(set) var isChecking = false
    @Published public private(set) var isDiscovering = false

    private let healthClient: WispBackendHealthClient
    private let browser: WispBonjourBackendBrowser

    public init(
        healthClient: WispBackendHealthClient = WispBackendHealthClient(),
        browser: WispBonjourBackendBrowser = WispBonjourBackendBrowser()
    ) {
        self.healthClient = healthClient
        self.browser = browser
    }

    public func testConnection(to backend: WispModelBackend) {
        isChecking = true
        Task {
            let result = await healthClient.check(backend)
            health = result
            isChecking = false
        }
    }

    public func discover(timeoutSeconds: TimeInterval = 3) {
        isDiscovering = true
        Task {
            discoveredBackends = await browser.discover(timeoutSeconds: timeoutSeconds)
            isDiscovering = false
        }
    }

    public func resetHealth() {
        health = nil
    }
}

public struct WispBackendConnectionView: View {
    private let visibleModelLimit = 4
    private let health: WispBackendHealth?
    private let isChecking: Bool
    private let onTestConnection: () -> Void

    public init(
        health: WispBackendHealth?,
        isChecking: Bool,
        onTestConnection: @escaping () -> Void
    ) {
        self.health = health
        self.isChecking = isChecking
        self.onTestConnection = onTestConnection
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Label(statusTitle, systemImage: statusSymbol)
                    .font(.headline)
                    .foregroundStyle(statusColor)
                Spacer()
                Button(action: onTestConnection) {
                    if isChecking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Test", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isChecking)
            }

            if let health {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Endpoint")
                            .foregroundStyle(.secondary)
                        Text(health.backend.baseURL)
                            .textSelection(.enabled)
                    }
                    GridRow {
                        Text("Provider")
                            .foregroundStyle(.secondary)
                        Text(providerTitle(for: health.backend))
                    }
                    GridRow {
                        Text("Model")
                            .foregroundStyle(.secondary)
                        Text(health.backend.model)
                    }
                    if let latency = health.latencyMilliseconds {
                        GridRow {
                            Text("Latency")
                                .foregroundStyle(.secondary)
                            Text("\(latency) ms")
                        }
                    }
                    GridRow {
                        Text("Message")
                            .foregroundStyle(.secondary)
                        Text(health.message)
                    }
                    if !health.models.isEmpty {
                        GridRow {
                            Text("Models")
                                .foregroundStyle(.secondary)
                            Text("\(health.models.count) available")
                        }
                    }
                }
                .font(.callout)

                if !health.models.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sample Models")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        ForEach(Array(health.models.prefix(visibleModelLimit)), id: \.self) { model in
                            Label(model, systemImage: "cpu")
                                .font(.callout)
                        }
                        if health.models.count > visibleModelLimit {
                            Text("+ \(health.models.count - visibleModelLimit) more")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("No connection check has run.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private var statusTitle: String {
        guard let health else { return isChecking ? "Checking" : "Not Checked" }
        switch health.status {
        case .idle:
            return "Not Checked"
        case .checking:
            return "Checking"
        case .reachable:
            return "Reachable"
        case .unauthorized:
            return "Unauthorized"
        case .invalidResponse:
            return "Invalid Response"
        case .unreachable:
            return "Unreachable"
        }
    }

    private var statusSymbol: String {
        guard let health else { return isChecking ? "clock" : "circle" }
        switch health.status {
        case .idle:
            return "circle"
        case .checking:
            return "clock"
        case .reachable:
            return "checkmark.circle.fill"
        case .unauthorized:
            return "lock.trianglebadge.exclamationmark"
        case .invalidResponse:
            return "exclamationmark.triangle"
        case .unreachable:
            return "wifi.exclamationmark"
        }
    }

    private var statusColor: Color {
        guard let health else { return .secondary }
        switch health.status {
        case .idle, .checking:
            return .secondary
        case .reachable:
            return .green
        case .unauthorized, .invalidResponse:
            return .orange
        case .unreachable:
            return .red
        }
    }

    private func providerTitle(for backend: WispModelBackend) -> String {
        if let displayName = backend.displayName, !displayName.isEmpty {
            return displayName
        }

        return switch backend.provider {
        case .codex:
            "Codex API"
        case .openAICompatible:
            "OpenAI API"
        case .ollama:
            "Ollama"
        case .lmStudio:
            "LM Studio"
        case .llamaCPP:
            "llama.cpp"
        }
    }
}

#Preview {
    WispBackendConnectionView(
        health: WispBackendHealth(
            backend: .localGemmaViaOllama(),
            status: .reachable,
            latencyMilliseconds: 42,
            statusCode: 200,
            models: ["gemma4"],
            message: "Server is reachable with 1 model."
        ),
        isChecking: false,
        onTestConnection: {}
    )
}
