import SwiftUI
import WispCore
import WispLlama

struct WispChatView: View {
    let configuration: WispChatConfiguration

    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var isSending = false
    @State private var errorText: String?
    @State private var llamaGenerator: WispLlamaLocalGenerator?

    private let responsesClient = WispResponsesClient()

    init(configuration: WispChatConfiguration, initialMessages: [ChatMessage] = []) {
        self.configuration = configuration
        _messages = State(initialValue: initialMessages)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ConfigurationBanner(configuration: configuration)

                    if messages.isEmpty {
                        EmptyChatPlaceholder()
                    }

                    ForEach(messages) { message in
                        ChatBubble(message: message)
                            .id(message.id)
                    }

                    if isSending {
                        TypingIndicator()
                            .id("typing")
                    }

                    if let errorText {
                        ErrorBanner(text: errorText)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: messages) {
                scrollToBottom(with: proxy)
            }
            .onChange(of: isSending) {
                scrollToBottom(with: proxy)
            }
        }
        .safeAreaInset(edge: .bottom) {
            ChatInputBar(
                draft: $draft,
                isSending: isSending,
                onSend: sendMessage
            )
        }
        .navigationTitle(configuration.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sendMessage() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else {
            return
        }

        errorText = nil
        draft = ""
        messages.append(ChatMessage(role: .user, text: text))
        isSending = true

        let prompt = transcriptPrompt()
        Task {
            do {
                let responseText = try await response(to: prompt)
                messages.append(ChatMessage(role: .assistant, text: responseText))
            } catch {
                errorText = String(describing: error)
            }
            isSending = false
        }
    }

    private func response(to prompt: String) async throws -> String {
        switch configuration.setup {
        case .openAIAPI, .tailscaleMac:
            guard let backend = configuration.remoteBackend else {
                throw WispCoreError.unsupportedBackend("Missing remote backend configuration.")
            }
            return try await responsesClient.respond(to: prompt, using: backend).text
        case .onDeviceLlamaCPP:
            guard let llamaConfiguration = configuration.onDeviceLlama else {
                throw WispCoreError.unsupportedBackend("Missing on-device llama.cpp configuration.")
            }
            let generator = llamaGenerator ?? WispLlamaLocalGenerator(configuration: llamaConfiguration)
            llamaGenerator = generator
            return try await generator.respond(to: prompt).text
        }
    }

    private func transcriptPrompt() -> String {
        WispPromptBuilder.chatTranscript(messages: messages)
    }

    private func scrollToBottom(with proxy: ScrollViewProxy) {
        let target: AnyHashable? = isSending ? AnyHashable("typing") : messages.last?.id
        guard let target else {
            return
        }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }
}

#Preview {
    NavigationStack {
        WispChatView(configuration: .openAIAPI(apiKey: "preview"))
    }
}
