import Foundation

public enum WispInferenceSetup: String, CaseIterable, Codable, Sendable, Equatable, Identifiable {
    case openAIAPI = "openai_api"
    case onDeviceLlamaCPP = "on_device_llamacpp"
    case tailscaleMac = "tailscale_mac"

    public var id: String { rawValue }
}

public struct WispOnDeviceLlamaConfiguration: Codable, Sendable, Equatable {
    public var modelName: String
    public var modelURL: URL
    public var contextLength: Int32
    public var maxTokens: Int32
    public var temperature: Float
    public var seed: UInt32?
    public var threadCount: Int32?
    public var gpuLayerCount: Int32

    public init(
        modelName: String,
        modelURL: URL,
        contextLength: Int32 = 2_048,
        maxTokens: Int32 = 512,
        temperature: Float = 0.4,
        seed: UInt32? = 1_234,
        threadCount: Int32? = nil,
        gpuLayerCount: Int32 = 99
    ) {
        self.modelName = modelName
        self.modelURL = modelURL
        self.contextLength = contextLength
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.seed = seed
        self.threadCount = threadCount
        self.gpuLayerCount = gpuLayerCount
    }
}

public struct WispChatConfiguration: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var setup: WispInferenceSetup
    public var title: String
    public var remoteBackend: WispModelBackend?
    public var onDeviceLlama: WispOnDeviceLlamaConfiguration?

    public init(
        id: UUID = UUID(),
        setup: WispInferenceSetup,
        title: String,
        remoteBackend: WispModelBackend? = nil,
        onDeviceLlama: WispOnDeviceLlamaConfiguration? = nil
    ) {
        self.id = id
        self.setup = setup
        self.title = title
        self.remoteBackend = remoteBackend
        self.onDeviceLlama = onDeviceLlama
    }

    public static func openAIAPI(model: String = "gpt-5.4", apiKey: String) -> Self {
        Self(
            setup: .openAIAPI,
            title: "OpenAI API",
            remoteBackend: WispModelBackend.openAIAPI(model: model, apiKey: apiKey)
        )
    }

    public static func tailscaleMac(baseURL: String, model: String = "gemma4", bearerToken: String = "") -> Self {
        Self(
            setup: .tailscaleMac,
            title: "Tailscale Mac",
            remoteBackend: WispModelBackend.tailscaleMac(
                baseURL: baseURL,
                model: model,
                bearerToken: bearerToken
            )
        )
    }

    public static func onDeviceLlama(_ configuration: WispOnDeviceLlamaConfiguration) -> Self {
        Self(
            setup: .onDeviceLlamaCPP,
            title: "On-device llama.cpp",
            onDeviceLlama: configuration
        )
    }
}

public struct WispOnDeviceModelStore: Sendable {
    public var rootDirectory: URL?

    public init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory
    }

    public func modelsDirectory() throws -> URL {
        if let rootDirectory {
            try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            return rootDirectory
        }

        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let modelsDirectory = applicationSupport
            .appendingPathComponent("Wisp", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        return modelsDirectory
    }

    public func importModel(from sourceURL: URL) throws -> WispOnDeviceLlamaConfiguration {
        guard sourceURL.pathExtension.lowercased() == "gguf" else {
            throw WispCoreError.invalidModelFile("On-device llama.cpp requires a GGUF model file.")
        }

        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let destinationURL = try modelsDirectory()
            .appendingPathComponent(sourceURL.lastPathComponent, isDirectory: false)
        if destinationURL.standardizedFileURL != sourceURL.standardizedFileURL {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }

        let modelName = destinationURL.deletingPathExtension().lastPathComponent
        return WispOnDeviceLlamaConfiguration(modelName: modelName, modelURL: destinationURL)
    }
}
