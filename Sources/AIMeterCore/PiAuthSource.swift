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
}

/// Decoded `~/.pi/agent/auth.json`: map of provider id → credential entry
/// `{type, key, access, refresh, expires}` (expires is Unix milliseconds).
/// Non-object entries (e.g. `_comment`) are skipped.
public struct PiAuthFile: Decodable, Equatable, Sendable {
    public struct Entry: Decodable, Equatable, Sendable {
        public let type: String?
        public let key: String?
        public let access: String?
        public let refresh: String?
        public let expires: Double?

        public init(type: String?, key: String?, access: String?, refresh: String?, expires: Double?) {
            self.type = type
            self.key = key
            self.access = access
            self.refresh = refresh
            self.expires = expires
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