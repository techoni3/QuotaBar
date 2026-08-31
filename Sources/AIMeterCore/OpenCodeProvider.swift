import Foundation

/// Supplies an API key for OpenCode's own usage API (Decision 3 pattern:
/// the CLI's own credential file is preferred, an explicitly imported key
/// from AIMeter's vault is the fallback).
public protocol OpenCodeTokenSource: Sendable {
    func accessToken() async throws -> String
}

/// Reads the OpenCode API key from `~/.local/share/opencode/auth.json`
/// (`$XDG_DATA_HOME/opencode/auth.json` honored; path injectable for sandbox
/// portability). Prefers the `opencode-go` (paid) entry over `opencode` (Zen).
public struct FileOpenCodeTokenSource: OpenCodeTokenSource {
    public let path: URL

    public init(explicitPath: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let explicitPath {
            path = explicitPath
        } else if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            path = URL(fileURLWithPath: xdg).appendingPathComponent("opencode/auth.json")
        } else {
            path = URL(fileURLWithPath: NSString(string: "~/.local/share/opencode/auth.json").expandingTildeInPath)
        }
    }

    public func accessToken() async throws -> String {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw ProviderError.notInstalled
        }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw ProviderError.unavailable("unreadable auth.json: \(error.localizedDescription)")
        }
        guard let file = try? JSONDecoder().decode(OpenCodeAuthFile.self, from: data) else {
            throw ProviderError.unavailable("unparsable OpenCode auth.json")
        }
        guard let key = file.apiKey else {
            throw ProviderError.unauthorized(detail: "no OpenCode API key in auth.json")
        }
        return key
    }
}

/// Reads an explicitly imported API key from AIMeter's own vault.
public struct VaultOpenCodeTokenSource: OpenCodeTokenSource {
    private let vault: any CredentialVault
    private let providerID: ProviderID

    public init(vault: any CredentialVault, providerID: ProviderID) {
        self.vault = vault
        self.providerID = providerID
    }

    public func accessToken() async throws -> String {
        guard let token = vault.fetchToken(for: providerID), !token.isEmpty else {
            throw ProviderError.unauthorized(detail: "no imported OpenCode key")
        }
        return token
    }
}

/// Tries each source in order and returns the first success.
public struct CompositeOpenCodeTokenSource: OpenCodeTokenSource {
    private let sources: [any OpenCodeTokenSource]

    public init(_ sources: [any OpenCodeTokenSource]) {
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
        throw lastError ?? ProviderError.unauthorized(detail: "no OpenCode token sources")
    }
}

/// Decoded `~/.local/share/opencode/auth.json`: map of provider → credential.
/// Only the `api`-type entries for `opencode` / `opencode-go` carry the Zen/Go
/// usage API key.
public struct OpenCodeAuthFile: Decodable {
    struct Credential: Decodable {
        let type: String?
        let key: String?
    }

    /// Dynamic-key container so non-object values (e.g. a `_comment` string) are
    /// skipped instead of failing the whole file.
    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private let credentials: [String: Credential]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var found: [String: Credential] = [:]
        for key in container.allKeys {
            if let entry = try? container.decodeIfPresent(Credential.self, forKey: key) {
                found[key.stringValue] = entry
            }
        }
        credentials = found
    }

    /// The first usable API key: `opencode-go` first (paid plan), then
    /// `opencode` (Zen). Returns nil when neither is an api-typed entry.
    public var apiKey: String? {
        for key in ["opencode-go", "opencode"] {
            if let entry = credentials[key], entry.type == "api", let apiKey = entry.key, !apiKey.isEmpty {
                return apiKey
            }
        }
        return nil
    }
}

/// OpenCode's own Go/Zen subscription quota:
/// `GET https://opencode.ai/zen/go/v1/usage` with `Authorization: Bearer <key>`.
/// Response shape per CodexBar/openusage docs:
/// `{"usage": {"rollingUsage": {"usagePercent": …, "resetInSec": …},
///             "weeklyUsage": {…}, "monthlyUsage": {…}}}`.
public struct OpenCodeProvider: AIProvider {
    public static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    public static let providerID = ProviderID("opencode")

    public let id = OpenCodeProvider.providerID
    public let displayName = "OpenCode (Go)"

    private let session: URLSession
    private let tokenSource: any OpenCodeTokenSource

    public init(session: URLSession = .shared, tokenSource: any OpenCodeTokenSource) {
        self.session = session
        self.tokenSource = tokenSource
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        let token = try await tokenSource.accessToken()
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await HTTPOps.send(request, session: session)
        let data = try response.validated()
        do {
            let decoded = try JSONDecoder().decode(OpenCodeUsageResponse.self, from: data)
            return decoded.snapshot()
        } catch {
            throw ProviderError.unavailable("unexpected OpenCode usage payload")
        }
    }
}

struct OpenCodeUsageResponse: Decodable {
    struct Window: Decodable {
        let usagePercent: Double
        let resetInSec: Int?

        enum CodingKeys: String, CodingKey {
            case usagePercent = "usagePercent"
            case resetInSec = "resetInSec"
        }
    }

    struct Usage: Decodable {
        let rollingUsage: Window?
        let weeklyUsage: Window?
        let monthlyUsage: Window?
    }

    let usage: Usage?

    func snapshot(now: Date = Date()) -> UsageSnapshot {
        var windows: [UsageWindow] = []
        func append(_ window: Window?, _ kind: WindowKind) {
            guard let window else { return }
            windows.append(UsageWindow(
                kind: kind,
                usedPercent: Self.clampedPercent(window.usagePercent),
                resetsAt: window.resetInSec.map { now.addingTimeInterval(TimeInterval($0)) }
            ))
        }
        append(usage?.rollingUsage, .session5h)
        append(usage?.weeklyUsage, .week7d)
        append(usage?.monthlyUsage, .month)
        return UsageSnapshot(planName: "OpenCode Go", windows: windows, fetchedAt: now)
    }

    static func clampedPercent(_ percent: Double) -> Int {
        min(100, max(0, Int(percent.rounded())))
    }
}