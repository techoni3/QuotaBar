import Foundation

/// Errors a provider can surface, mapped onto HTTP semantics where applicable.
public enum ProviderError: Error, Equatable, Sendable {
    /// Missing/denied credentials — HUD shows a "Connect" affordance.
    case unauthorized(detail: String?)
    /// Credentials exist but are rejected (e.g. expired refresh token).
    case invalidCredentials
    /// HTTP 429 (or equivalent) with an optional server-provided delay.
    case rateLimited(retryAfter: TimeInterval?)
    /// Any other transient failure (network, 5xx, bad keychain state).
    case unavailable(String)
    /// The provider's local installation/credentials don't exist at all.
    case notInstalled

    /// Maps an HTTP status code (plus an optional Retry-After header value in
    /// seconds) onto a ProviderError.
    public static func http(status: Int, retryAfter: TimeInterval?) -> ProviderError {
        switch status {
        case 401, 403:
            return .unauthorized(detail: "HTTP \(status)")
        case 429:
            return .rateLimited(retryAfter: retryAfter)
        case 500...599:
            return .unavailable("HTTP \(status)")
        default:
            return .unavailable("HTTP \(status)")
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .unavailable: return true
        case .unauthorized, .invalidCredentials, .notInstalled: return false
        }
    }

    /// Short text for the HUD error line.
    public var displayText: String {
        switch self {
        case .unauthorized(let detail):
            return detail.map { "Not connected — \($0)" } ?? "Not connected"
        case .invalidCredentials:
            return "Credentials rejected — reconnect"
        case .rateLimited:
            return "Rate limited — backing off"
        case .unavailable(let detail):
            return "Unavailable — \(detail)"
        case .notInstalled:
            return "Not installed"
        }
    }
}

/// Common HTTP plumbing shared by providers.
struct HTTPResponse {
    let data: Data
    let status: Int
    let retryAfter: TimeInterval?

    /// Validates the status and returns the payload, throwing a mapped
    /// ProviderError for non-2xx responses.
    func validated() throws -> Data {
        guard (200..<300).contains(status) else {
            throw ProviderError.http(status: status, retryAfter: retryAfter)
        }
        return data
    }
}

enum HTTPOps {
    /// Performs a request and wraps the outcome in an HTTPResponse.
    static func send(_ request: URLRequest, session: URLSession) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.unavailable("non-HTTP response")
        }
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
            .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return HTTPResponse(data: data, status: http.statusCode, retryAfter: retryAfter)
    }
}
