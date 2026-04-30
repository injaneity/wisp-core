import Foundation

public enum WispCoreError: Error, CustomStringConvertible, Equatable {
    case invalidBaseURL(String)
    case invalidPath(String)
    case emptyText(String)
    case unsupportedBackend(String)

    public var description: String {
        switch self {
        case .invalidBaseURL(let value):
            "Invalid base URL: \(value)"
        case .invalidPath(let value):
            "Invalid path: \(value)"
        case .emptyText(let field):
            "\(field) must be non-empty"
        case .unsupportedBackend(let message):
            message
        }
    }
}
