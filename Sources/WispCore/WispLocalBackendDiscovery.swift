import Foundation

public enum WispBonjourBackendDefaults {
    public static let serviceType = "_wisp-llm._tcp."
}

public struct WispDiscoveredBackend: Identifiable, Codable, Sendable, Equatable {
    public var id: String { baseURL }
    public var name: String
    public var serviceType: String
    public var host: String
    public var port: Int
    public var scheme: String
    public var path: String
    public var provider: WispModelProvider
    public var model: String
    public var requiresBearerToken: Bool

    public init(
        name: String,
        serviceType: String = WispBonjourBackendDefaults.serviceType,
        host: String,
        port: Int,
        scheme: String = "https",
        path: String = "/v1",
        provider: WispModelProvider = .openAICompatible,
        model: String = "gemma4",
        requiresBearerToken: Bool = true
    ) {
        self.name = name
        self.serviceType = serviceType
        self.host = host
        self.port = port
        self.scheme = scheme
        self.path = path.hasPrefix("/") ? path : "/" + path
        self.provider = provider
        self.model = model
        self.requiresBearerToken = requiresBearerToken
    }

    public var baseURL: String {
        "\(scheme)://\(host):\(port)\(path)"
    }

    public func modelBackend(authentication: WispBackendAuthentication = .none) -> WispModelBackend {
        WispModelBackend(
            provider: provider,
            baseURL: baseURL,
            model: model,
            authentication: authentication
        )
    }
}

@MainActor
public final class WispBonjourBackendBrowser: NSObject {
    public nonisolated static let defaultServiceType = WispBonjourBackendDefaults.serviceType

    private let serviceType: String
    private let domain: String
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var discovered: [WispDiscoveredBackend] = []

    public init(serviceType: String = WispBonjourBackendBrowser.defaultServiceType, domain: String = "local.") {
        self.serviceType = serviceType
        self.domain = domain
        super.init()
        browser.delegate = self
    }

    public func discover(timeoutSeconds: TimeInterval = 3) async -> [WispDiscoveredBackend] {
        services.removeAll(keepingCapacity: true)
        discovered.removeAll(keepingCapacity: true)
        browser.searchForServices(ofType: serviceType, inDomain: domain)
        let timeoutNanoseconds = UInt64(max(0.1, timeoutSeconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
        browser.stop()
        return discovered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public nonisolated static func makeDiscoveredBackend(from service: NetService, serviceType: String? = nil) -> WispDiscoveredBackend? {
        guard service.port > 0 else { return nil }
        let host = normalizedHost(service.hostName)
        guard !host.isEmpty else { return nil }

        let txt = decodeTXTRecord(service.txtRecordData())
        let scheme = txt["scheme"] ?? "https"
        let path = txt["path"] ?? "/v1"
        let provider = WispModelProvider(configValue: txt["provider"] ?? "openai_compatible")
        let model = txt["model"] ?? (provider == .codex ? "gpt-5.4" : "gemma4")
        let auth = (txt["auth"] ?? "bearer").lowercased()
        let requiresBearerToken = auth == "bearer" || auth == "token"

        return WispDiscoveredBackend(
            name: service.name,
            serviceType: serviceType ?? service.type,
            host: host,
            port: service.port,
            scheme: scheme,
            path: path,
            provider: provider,
            model: model,
            requiresBearerToken: requiresBearerToken
        )
    }

    public nonisolated static func decodeTXTRecord(_ data: Data?) -> [String: String] {
        guard let data else { return [:] }
        let raw = NetService.dictionary(fromTXTRecord: data)
        var result: [String: String] = [:]
        for (key, value) in raw {
            result[key] = String(data: value, encoding: .utf8)
        }
        return result
    }

    private nonisolated static func normalizedHost(_ hostName: String?) -> String {
        (hostName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}

extension WispBonjourBackendBrowser: @preconcurrency NetServiceBrowserDelegate {
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 == service }
        discovered.removeAll { $0.name == service.name }
    }
}

extension WispBonjourBackendBrowser: @preconcurrency NetServiceDelegate {
    public func netServiceDidResolveAddress(_ sender: NetService) {
        guard let backend = Self.makeDiscoveredBackend(from: sender, serviceType: serviceType),
              !discovered.contains(where: { $0.baseURL == backend.baseURL }) else {
            return
        }
        discovered.append(backend)
    }
}
