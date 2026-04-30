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
