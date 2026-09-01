import Foundation

/// Result of an OAuth token refresh.
public struct RefreshedToken: Equatable, Sendable {
    public let accessToken: String
    /// Some providers rotate the refresh token; nil means keep the old one.
    public let refreshToken: String?
    public let issuedAt: Date
    /// Expiry computed from `expires_in` when the provider returns it.
    public let expiresAt: Date?

    public init(accessToken: String, refreshToken: String?, issuedAt: Date = Date(), expiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

/// Refreshes an OAuth access token from a refresh token.
public protocol TokenRefresher: Sendable {
    func refresh(refreshToken: String) async throws -> RefreshedToken
}

/// OpenAI OAuth refresh via auth.openai.com.
///
/// IMPORTANT: refreshed tokens are held in memory only — we never write back
/// to `~/.codex/auth.json` because Codex CLI owns that file and cross-writer
/// mutation can corrupt its credential state (see CodexBar docs, "publish
/// contract" caution).
public struct OpenAITokenRefresher: TokenRefresher {
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func refresh(refreshToken: String) async throws -> RefreshedToken {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "refresh_token", value: refreshToken),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let response = try await HTTPOps.send(request, session: session)
        let data = try response.validated()
        struct RefreshResponse: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: Double?
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
            }
        }
        let decoded = try JSONDecoder().decode(RefreshResponse.self, from: data)
        let now = Date()
        let expiresAt = decoded.expiresIn.map { now.addingTimeInterval($0) }
        return RefreshedToken(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken ?? refreshToken,
            issuedAt: now,
            expiresAt: expiresAt
        )
    }
}
