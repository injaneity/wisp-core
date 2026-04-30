import XCTest
@testable import WispCore

final class WispCoreTests: XCTestCase {
    func testOllamaGemmaBackendUsesResponsesEndpoint() throws {
        let backend = WispModelBackend.localGemmaViaOllama()

        XCTAssertEqual(backend.provider, .ollama)
        XCTAssertEqual(backend.model, "gemma4")
        XCTAssertEqual(try backend.responsesURL().absoluteString, "http://localhost:11434/v1/responses")
    }

    func testProviderParsingAcceptsCommonLocalNames() {
        XCTAssertEqual(WispModelProvider(configValue: "lm-studio"), .lmStudio)
        XCTAssertEqual(WispModelProvider(configValue: "llama.cpp"), .llamaCPP)
        XCTAssertEqual(WispModelProvider(configValue: "openai-compatible"), .openAICompatible)
    }

    func testOpenAICompatibleBackendDefaultsToOpenAIAPI() throws {
        let backend = WispModelBackend(provider: .openAICompatible, model: "gpt-5.4")

        XCTAssertEqual(backend.baseURL, "https://api.openai.com/v1")
        XCTAssertEqual(try backend.modelsURL().absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(try backend.responsesURL().absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(try backend.chatCompletionsURL().absoluteString, "https://api.openai.com/v1/chat/completions")
    }

    func testChatConfigurationBuildsThreeSetupModes() {
        let openAI = WispChatConfiguration.openAIAPI(apiKey: "api-secret")
        XCTAssertEqual(openAI.setup, .openAIAPI)
        XCTAssertEqual(openAI.remoteBackend?.displayName, "OpenAI API")
        XCTAssertEqual(openAI.remoteBackend?.model, "gpt-5.4")
        XCTAssertEqual(openAI.remoteBackend?.authorizationHeader(), "Bearer api-secret")

        let local = WispChatConfiguration.onDeviceLlama(
            WispOnDeviceLlamaConfiguration(
                modelName: "gemma-local",
                modelURL: URL(fileURLWithPath: "/tmp/gemma-local.gguf")
            )
        )
        XCTAssertEqual(local.setup, .onDeviceLlamaCPP)
        XCTAssertEqual(local.onDeviceLlama?.modelName, "gemma-local")

        let tailscale = WispChatConfiguration.tailscaleMac(
            baseURL: "https://studio.tailnet.ts.net/v1",
            model: "gemma4",
            bearerToken: "tail-secret"
        )
        XCTAssertEqual(tailscale.setup, .tailscaleMac)
        XCTAssertEqual(tailscale.remoteBackend?.displayName, "Tailscale Mac")
        XCTAssertEqual(tailscale.remoteBackend?.baseURL, "https://studio.tailnet.ts.net/v1")
        XCTAssertEqual(tailscale.remoteBackend?.authorizationHeader(), "Bearer tail-secret")
    }

    func testOnDeviceModelStoreImportsGGUFModel() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisp-tests-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = tempRoot.appendingPathComponent("Source", isDirectory: true)
        let modelDirectory = tempRoot.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceURL = sourceDirectory.appendingPathComponent("gemma-local.gguf")
        try Data("placeholder".utf8).write(to: sourceURL)

        let configuration = try WispOnDeviceModelStore(rootDirectory: modelDirectory)
            .importModel(from: sourceURL)

        XCTAssertEqual(configuration.modelName, "gemma-local")
        XCTAssertEqual(configuration.modelURL.lastPathComponent, "gemma-local.gguf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: configuration.modelURL.path))
    }

    func testBearerAuthenticationCanComeFromTokenOrEnvironment() {
        let tokenBackend = WispModelBackend(
            provider: .ollama,
            model: "gemma4",
            authentication: .bearerToken("local-secret")
        )
        XCTAssertEqual(tokenBackend.authorizationHeader(), "Bearer local-secret")

        let envBackend = WispModelBackend(
            provider: .openAICompatible,
            model: "gemma4",
            apiKeyEnvironmentVariable: "WISP_LOCAL_TOKEN"
        )
        XCTAssertEqual(envBackend.authorizationHeader(environment: ["WISP_LOCAL_TOKEN": "env-secret"]), "Bearer env-secret")
    }

    func testDiscoveredBackendBuildsModelBackend() {
        let discovered = WispDiscoveredBackend(
            name: "Studio Mac",
            host: "studio-mac.local",
            port: 8443,
            scheme: "https",
            path: "/v1",
            provider: .openAICompatible,
            model: "gemma4",
            requiresBearerToken: true
        )

        let backend = discovered.modelBackend(authentication: .bearerToken("secret"))

        XCTAssertEqual(discovered.baseURL, "https://studio-mac.local:8443/v1")
        XCTAssertEqual(backend.baseURL, discovered.baseURL)
        XCTAssertEqual(backend.authorizationHeader(), "Bearer secret")
        XCTAssertEqual(try backend.modelsURL().absoluteString, "https://studio-mac.local:8443/v1/models")
    }

    func testBonjourTXTRecordDecoding() {
        let txt = NetService.data(fromTXTRecord: [
            "scheme": Data("https".utf8),
            "provider": Data("ollama".utf8),
            "model": Data("gemma4".utf8),
            "path": Data("/v1".utf8),
            "auth": Data("bearer".utf8)
        ])

        XCTAssertEqual(WispBonjourBackendBrowser.decodeTXTRecord(txt)["provider"], "ollama")
        XCTAssertEqual(WispBonjourBackendBrowser.decodeTXTRecord(txt)["model"], "gemma4")
    }

    func testMarkdownTaskRendererIncludesPreludeAndTaskFields() throws {
        let renderer = WispMarkdownRenderer()
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-04-17T10:00:00Z"))

        let document = renderer.renderTask(
            title: "Dinner with Maya",
            summary: "Dinner with Maya at Rintaro.",
            content: "## Context #person/maya\n- Confirm the reservation.",
            due: "2026-04-18",
            time: "19:30",
            place: "Rintaro",
            date: date
        )

        XCTAssertTrue(document.contains("# Dinner with Maya"))
        XCTAssertTrue(document.contains("created: 2026-04-17"))
        XCTAssertTrue(document.contains("summary: Dinner with Maya at Rintaro."))
        XCTAssertTrue(document.contains("status: open"))
        XCTAssertTrue(document.contains("due: 2026-04-18"))
        XCTAssertTrue(document.contains("time: 19:30"))
        XCTAssertTrue(document.contains("place: Rintaro"))
    }

    func testAppFacadeCapturesScratchpadText() async throws {
        let facade = WispAppFacade()
        let item = try await facade.captureScratchpadText("  Follow up with Sean tomorrow.  ")
        let snapshot = await facade.currentSnapshot()

        XCTAssertEqual(item.text, "Follow up with Sean tomorrow.")
        XCTAssertEqual(snapshot.scratchpadItems, [item])
    }

    func testHealthClientChecksOpenAICompatibleModelsEndpoint() async {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer local-secret")
            XCTAssertEqual(request.url?.absoluteString, "http://192.168.1.42:11434/v1/models")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data(#"{"data":[{"id":"gemma4"}]}"#.utf8)
            return (response, data)
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = WispBackendHealthClient(urlSession: session)
        let backend = WispModelBackend(
            provider: .ollama,
            baseURL: "http://192.168.1.42:11434/v1",
            model: "gemma4",
            authentication: .bearerToken("local-secret")
        )

        let health = await client.check(backend)

        XCTAssertEqual(health.status, .reachable)
        XCTAssertEqual(health.statusCode, 200)
        XCTAssertEqual(health.models, ["gemma4"])
    }

    func testResponsesClientSendsPromptToResponsesEndpoint() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer api-secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")

            let body = try XCTUnwrap(Self.requestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["model"] as? String, "gpt-5.4")
            XCTAssertEqual(json?["input"] as? String, "Hello Wisp")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data(#"{"id":"resp_123","model":"gpt-5.4","output_text":"Hello from the model."}"#.utf8)
            return (response, data)
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = WispResponsesClient(urlSession: session)
        let backend = WispModelBackend(
            provider: .openAICompatible,
            model: "gpt-5.4",
            authentication: .bearerToken("api-secret")
        )

        let response = try await client.respond(to: "Hello Wisp", using: backend)

        XCTAssertEqual(response.id, "resp_123")
        XCTAssertEqual(response.model, "gpt-5.4")
        XCTAssertEqual(response.text, "Hello from the model.")
    }

    func testResponsesClientFallsBackToChatCompletions() async throws {
        var requestedURLs: [String] = []
        MockURLProtocol.handler = { request in
            requestedURLs.append(request.url?.absoluteString ?? "")
            if request.url?.path == "/v1/responses" {
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(#"{"error":"not found"}"#.utf8))
            }

            XCTAssertEqual(request.url?.absoluteString, "https://studio.tailnet.ts.net/v1/chat/completions")
            let body = try XCTUnwrap(Self.requestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["model"] as? String, "gemma4")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data(#"{"id":"chatcmpl_123","model":"gemma4","choices":[{"message":{"content":"Hello from Tailscale."}}]}"#.utf8)
            return (response, data)
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = WispResponsesClient(urlSession: session)
        let backend = WispModelBackend.tailscaleMac(
            baseURL: "https://studio.tailnet.ts.net/v1",
            model: "gemma4"
        )

        let response = try await client.respond(to: "Hello Wisp", using: backend)

        XCTAssertEqual(
            requestedURLs,
            [
                "https://studio.tailnet.ts.net/v1/responses",
                "https://studio.tailnet.ts.net/v1/chat/completions"
            ]
        )
        XCTAssertEqual(response.id, "chatcmpl_123")
        XCTAssertEqual(response.model, "gemma4")
        XCTAssertEqual(response.text, "Hello from Tailscale.")
    }

    private static func requestBodyData(from request: URLRequest) -> Data? {
        if let httpBody = request.httpBody {
            return httpBody
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let readCount = stream.read(&buffer, maxLength: buffer.count)
            if readCount > 0 {
                data.append(buffer, count: readCount)
            } else {
                break
            }
        }
        return data
    }
}

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
