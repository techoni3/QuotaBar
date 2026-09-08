import Foundation

/// Read-only access to Pi's own credential file (`~/.pi/agent/auth.json`,
/// legacy `~/.pi/auth.json`). read-only by contract: AIMeter never writes to
/// `~/.pi`. Never log the returned secrets.
public protocol PiAuthReading: Sendable {
    /// API-key credential for a provider (the `key` field of api entries,
    /// e.g. opencode-go / ollama / openrouter).
    func apiKey(for provider: String) -> String?
    /// OAuth access token (the `access` field of oauth entries, e.g. antigravity).
    func accessToken(for provider: String) -> String?
    /// OAuth refresh token (the `refresh` field of oauth entries).
    func refreshToken(for provider: String) -> String?
    /// OAuth access token expiry (the `expires` field, Unix milliseconds).
    func expiryDate(for provider: String) -> Date?
    /// Optional provider account identifier (the `accountId` field).
    func accountID(for provider: String) -> String?
    /// One consistent OAuth entry snapshot. File-backed sources override this
    /// so a concurrent Pi refresh cannot mix fields from separate file reads.
    func oauthCredential(for provider: String) -> PiOAuthCredential?
}

/// Read-only OAuth credential snapshot from Pi's auth file.
public struct PiOAuthCredential: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiry: Date?
    public let accountID: String?

    public init(accessToken: String, refreshToken: String?, expiry: Date?, accountID: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiry = expiry
        self.accountID = accountID
    }
}

public extension PiAuthReading {
    /// Keeps existing conformers source-compatible when account metadata is
    /// unavailable.
    func accountID(for provider: String) -> String? { nil }

    /// Compatibility default for non-file test doubles. `FilePiAuthSource`
    /// overrides this with a single-read implementation.
    func oauthCredential(for provider: String) -> PiOAuthCredential? {
        guard let access = accessToken(for: provider), !access.isEmpty else { return nil }
        return PiOAuthCredential(
            accessToken: access,
            refreshToken: refreshToken(for: provider),
            expiry: expiryDate(for: provider),
            accountID: accountID(for: provider)
        )
    }
}

/// Decoded `~/.pi/agent/auth.json`: map of provider id → credential entry
/// `{type, key, access, refresh, expires, accountId}` (expires is Unix milliseconds).
/// Non-object entries (e.g. `_comment`) are skipped.
public struct PiAuthFile: Decodable, Equatable, Sendable {
    public struct Entry: Decodable, Equatable, Sendable {
        public let type: String?
        public let key: String?
        public let access: String?
        public let refresh: String?
        public let expires: Double?
        public let accountID: String?

        private enum CodingKeys: String, CodingKey {
            case type, key, access, refresh, expires
            case accountID = "accountId"
        }

        public init(type: String?, key: String?, access: String?, refresh: String?, expires: Double?, accountID: String? = nil) {
            self.type = type
            self.key = key
            self.access = access
            self.refresh = refresh
            self.expires = expires
            self.accountID = accountID
        }
    }

    public let entries: [String: Entry]

    /// Tolerant root decode: unknown non-object values are skipped so comment
    /// keys or partial writes never fail the whole file.
    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var found: [String: Entry] = [:]
        for key in container.allKeys {
            if let entry = try? container.decode(Entry.self, forKey: key) {
                found[key.stringValue] = entry
            }
        }
        entries = found
    }
}

/// Reads Pi's credential file from disk. Paths are injectable for sandbox
/// portability and tests; the agent path is tried first, then the legacy
/// `~/.pi/auth.json` when it exists.
public struct FilePiAuthSource: PiAuthReading {
    public let path: URL
    public let legacyPath: URL

    public init(explicitPath: URL? = nil, legacyExplicitPath: URL? = nil) {
        self.path = explicitPath
            ?? URL(fileURLWithPath: NSString(string: "~/.pi/agent/auth.json").expandingTildeInPath)
        self.legacyPath = legacyExplicitPath
            ?? URL(fileURLWithPath: NSString(string: "~/.pi/auth.json").expandingTildeInPath)
    }

    public func apiKey(for provider: String) -> String? {
        entry(for: provider).flatMap(\.key).flatMap { $0.isEmpty ? nil : $0 }
    }

    public func accessToken(for provider: String) -> String? {
        entry(for: provider).flatMap(\.access).flatMap { $0.isEmpty ? nil : $0 }
    }

    public func refreshToken(for provider: String) -> String? {
        entry(for: provider).flatMap(\.refresh).flatMap { $0.isEmpty ? nil : $0 }
    }

    public func expiryDate(for provider: String) -> Date? {
        Self.expiryDate(from: entry(for: provider)?.expires)
    }

    public func accountID(for provider: String) -> String? {
        entry(for: provider).flatMap(\.accountID).flatMap { $0.isEmpty ? nil : $0 }
    }

    public func oauthCredential(for provider: String) -> PiOAuthCredential? {
        guard let entry = entry(for: provider), entry.type == "oauth",
              let access = entry.access, !access.isEmpty else { return nil }
        return PiOAuthCredential(
            accessToken: access,
            refreshToken: entry.refresh.flatMap { $0.isEmpty ? nil : $0 },
            expiry: Self.expiryDate(from: entry.expires),
            accountID: entry.accountID.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private static func expiryDate(from milliseconds: Double?) -> Date? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private func entry(for provider: String) -> PiAuthFile.Entry? {
        load()?.entries[provider]
    }

    private func load() -> PiAuthFile? {
        for candidate in [path, legacyPath] where FileManager.default.fileExists(atPath: candidate.path) {
            guard let data = try? Data(contentsOf: candidate) else { continue }
            if let file = try? JSONDecoder().decode(PiAuthFile.self, from: data) {
                return file
            }
        }
        return nil
    }
}

/// Antigravity OAuth credential from Pi's credential file (auto-connect for
/// the remote path; injected between the local language-server probe and the
/// keychain live-read in the provider's source order).
///
/// Auto-refresh: when the Pi token is expired (expiry ≤ now+60s) and a
/// refresh token exists, the source refreshes via
/// `https://oauth2.googleapis.com/token` with the Antigravity public client
/// constants, updating access/expiry in-memory only (never writes to ~/.pi
/// and never logs tokens).
/// Pi-backed Antigravity token source with auto-refresh.
/// Reads `~/.pi/agent/auth.json` (or legacy) and, when the stored OAuth token
/// is expired (expiry ≤ now+60s) and a refresh token exists, refreshes via
/// `https://oauth2.googleapis.com/token` using the Antigravity public client
/// (`client_id`/`client_secret`). Refreshed access/expiry are cached
/// in-memory only and never written to `~/.pi` (and never logged).
public final class PiAntigravityTokenSource: @unchecked Sendable {
    public static let providerID = "antigravity"

    private let auth: any PiAuthReading
    private let refresher: (any AntigravityOAuthRefresher)?

    public init(auth: any PiAuthReading, refresher: (any AntigravityOAuthRefresher)? = nil) {
        self.auth = auth
        self.refresher = refresher
    }

    /// Synchronous file-only credentials (no network, no refresh) — kept for
    /// existing callers and tests that assert the on-disk shape.
    public var credentials: AntigravityOAuthCredentials? {
        guard let access = auth.accessToken(for: Self.providerID), !access.isEmpty else { return nil }
        return AntigravityOAuthCredentials(
            accessToken: access,
            expiry: auth.expiryDate(for: Self.providerID),
            refreshToken: auth.refreshToken(for: Self.providerID)
        )
    }

    /// Auto-refreshing credential load: checks expiry (≤60s), refreshes via
    /// the OAuth token endpoint with the Antigravity public client, and
    /// returns the new access/expiry. The caller is responsible for caching
    /// the result in-memory (provider's TokenCache) — never writes to
    /// `~/.pi`. Throws `ProviderError.unauthorized("Auth expired →
    /// Reconnect in Settings")` when the refresh fails so the caller can
    /// surface a clear Settings affordance instead of a silent hide.
    public func refreshedCredentials() async throws -> AntigravityOAuthCredentials? {
        guard let base = credentials else { return nil }
        guard let expiry = base.expiry, expiry <= Date().addingTimeInterval(60),
              let refresh = base.refreshToken, !refresh.isEmpty,
              let refresher else {
            return base
        }
        do {
            let refreshed = try await refresher.refresh(refreshToken: refresh)
            return AntigravityOAuthCredentials(
                accessToken: refreshed.accessToken,
                expiry: refreshed.expiresAt ?? Date().addingTimeInterval(3600),
                refreshToken: refreshed.refreshToken ?? refresh
            )
        } catch {
            throw ProviderError.unauthorized(detail: "Auth expired → Reconnect in Settings")
        }
    }
}

/// OpenCode API key from Pi's credential file (`opencode-go` preferred over
/// `opencode`) — sits between the OpenCode CLI's own auth.json and the vault
/// in the composite (File freshest > Pi > Vault).
public struct PiOpenCodeTokenSource: OpenCodeTokenSource {
    private let auth: any PiAuthReading

    public init(auth: any PiAuthReading) {
        self.auth = auth
    }

    public func accessToken() async throws -> String {
        if let key = auth.apiKey(for: "opencode-go"), !key.isEmpty { return key }
        if let key = auth.apiKey(for: "opencode"), !key.isEmpty { return key }
        throw ProviderError.unauthorized(detail: "no Pi OpenCode key")
    }
}