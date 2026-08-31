import Foundation
import Security

/// Supplies an access token for the Claude OAuth usage API.
///
/// Per spec Decision 3 the preferred path is a live keychain read of Claude
/// Code's own item (with the system ACL prompt); an explicitly imported token
/// from AIMeter's vault is the fallback.
public protocol ClaudeTokenSource: Sendable {
    func accessToken() async throws -> String
}

/// Tries each source in order and returns the first success.
public struct CompositeClaudeTokenSource: ClaudeTokenSource {
    private let sources: [any ClaudeTokenSource]

    public init(_ sources: [any ClaudeTokenSource]) {
        self.sources = sources
    }

    public func accessToken() async throws -> String {
        var lastError: ProviderError?
        for source in sources {
            do {
                return try await source.accessToken()
            } catch let error as ProviderError {
                lastError = error
            }
        }
        throw lastError ?? ProviderError.unauthorized(detail: "no token sources")
    }
}

/// Live-reads Claude Code's keychain item `Claude Code-credentials`.
///
/// The item holds JSON like:
/// `{"claudeAiOauth": {"access_token": "sk-ant-oat01-…", "refresh_token": "…",
///   "expiresAt": 1788000000000, "scopes": ["user:profile", …]}}`
/// (On Claude Code 2.1.x the item may contain only `mcpOAuth` with no
/// `claudeAiOauth` — that means the user must re-auth; we surface unauthorized
/// so the HUD offers the import fallback. Per CodexBar docs #1844.)
public struct LiveKeychainClaudeTokenSource: ClaudeTokenSource {
    /// Claude Code's keychain service name.
    public static let defaultService = "Claude Code-credentials"

    private let service: String

    public init(service: String = LiveKeychainClaudeTokenSource.defaultService) {
        self.service = service
    }

    public func accessToken() async throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            // No Claude Code login on this machine → import fallback.
            throw ProviderError.unauthorized(detail: "no Claude Code keychain entry")
        case errSecInteractionNotAllowed, errSecAuthFailed:
            // ACL prompt denied or keychain locked → user can import instead.
            throw ProviderError.unauthorized(detail: "keychain access denied")
        default:
            throw ProviderError.unavailable("keychain error \(status)")
        }
        guard let data = out as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["access_token"] as? String,
              !token.isEmpty
        else {
            // mcpOAuth-only item (Claude Code 2.1.x) → needs re-auth/import.
            throw ProviderError.unauthorized(detail: "keychain entry has no Claude OAuth token")
        }
        return token
    }
}

/// Reads an explicitly imported token from AIMeter's own vault.
public struct VaultClaudeTokenSource: ClaudeTokenSource {
    private let vault: any CredentialVault
    private let providerID: ProviderID

    public init(vault: any CredentialVault, providerID: ProviderID) {
        self.vault = vault
        self.providerID = providerID
    }

    public func accessToken() async throws -> String {
        guard let token = vault.fetchToken(for: providerID), !token.isEmpty else {
            throw ProviderError.unauthorized(detail: "no imported token")
        }
        return token
    }
}
