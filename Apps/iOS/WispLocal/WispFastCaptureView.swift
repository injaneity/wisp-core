import AVFoundation
import Speech
import SwiftUI
import WispCore
import WispLlama

struct WispFastCaptureView: View {
    let configuration: WispChatConfiguration

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isDraftFocused: Bool
    @StateObject private var speech = WispSpeechCaptureController()

    @State private var draft: String
    @State private var responseText: String?
    @State private var isSending = false
    @State private var errorText: String?
    @State private var llamaGenerator: WispLlamaLocalGenerator?

    private let responsesClient = WispResponsesClient()

    init(configuration: WispChatConfiguration, initialText: String = "") {
        self.configuration = configuration
        _draft = State(initialValue: initialText)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ConfigurationBanner(configuration: configuration)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Talk", systemImage: "waveform")
                            .font(.headline)
                        Spacer()
                        Button(action: toggleSpeechCapture) {
                            Image(systemName: speech.isRecording ? "stop.fill" : "mic.fill")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(speech.isRecording ? .red : .blue)
                        .accessibilityLabel(speech.isRecording ? "Stop Voice Capture" : "Start Voice Capture")
                    }

                    TextEditor(text: $draft)
                        .focused($isDraftFocused)
                        .frame(minHeight: 160)
                        .padding(8)
                        .scrollContentBackground(.hidden)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topLeading) {
                            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("Speak or type what you want Wisp to handle...")
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 16)
                                    .allowsHitTesting(false)
                            }
                        }

                    HStack(spacing: 10) {
                        Button(action: focusKeyboard) {
                            Label("Type", systemImage: "keyboard")
                        }
                        .buttonStyle(.bordered)

                        Button(action: toggleSpeechCapture) {
                            Label(speech.isRecording ? "Listening" : "Speak", systemImage: speech.isRecording ? "waveform" : "mic")
                        }
                        .buttonStyle(.bordered)
                        .tint(speech.isRecording ? .red : .blue)

                        Spacer()

                        Button(action: submitCapture) {
                            if isSending {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Send", systemImage: "paperplane.fill")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))

                if let statusText = speech.statusText {
                    Label(statusText, systemImage: speech.isRecording ? "waveform" : "info.circle")
                        .font(.callout)
                        .foregroundStyle(speech.isRecording ? .red : .secondary)
                }

                if isSending {
                    TypingIndicator()
                }

                if let errorText {
                    ErrorBanner(text: errorText)
                }

                if let responseText {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Wisp")
                            .font(.headline)
                        Text(responseText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        NavigationLink {
                            WispChatView(
                                configuration: configuration,
                                initialMessages: [
                                    ChatMessage(role: .user, text: draft),
                                    ChatMessage(role: .assistant, text: responseText)
                                ]
                            )
                        } label: {
                            Label("Continue in Chat", systemImage: "message")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(16)
        }
        .navigationTitle("Talk")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        .onAppear {
            isDraftFocused = draft.isEmpty
        }
        .onDisappear {
            speech.stopRecording()
        }
        .onChange(of: speech.transcript) {
            guard speech.isRecording else { return }
            draft = speech.transcript
        }
    }

    private func focusKeyboard() {
        isDraftFocused = true
    }

    private func toggleSpeechCapture() {
        isDraftFocused = false
        speech.toggleRecording(seedText: draft)
    }

    private func submitCapture() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else {
            return
        }

        speech.stopRecording()
        errorText = nil
        responseText = nil
        isSending = true

        Task {
            do {
                responseText = try await response(to: WispPromptBuilder.fastCapture(text: text))
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
}

@MainActor
final class WispSpeechCaptureController: NSObject, ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false
    @Published var statusText: String?

    private let speechRecognizer = SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    func toggleRecording(seedText: String) {
        if isRecording {
            stopRecording()
            return
        }

        transcript = seedText
        Task {
            do {
                try await requestPermissions()
                try startRecording()
            } catch {
                statusText = String(describing: error)
                stopRecording()
            }
        }
    }

    func stopRecording() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isRecording = false
        if statusText == "Listening..." {
            statusText = nil
        }
    }

    private func requestPermissions() async throws {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            throw WispSpeechCaptureError.speechNotAuthorized
        }

        let microphoneGranted = await AVAudioApplication.requestRecordPermission()
        guard microphoneGranted else {
            throw WispSpeechCaptureError.microphoneNotAuthorized
        }
    }

    private func startRecording() throws {
        stopRecording()

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw WispSpeechCaptureError.recognizerUnavailable
        }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true
        statusText = "Listening..."

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if let error {
                    self.statusText = String(describing: error)
                    self.stopRecording()
                } else if result?.isFinal == true {
                    self.stopRecording()
                }
            }
        }
    }
}

enum WispSpeechCaptureError: LocalizedError {
    case speechNotAuthorized
    case microphoneNotAuthorized
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .speechNotAuthorized:
            "Speech recognition is not authorized."
        case .microphoneNotAuthorized:
            "Microphone access is not authorized."
        case .recognizerUnavailable:
            "Speech recognition is unavailable on this device."
        }
    }
}

#Preview {
    NavigationStack {
        WispFastCaptureView(configuration: .openAIAPI(apiKey: "preview"))
    }
}
