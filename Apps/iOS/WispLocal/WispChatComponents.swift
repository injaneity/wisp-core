import SwiftUI
import WispCore

struct ChatMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant

        var promptLabel: String {
            switch self {
            case .user:
                "User"
            case .assistant:
                "Assistant"
            }
        }
    }

    let id: UUID
    let role: Role
    let text: String

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

struct ConfigurationBanner: View {
    let configuration: WispChatConfiguration

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 32, height: 32)
                .background(.blue.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(configuration.title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var symbol: String {
        switch configuration.setup {
        case .openAIAPI:
            "key"
        case .onDeviceLlamaCPP:
            "iphone.gen3"
        case .tailscaleMac:
            "desktopcomputer"
        }
    }

    private var subtitle: String {
        switch configuration.setup {
        case .openAIAPI, .tailscaleMac:
            configuration.remoteBackend.map { "\($0.model) at \($0.baseURL)" } ?? "Remote backend"
        case .onDeviceLlamaCPP:
            configuration.onDeviceLlama.map(\.modelName) ?? "Local model"
        }
    }
}

struct EmptyChatPlaceholder: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "message")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Start a Wisp chat")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .bottom) {
            if message.role == .user {
                Spacer(minLength: 48)
            }

            Text(message.text)
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(message.role == .user ? .white : .primary)
                .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 8))

            if message.role == .assistant {
                Spacer(minLength: 48)
            }
        }
    }

    private var backgroundStyle: Color {
        switch message.role {
        case .user:
            .blue
        case .assistant:
            Color(.secondarySystemGroupedBackground)
        }
    }
}

struct TypingIndicator: View {
    var body: some View {
        HStack {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Wisp is responding")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))

            Spacer(minLength: 48)
        }
    }
}

struct ErrorBanner: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ChatInputBar: View {
    @Binding var draft: String
    let isSending: Bool
    let onSend: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Wisp", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .disabled(isSending)

            Button(action: onSend) {
                if isSending {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "paperplane.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
