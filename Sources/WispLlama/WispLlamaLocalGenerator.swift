import Foundation
import WispCore
import llama

private struct WispLlamaPointer: @unchecked Sendable {
    let value: OpaquePointer
}

public enum WispLlamaLocalGeneratorError: Error, CustomStringConvertible, Equatable {
    case modelFileMissing(URL)
    case couldNotLoadModel(URL)
    case couldNotCreateContext
    case promptTooLong(tokenCount: Int, contextLength: Int32)
    case decodeFailed
    case missingContext
    case emptyOutput

    public var description: String {
        switch self {
        case .modelFileMissing(let url):
            "Model file does not exist at \(url.path)."
        case .couldNotLoadModel(let url):
            "llama.cpp could not load the model at \(url.path)."
        case .couldNotCreateContext:
            "llama.cpp could not create an inference context for this model."
        case .promptTooLong(let tokenCount, let contextLength):
            "Prompt uses \(tokenCount) tokens, which is larger than the configured \(contextLength)-token context."
        case .decodeFailed:
            "llama.cpp failed while decoding tokens."
        case .missingContext:
            "llama.cpp context was not initialized."
        case .emptyOutput:
            "The local model finished without producing text."
        }
    }
}

public actor WispLlamaLocalGenerator {
    private let configuration: WispOnDeviceLlamaConfiguration
    private var model: WispLlamaPointer?
    private var context: WispLlamaPointer?
    private var vocab: WispLlamaPointer?
    private var backendInitialized = false

    public init(configuration: WispOnDeviceLlamaConfiguration) {
        self.configuration = configuration
    }

    deinit {
        if let context {
            llama_free(context.value)
        }
        if let model {
            llama_model_free(model.value)
        }
        if backendInitialized {
            llama_backend_free()
        }
    }

    public func respond(to prompt: String) async throws -> WispModelResponse {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw WispCoreError.emptyText("prompt")
        }

        try loadIfNeeded()
        let output = try await generate(prompt: formattedPrompt(for: trimmedPrompt))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            throw WispLlamaLocalGeneratorError.emptyOutput
        }

        return WispModelResponse(model: configuration.modelName, text: output)
    }

    public func unload() {
        if let context {
            llama_free(context.value)
            self.context = nil
        }
        if let model {
            llama_model_free(model.value)
            self.model = nil
            self.vocab = nil
        }
        if backendInitialized {
            llama_backend_free()
            backendInitialized = false
        }
    }

    private func loadIfNeeded() throws {
        guard model == nil || context == nil else {
            return
        }

        guard FileManager.default.fileExists(atPath: configuration.modelURL.path) else {
            throw WispLlamaLocalGeneratorError.modelFileMissing(configuration.modelURL)
        }

        llama_backend_init()
        backendInitialized = true

        var modelParameters = llama_model_default_params()
        modelParameters.n_gpu_layers = configuration.gpuLayerCount
#if targetEnvironment(simulator)
        modelParameters.n_gpu_layers = 0
#endif

        guard let loadedModel = llama_model_load_from_file(configuration.modelURL.path, modelParameters) else {
            throw WispLlamaLocalGeneratorError.couldNotLoadModel(configuration.modelURL)
        }

        let threads = configuration.threadCount ?? defaultThreadCount()
        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = UInt32(max(128, configuration.contextLength))
        contextParameters.n_threads = threads
        contextParameters.n_threads_batch = threads

        guard let loadedContext = llama_init_from_model(loadedModel, contextParameters) else {
            llama_model_free(loadedModel)
            throw WispLlamaLocalGeneratorError.couldNotCreateContext
        }

        model = WispLlamaPointer(value: loadedModel)
        context = WispLlamaPointer(value: loadedContext)
        vocab = llama_model_get_vocab(loadedModel)
            .map(WispLlamaPointer.init(value:))
    }

    private func generate(prompt: String) async throws -> String {
        guard let context, let vocab else {
            throw WispLlamaLocalGeneratorError.missingContext
        }

        let tokens = try tokenize(prompt, addBOS: true)
        guard tokens.count < Int(configuration.contextLength) else {
            throw WispLlamaLocalGeneratorError.promptTooLong(
                tokenCount: tokens.count,
                contextLength: configuration.contextLength
            )
        }

        llama_memory_clear(llama_get_memory(context.value), true)

        let batchCapacity = max(Int32(tokens.count), 1)
        var batch = llama_batch_init(batchCapacity, 0, 1)
        defer {
            llama_batch_free(batch)
            llama_memory_clear(llama_get_memory(context.value), true)
        }

        batchClear(&batch)
        for index in tokens.indices {
            batchAdd(&batch, tokens[index], position: Int32(index), sequenceIDs: [0], logits: false)
        }
        batch.logits[Int(batch.n_tokens) - 1] = 1

        guard llama_decode(context.value, batch) == 0 else {
            throw WispLlamaLocalGeneratorError.decodeFailed
        }

        let sampler = makeSampler()
        defer {
            llama_sampler_free(sampler)
        }

        var currentPosition = Int32(tokens.count)
        var output = ""
        var pendingUTF8: [CChar] = []

        while currentPosition < configuration.maxTokens + Int32(tokens.count) {
            try Task.checkCancellation()

            let token = llama_sampler_sample(sampler, context.value, batch.n_tokens - 1)
            if llama_vocab_is_eog(vocab.value, token) {
                output += flushPendingUTF8(&pendingUTF8)
                break
            }

            pendingUTF8.append(contentsOf: tokenToPiece(token))
            output += consumeValidUTF8(&pendingUTF8)

            batchClear(&batch)
            batchAdd(&batch, token, position: currentPosition, sequenceIDs: [0], logits: true)
            guard llama_decode(context.value, batch) == 0 else {
                throw WispLlamaLocalGeneratorError.decodeFailed
            }

            currentPosition += 1
        }

        return output
    }

    private func makeSampler() -> UnsafeMutablePointer<llama_sampler> {
        let parameters = llama_sampler_chain_default_params()
        let sampler = llama_sampler_chain_init(parameters)
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(configuration.temperature))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(configuration.seed ?? 1_234))
        return sampler!
    }

    private func tokenize(_ text: String, addBOS: Bool) throws -> [llama_token] {
        guard let vocab else {
            throw WispLlamaLocalGeneratorError.missingContext
        }

        var capacity = Int32(text.utf8.count + (addBOS ? 1 : 0) + 1)
        while true {
            let buffer = UnsafeMutablePointer<llama_token>.allocate(capacity: Int(capacity))
            defer { buffer.deallocate() }

            let count = llama_tokenize(
                vocab.value,
                text,
                Int32(text.utf8.count),
                buffer,
                capacity,
                addBOS,
                false
            )

            if count >= 0 {
                let tokenBuffer = UnsafeBufferPointer(start: buffer, count: Int(count))
                return Array(tokenBuffer)
            }

            capacity = -count
        }
    }

    private func tokenToPiece(_ token: llama_token) -> [CChar] {
        guard let vocab else {
            return []
        }

        var capacity: Int32 = 8
        while true {
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(capacity))
            buffer.initialize(repeating: 0, count: Int(capacity))
            defer { buffer.deallocate() }

            let count = llama_token_to_piece(vocab.value, token, buffer, capacity, 0, false)
            if count >= 0 {
                return Array(UnsafeBufferPointer(start: buffer, count: Int(count)))
            }

            capacity = -count
        }
    }

    private func batchClear(_ batch: inout llama_batch) {
        batch.n_tokens = 0
    }

    private func batchAdd(
        _ batch: inout llama_batch,
        _ token: llama_token,
        position: llama_pos,
        sequenceIDs: [llama_seq_id],
        logits: Bool
    ) {
        let tokenIndex = Int(batch.n_tokens)
        batch.token[tokenIndex] = token
        batch.pos[tokenIndex] = position
        batch.n_seq_id[tokenIndex] = Int32(sequenceIDs.count)
        for index in sequenceIDs.indices {
            batch.seq_id[tokenIndex]![index] = sequenceIDs[index]
        }
        batch.logits[tokenIndex] = logits ? 1 : 0
        batch.n_tokens += 1
    }

    private func consumeValidUTF8(_ bytes: inout [CChar]) -> String {
        guard !bytes.isEmpty else {
            return ""
        }

        if let string = String(data: Data(unsignedBytes(bytes)), encoding: .utf8) {
            bytes.removeAll(keepingCapacity: true)
            return string
        }

        for suffixLength in 1..<bytes.count {
            let suffix = Array(bytes.suffix(suffixLength))
            if String(data: Data(unsignedBytes(suffix)), encoding: .utf8) != nil {
                let prefixLength = bytes.count - suffixLength
                let prefix = Array(bytes.prefix(prefixLength))
                bytes = Array(bytes.suffix(suffixLength))
                return String(decoding: unsignedBytes(prefix), as: UTF8.self)
            }
        }

        return ""
    }

    private func flushPendingUTF8(_ bytes: inout [CChar]) -> String {
        guard !bytes.isEmpty else {
            return ""
        }
        defer { bytes.removeAll(keepingCapacity: true) }
        return String(decoding: unsignedBytes(bytes), as: UTF8.self)
    }

    private func unsignedBytes(_ bytes: [CChar]) -> [UInt8] {
        bytes.map { UInt8(bitPattern: $0) }
    }

    private func defaultThreadCount() -> Int32 {
        Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
    }

    private func formattedPrompt(for prompt: String) -> String {
        """
        You are Wisp, a concise local assistant inside an iPhone app.

        User:
        \(prompt)

        Assistant:
        """
    }
}
