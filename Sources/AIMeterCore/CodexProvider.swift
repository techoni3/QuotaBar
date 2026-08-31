import Foundation

/// In-memory store for tokens refreshed via the OAuth refresh flow.
/// We never write these back to Codex's own auth.json.
actor CodexTokenStore {
    private var token: RefreshedToken?

    func current() -> RefreshedToken? { token }
    func store(_ refreshed: RefreshedToken) { token = refreshed }
}

/// Codex (ChatGPT) subscription usage via
/// `GET https://chatgpt.com/backend-api/wham/usage`.
///
/// Response shape per winusage docs (reverse-engineered):
/// `{ "plan_type": "plus",
///    "rate_limit": {"primary_window": {"used_percent", "reset_at", "limit_window_seconds"},
///                   "secondary_window": {…}},
///    "code_review_rate_limit": {"primary_window": {…}}?,
///    "credits": {"has_credits", "unlimited", "balance"}? }`
///
/// Tokens come from `~/.codex/auth.json` (`$CODEX_HOME` honored). Refreshed
/// tokens are kept in memory only — we never mutate Codex's own auth.json.
public final class CodexProvider: AIProvider, @unchecked Sendable {
    public static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    public static let providerID = ProviderID("codex")

    public let id = CodexProvider.providerID
    public let displayName = "Codex (ChatGPT)"

    private let session: URLSession
    private let authReader: FileCodexAuthReader
    private let tokenRefresher: any TokenRefresher
    private let tokenFallback: (any CodexTokenFallback)?
    private let tokenStore = CodexTokenStore()

    public init(session: URLSession = .shared,
                authReader: FileCodexAuthReader = FileCodexAuthReader(),
                tokenRefresher: any TokenRefresher = OpenAITokenRefresher(),
                tokenFallback: (any CodexTokenFallback)? = nil) {
        self.session = session
        self.authReader = authReader
        self.tokenRefresher = tokenRefresher
        self.tokenFallback = tokenFallback
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        let credentials: CodexAuthFile
        do {
            credentials = try authReader.read()
        } catch ProviderError.notInstalled {
            // No ~/.codex/auth.json: fall back to an imported token in
            // AIMeter's vault (Decision 3 import flow), when provided.
            if let imported = tokenFallback?.importedAccessToken() {
                return try await fetchUsage(token: imported, accountID: nil)
            }
            throw ProviderError.notInstalled
        }
        guard let tokens = credentials.tokens, !tokens.accessToken.isEmpty else {
            // API-key-only auth.json can't call the ChatGPT backend API.
            // A vault-imported token is the fallback when configured.
            if let imported = tokenFallback?.importedAccessToken() {
                return try await fetchUsage(token: imported, accountID: nil)
            }
            throw ProviderError.unauthorized(detail: "no OAuth tokens in auth.json")
        }

        var accessToken = await tokenStore.current()?.accessToken ?? tokens.accessToken

        // Proactive refresh when the token is stale (>8 days since last_refresh,
        // per winusage/CodexBar docs). Best-effort: on refresh failure we still
        // try the existing token and surface its error.
        let lastRefresh = await tokenStore.current()?.issuedAt ?? credentials.lastRefresh
        if let lastRefresh,
           Date().timeIntervalSince(lastRefresh) > FileCodexAuthReader.stalenessLimit,
           let refreshToken = tokens.refreshToken {
            accessToken = (try? await performRefresh(refreshToken: refreshToken)) ?? accessToken
        }

        do {
            return try await fetchUsage(token: accessToken, accountID: tokens.accountID)
        } catch ProviderError.unauthorized where tokens.refreshToken != nil {
            // Access token rejected — refresh once in memory and retry.
            accessToken = try await performRefresh(refreshToken: tokens.refreshToken!)
            return try await fetchUsage(token: accessToken, accountID: tokens.accountID)
        }
    }

    private func fetchUsage(token: String, accountID: String?) async throws -> UsageSnapshot {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let response = try await HTTPOps.send(request, session: session)
        let data = try response.validated()
        do {
            let decoded = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
            return decoded.snapshot()
        } catch {
            throw ProviderError.unavailable("unexpected Codex usage payload")
        }
    }

    private func performRefresh(refreshToken: String) async throws -> String {
        let refreshed = try await tokenRefresher.refresh(refreshToken: refreshToken)
        await tokenStore.store(refreshed)
        return refreshed.accessToken
    }
}

/// Supplies a vault-imported access token as a fallback when the Codex CLI
/// credential file is missing (Decision 3 import flow).
public protocol CodexTokenFallback: Sendable {
    /// Returns an imported access token, or nil when none is stored.
    func importedAccessToken() -> String?
}

/// Reads the imported token from AIMeter's own keychain vault.
public struct VaultCodexTokenFallback: CodexTokenFallback {
    private let vault: any CredentialVault
    private let providerID: ProviderID

    public init(vault: any CredentialVault, providerID: ProviderID) {
        self.vault = vault
        self.providerID = providerID
    }

    public func importedAccessToken() -> String? {
        guard let token = vault.fetchToken(for: providerID), !token.isEmpty else { return nil }
        return token
    }
}

// MARK: - Response model

struct CodexUsageResponse: Decodable {
    struct Window: Decodable {
        let usedPercent: Int
        let resetAt: Date?
        let limitWindowSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = try c.decode(Int.self, forKey: .usedPercent)
            // reset_at is unix seconds when present.
            if let seconds = try c.decodeIfPresent(Int64.self, forKey: .resetAt) {
                resetAt = Date(timeIntervalSince1970: TimeInterval(seconds))
            } else {
                resetAt = nil
            }
            limitWindowSeconds = try c.decodeIfPresent(Int.self, forKey: .limitWindowSeconds)
        }
    }

    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    let planType: String?
    let rateLimit: RateLimit?
    let codeReviewRateLimit: RateLimit?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case codeReviewRateLimit = "code_review_rate_limit"
    }
}

extension CodexUsageResponse {
    func snapshot(now: Date = Date()) -> UsageSnapshot {
        var windows: [UsageWindow] = []
        if let primary = rateLimit?.primaryWindow {
            windows.append(UsageWindow(kind: .session5h,
                                       usedPercent: clamp(primary.usedPercent),
                                       resetsAt: primary.resetAt))
        }
        if let secondary = rateLimit?.secondaryWindow {
            windows.append(UsageWindow(kind: .week7d,
                                       usedPercent: clamp(secondary.usedPercent),
                                       resetsAt: secondary.resetAt))
        }
        if let codeReview = codeReviewRateLimit?.primaryWindow {
            windows.append(UsageWindow(kind: .week7d,
                                       usedPercent: clamp(codeReview.usedPercent),
                                       resetsAt: codeReview.resetAt,
                                       label: "Code review"))
        }
        return UsageSnapshot(planName: Self.planName(planType), windows: windows, fetchedAt: now)
    }

    private func clamp(_ percent: Int) -> Int { min(100, max(0, percent)) }

    static func planName(_ planType: String?) -> String? {
        guard let planType else { return nil }
        switch planType.lowercased() {
        case "free": return "ChatGPT Free"
        case "plus": return "ChatGPT Plus"
        case "pro": return "ChatGPT Pro"
        case "team": return "ChatGPT Team"
        case "enterprise": return "ChatGPT Enterprise"
        default: return "ChatGPT \(planType.replacingOccurrences(of: "_", with: " ").capitalized)"
        }
    }
}
