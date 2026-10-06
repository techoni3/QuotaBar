import Foundation

/// OAuth application credentials are supplied locally, never embedded in source.
/// These must belong to the client that issued the account's refresh token.
public struct AntigravityOAuthClient: Sendable {
    public let clientID: String
    public let clientSecret: String

    public init?(clientID: String, clientSecret: String) {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        self.clientID = id
        self.clientSecret = secret
    }

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AntigravityOAuthClient? {
        guard let id = environment["AIMETER_ANTIGRAVITY_CLIENT_ID"],
              let secret = environment["AIMETER_ANTIGRAVITY_CLIENT_SECRET"] else { return nil }
        return AntigravityOAuthClient(clientID: id, clientSecret: secret)
    }
}
