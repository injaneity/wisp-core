import Foundation

enum CodexOAuth {
    private static let authClaimPath = "https://api.openai.com/auth"

    static func resolveResponsesURL(baseURL: String) throws -> URL {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = raw.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let urlString: String
        if normalized.hasSuffix("/codex/responses") {
            urlString = normalized
        } else if normalized.hasSuffix("/codex") {
            urlString = normalized + "/responses"
        } else {
            urlString = normalized + "/codex/responses"
        }
        guard let url = URL(string: urlString) else {
            throw AppError.io("Invalid Codex base URL: \(baseURL)")
        }
        return url
    }

    static func buildSSEHeaders(token: String, sessionID: String) throws -> [String: String] {
        let accountID = try extractAccountID(from: token)
        let userAgent: String = {
            let p = ProcessInfo.processInfo
            return "wisp (\(p.operatingSystemVersionString))"
        }()
        return [
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
            "Authorization": "Bearer \(token)",
            "OpenAI-Beta": "responses=experimental",
            "chatgpt-account-id": accountID,
            "originator": "wisp",
            "User-Agent": userAgent,
            "session_id": sessionID,
            "x-client-request-id": sessionID
        ]
    }

    private static func extractAccountID(from jwt: String) throws -> String {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else {
            throw AppError.requestFailed("Invalid Codex OAuth token format")
        }
        let payloadPart = String(parts[1])
        guard let payloadData = decodeBase64URL(payloadPart),
              let payloadObject = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let authObject = payloadObject[authClaimPath] as? [String: Any],
              let accountID = authObject["chatgpt_account_id"] as? String,
              !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.requestFailed("Could not extract chatgpt_account_id from Codex OAuth token")
        }
        return accountID
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - (base64.count % 4)) % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: padding)
        }
        return Data(base64Encoded: base64)
    }
}
