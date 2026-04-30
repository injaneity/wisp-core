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
}
