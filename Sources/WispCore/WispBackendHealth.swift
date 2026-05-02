import Foundation

public enum WispBackendConnectionStatus: String, Codable, Sendable, Equatable {
    case idle
    case checking
    case reachable
    case unauthorized
    case invalidResponse = "invalid_response"
    case unreachable
}

public struct WispBackendHealth: Codable, Sendable, Equatable {
    public var backend: WispModelBackend
    public var status: WispBackendConnectionStatus
    public var checkedAt: Date
    public var latencyMilliseconds: Int?
    public var statusCode: Int?
    public var models: [String]
    public var message: String

    public init(
        backend: WispModelBackend,
        status: WispBackendConnectionStatus,
        checkedAt: Date = Date(),
        latencyMilliseconds: Int? = nil,
        statusCode: Int? = nil,
        models: [String] = [],
        message: String
    ) {
        self.backend = backend
        self.status = status
        self.checkedAt = checkedAt
        self.latencyMilliseconds = latencyMilliseconds
        self.statusCode = statusCode
        self.models = models
        self.message = message
    }
}

public struct WispBackendHealthClient: @unchecked Sendable {
    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func check(_ backend: WispModelBackend) async -> WispBackendHealth {
        let started = Date()
        let modelsURL: URL
        do {
            modelsURL = try backend.modelsURL()
        } catch {
            return WispBackendHealth(
                backend: backend,
                status: .invalidResponse,
                checkedAt: Date(),
                latencyMilliseconds: elapsedMilliseconds(since: started),
                message: String(describing: error)
            )
        }

        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("wisp", forHTTPHeaderField: "User-Agent")
        if let authorizationHeader = backend.authorizationHeader() {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return WispBackendHealth(
                    backend: backend,
                    status: .invalidResponse,
                    checkedAt: Date(),
                    latencyMilliseconds: elapsedMilliseconds(since: started),
                    message: "Server did not return an HTTP response."
                )
            }

            if http.statusCode == 401 || http.statusCode == 403 {
                return WispBackendHealth(
                    backend: backend,
                    status: .unauthorized,
                    checkedAt: Date(),
                    latencyMilliseconds: elapsedMilliseconds(since: started),
                    statusCode: http.statusCode,
                    message: "Server rejected the configured credentials."
                )
            }

            guard (200..<300).contains(http.statusCode) else {
                return WispBackendHealth(
                    backend: backend,
                    status: .unreachable,
                    checkedAt: Date(),
                    latencyMilliseconds: elapsedMilliseconds(since: started),
                    statusCode: http.statusCode,
                    message: "Server returned HTTP \(http.statusCode)."
                )
            }

            let models = (try? JSONDecoder().decode(OpenAIModelsResponse.self, from: data).data.map(\.id)) ?? []
            return WispBackendHealth(
                backend: backend,
                status: .reachable,
                checkedAt: Date(),
                latencyMilliseconds: elapsedMilliseconds(since: started),
                statusCode: http.statusCode,
                models: models,
                message: models.isEmpty ? "Server is reachable." : "Server is reachable with \(models.count) model(s)."
            )
        } catch {
            return WispBackendHealth(
                backend: backend,
                status: .unreachable,
                checkedAt: Date(),
                latencyMilliseconds: elapsedMilliseconds(since: started),
                message: error.localizedDescription
            )
        }
    }

    private func elapsedMilliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1_000))
    }
}

private struct OpenAIModelsResponse: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]
}

public actor WispBackendMonitor {
    private let healthClient: WispBackendHealthClient
    private var latestHealth: WispBackendHealth?

    public init(healthClient: WispBackendHealthClient = WispBackendHealthClient()) {
        self.healthClient = healthClient
    }

    @discardableResult
    public func check(_ backend: WispModelBackend) async -> WispBackendHealth {
        let health = await healthClient.check(backend)
        latestHealth = health
        return health
    }

    public func currentHealth() -> WispBackendHealth? {
        latestHealth
    }
}
