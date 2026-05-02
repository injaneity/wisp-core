import Foundation

public struct WispModelResponse: Codable, Sendable, Equatable {
    public var id: String?
    public var model: String
    public var text: String

    public init(id: String? = nil, model: String, text: String) {
        self.id = id
        self.model = model
        self.text = text
    }
}

public enum WispResponsesClientError: Error, CustomStringConvertible, Equatable {
    case invalidHTTPStatus(Int, String)
    case missingResponseText

    public var description: String {
        switch self {
        case .invalidHTTPStatus(let statusCode, let body):
            "Server returned HTTP \(statusCode): \(body)"
        case .missingResponseText:
            "Server response did not include assistant text."
        }
    }
}

public struct WispResponsesClient: @unchecked Sendable {
    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func respond(to prompt: String, using backend: WispModelBackend) async throws -> WispModelResponse {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw WispCoreError.emptyText("prompt")
        }

        do {
            return try await performResponsesRequest(prompt: trimmedPrompt, using: backend)
        } catch let error as WispResponsesClientError where shouldFallbackToChatCompletions(after: error) {
            return try await performChatCompletionsRequest(prompt: trimmedPrompt, using: backend)
        }
    }

    private func performResponsesRequest(prompt: String, using backend: WispModelBackend) async throws -> WispModelResponse {
        var request = URLRequest(url: try backend.responsesURL())
        request.httpMethod = "POST"
        applyStandardHeaders(to: &request, backend: backend)
        request.httpBody = try JSONEncoder().encode(ResponsesRequest(model: backend.model, input: prompt))

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WispResponsesClientError.invalidHTTPStatus(-1, "Server did not return an HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw WispResponsesClientError.invalidHTTPStatus(http.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(ResponsesResponse.self, from: data)
        guard let text = decoded.extractedText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw WispResponsesClientError.missingResponseText
        }

        return WispModelResponse(
            id: decoded.id,
            model: decoded.model ?? backend.model,
            text: text
        )
    }

    private func performChatCompletionsRequest(prompt: String, using backend: WispModelBackend) async throws -> WispModelResponse {
        var request = URLRequest(url: try backend.chatCompletionsURL())
        request.httpMethod = "POST"
        applyStandardHeaders(to: &request, backend: backend)
        request.httpBody = try JSONEncoder().encode(
            ChatCompletionsRequest(
                model: backend.model,
                messages: [
                    ChatCompletionsRequest.Message(role: "user", content: prompt)
                ]
            )
        )

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WispResponsesClientError.invalidHTTPStatus(-1, "Server did not return an HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw WispResponsesClientError.invalidHTTPStatus(http.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        guard let text = decoded.extractedText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw WispResponsesClientError.missingResponseText
        }

        return WispModelResponse(
            id: decoded.id,
            model: decoded.model ?? backend.model,
            text: text
        )
    }

    private func applyStandardHeaders(to request: inout URLRequest, backend: WispModelBackend) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("wisp", forHTTPHeaderField: "User-Agent")
        if let authorizationHeader = backend.authorizationHeader() {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }
    }

    private func shouldFallbackToChatCompletions(after error: WispResponsesClientError) -> Bool {
        guard case .invalidHTTPStatus(let statusCode, _) = error else {
            return false
        }
        return [404, 405, 501].contains(statusCode)
    }
}

private struct ResponsesRequest: Encodable {
    let model: String
    let input: String
}

private struct ChatCompletionsRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
}

private struct ResponsesResponse: Decodable {
    struct OutputItem: Decodable {
        struct Content: Decodable {
            let text: String?
        }

        let content: [Content]?
    }

    let id: String?
    let model: String?
    let outputText: String?
    let output: [OutputItem]?

    enum CodingKeys: String, CodingKey {
        case id
        case model
        case outputText = "output_text"
        case output
    }

    var extractedText: String? {
        if let outputText {
            return outputText
        }
        let text = output?
            .compactMap(\.content)
            .flatMap { $0 }
            .compactMap(\.text)
            .joined(separator: "\n")
        return text?.isEmpty == false ? text : nil
    }
}

private struct ChatCompletionsResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message?
        let text: String?
    }

    let id: String?
    let model: String?
    let choices: [Choice]

    var extractedText: String? {
        let text = choices
            .compactMap { choice in
                choice.message?.content ?? choice.text
            }
            .joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}
