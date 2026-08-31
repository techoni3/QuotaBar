import Foundation

/// Decoded `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`).
/// Shape per winusage/CodexBar docs:
/// `{ "OPENAI_API_KEY": null, "tokens": { "access_token", "refresh_token",
///    "id_token", "account_id" }, "last_refresh": "2026-01-28T08:05:37Z" }`
public struct CodexAuthFile: Equatable, Sendable {
    public struct Tokens: Equatable, Sendable {
        public let accessToken: String
        public let refreshToken: String?
        public let idToken: String?
        public let accountID: String?

        public init(accessToken: String, refreshToken: String?, idToken: String?, accountID: String?) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.idToken = idToken
            self.accountID = accountID
        }
    }

    public let tokens: Tokens?
    public let lastRefresh: Date?

    public init(tokens: Tokens?, lastRefresh: Date?) {
        self.tokens = tokens
        self.lastRefresh = lastRefresh
    }

    private enum RootKeys: String, CodingKey {
        case openAIAPIKey = "OPENAI_API_KEY"
        case tokens
        case lastRefresh = "last_refresh"
    }

    private enum TokenKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case accountID = "account_id"
    }
}

extension CodexAuthFile: Decodable {
    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        var decodedTokens: Tokens?
        if root.contains(.tokens) {
            // "tokens" can be an explicit JSON null on API-key-only setups;
            // treat null/absent the same (no OAuth tokens available).
            if let t = try? root.nestedContainer(keyedBy: TokenKeys.self, forKey: .tokens) {
                let access = try t.decodeIfPresent(String.self, forKey: .accessToken) ?? ""
                decodedTokens = Tokens(
                    accessToken: access,
                    refreshToken: try t.decodeIfPresent(String.self, forKey: .refreshToken),
                    idToken: try t.decodeIfPresent(String.self, forKey: .idToken),
                    accountID: try t.decodeIfPresent(String.self, forKey: .accountID)
                )
            }
        }
        tokens = decodedTokens
        lastRefresh = try root.decodeIfPresent(Date.self, forKey: .lastRefresh)
    }
}

/// ISO8601 date decoding that tolerates fractional seconds.
enum ISO8601Dates {
    private nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let plain = ISO8601DateFormatter()

    static func parse(_ string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }

    static func format(_ date: Date) -> String {
        plain.string(from: date)
    }
}

extension JSONEncoder {
    /// ISO8601 dates written as strings, the mirror image of
    /// `JSONDecoder.flexibleISO8601` so cached payloads round-trip exactly.
    public static var flexibleISO8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601Dates.format(date))
        }
        return encoder
    }
}

extension JSONDecoder {
    /// ISO8601 dates with fractional-seconds tolerance.
    public static var flexibleISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = ISO8601Dates.parse(string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "bad ISO8601 date: \(string)")
            }
            return date
        }
        return decoder
    }
}

/// Reads the Codex CLI credential file. Path is injectable for sandbox
/// portability (spec Risk §10): explicit path wins, then `$CODEX_HOME`,
/// then `~/.codex/auth.json`.
public struct FileCodexAuthReader: Sendable {
    public static let stalenessLimit: TimeInterval = 8 * 24 * 3_600

    public let path: URL

    public init(explicitPath: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let explicitPath {
            path = explicitPath
        } else if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            path = URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")
        } else {
            path = URL(fileURLWithPath: NSString(string: "~/.codex/auth.json").expandingTildeInPath)
        }
    }

    public func read() throws -> CodexAuthFile {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw ProviderError.notInstalled
        }
        do {
            let data = try Data(contentsOf: path)
            return try JSONDecoder.flexibleISO8601.decode(CodexAuthFile.self, from: data)
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.unavailable("unreadable auth.json: \(error.localizedDescription)")
        }
    }
}
