import Foundation

private enum CodexCredentialSource: Sendable {
    case pi
    case nativeFile
    case vault
}

private struct CodexUsageCredential: Sendable {
    let source: CodexCredentialSource
    let accessToken: String
    let refreshToken: String?
    let accountID: String?
    let expiry: Date?
    let lastRefresh: Date?
}

/// In-memory store for tokens refreshed via the OAuth refresh flow.
/// Source-tagging prevents a Pi refresh from overriding a later native-file
/// fallback (or vice versa). We never write refreshed credentials to disk.
private actor CodexTokenStore {
    private var token: RefreshedToken?
    private var source: CodexCredentialSource?
    private var sourceAccessToken: String?

    func current(for source: CodexCredentialSource,
                 sourceAccessToken: String) -> RefreshedToken? {
        self.source == source && self.sourceAccessToken == sourceAccessToken ? token : nil
    }

    func store(_ refreshed: RefreshedToken,
               for source: CodexCredentialSource,
               sourceAccessToken: String) {
        token = refreshed
        self.source = source
        self.sourceAccessToken = sourceAccessToken
    }
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
/// The primary/secondary field names are positional, not semantic. The
/// reported duration is authoritative when present because a weekly-only
/// account can return its 7-day window as `primary_window`.
///
/// Tokens prefer Pi's `openai-codex` OAuth entry, then
/// `~/.codex/auth.json` (`$CODEX_HOME` honored), then AIMeter's vault import.
/// Refreshed tokens are kept in memory only — we never mutate credential files.
public final class CodexProvider: AIProvider, @unchecked Sendable {
    public static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    public static let providerID = ProviderID("codex")

    public let id = CodexProvider.providerID
    public let displayName = "Codex (ChatGPT)"

    /// Pi refreshes OAuth credentials with less than five minutes remaining.
    /// Match that threshold while keeping AIMeter's refresh in memory only.
    public static let piRefreshWindow: TimeInterval = 5 * 60

    private let session: URLSession
    private let authReader: FileCodexAuthReader
    private let piAuth: (any PiAuthReading)?
    private let tokenRefresher: any TokenRefresher
    private let tokenFallback: (any CodexTokenFallback)?
    private let tokenStore = CodexTokenStore()

    public init(session: URLSession = .shared,
                authReader: FileCodexAuthReader = FileCodexAuthReader(),
                piAuth: (any PiAuthReading)? = nil,
                tokenRefresher: any TokenRefresher = OpenAITokenRefresher(),
                tokenFallback: (any CodexTokenFallback)? = nil) {
        self.session = session
        self.authReader = authReader
        self.piAuth = piAuth
        self.tokenRefresher = tokenRefresher
        self.tokenFallback = tokenFallback
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        let credentials = try resolveCredentials()
        let cached = await tokenStore.current(for: credentials.source,
                                              sourceAccessToken: credentials.accessToken)
        var accessToken = cached?.accessToken ?? credentials.accessToken
        var refreshToken = cached?.refreshToken ?? credentials.refreshToken
        var didRefresh = false

        let shouldRefreshPi = credentials.source == .pi
            && (cached?.expiresAt ?? credentials.expiry).map {
                $0 <= Date().addingTimeInterval(Self.piRefreshWindow)
            } == true
        let shouldRefreshNative = credentials.source == .nativeFile
            && (cached?.issuedAt ?? credentials.lastRefresh).map {
                Date().timeIntervalSince($0) > FileCodexAuthReader.stalenessLimit
            } == true

        // Best-effort proactive refresh: an access token near its threshold can
        // still be accepted. If refresh fails, try the token and let its HTTP
        // result determine the provider state.
        if (shouldRefreshPi || shouldRefreshNative), let currentRefreshToken = refreshToken {
            if let refreshed = try? await performRefresh(refreshToken: currentRefreshToken,
                                                           source: credentials.source,
                                                           sourceAccessToken: credentials.accessToken) {
                accessToken = refreshed.accessToken
                refreshToken = refreshed.refreshToken ?? currentRefreshToken
                didRefresh = true
            }
        }

        do {
            return try await fetchUsage(token: accessToken, accountID: credentials.accountID)
        } catch ProviderError.unauthorized where refreshToken != nil && !didRefresh {
            // Access token rejected — refresh once in memory and retry.
            let refreshed = try await performRefresh(refreshToken: refreshToken!,
                                                       source: credentials.source,
                                                       sourceAccessToken: credentials.accessToken)
            return try await fetchUsage(token: refreshed.accessToken, accountID: credentials.accountID)
        }
    }

    private func resolveCredentials() throws -> CodexUsageCredential {
        if let pi = piAuth?.oauthCredential(for: "openai-codex") {
            return CodexUsageCredential(
                source: .pi,
                accessToken: pi.accessToken,
                refreshToken: pi.refreshToken,
                accountID: pi.accountID,
                expiry: pi.expiry,
                lastRefresh: nil
            )
        }

        do {
            let credentials = try authReader.read()
            if let tokens = credentials.tokens, !tokens.accessToken.isEmpty {
                return CodexUsageCredential(
                    source: .nativeFile,
                    accessToken: tokens.accessToken,
                    refreshToken: tokens.refreshToken,
                    accountID: tokens.accountID,
                    expiry: nil,
                    lastRefresh: credentials.lastRefresh
                )
            }
            if let imported = tokenFallback?.importedAccessToken() {
                return vaultCredential(imported)
            }
            throw ProviderError.unauthorized(detail: "no OAuth tokens in auth.json")
        } catch ProviderError.notInstalled {
            if let imported = tokenFallback?.importedAccessToken() {
                return vaultCredential(imported)
            }
            throw ProviderError.notInstalled
        }
    }

    private func vaultCredential(_ accessToken: String) -> CodexUsageCredential {
        CodexUsageCredential(source: .vault,
                             accessToken: accessToken,
                             refreshToken: nil,
                             accountID: nil,
                             expiry: nil,
                             lastRefresh: nil)
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

    private func performRefresh(refreshToken: String,
                                source: CodexCredentialSource,
                                sourceAccessToken: String) async throws -> RefreshedToken {
        let refreshed = try await tokenRefresher.refresh(refreshToken: refreshToken)
        await tokenStore.store(refreshed, for: source, sourceAccessToken: sourceAccessToken)
        return refreshed
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
            windows.append(UsageWindow(kind: kind(for: primary, fallback: .session5h),
                                       usedPercent: clamp(primary.usedPercent),
                                       resetsAt: primary.resetAt))
        }
        if let secondary = rateLimit?.secondaryWindow {
            windows.append(UsageWindow(kind: kind(for: secondary, fallback: .week7d),
                                       usedPercent: clamp(secondary.usedPercent),
                                       resetsAt: secondary.resetAt))
        }
        if let codeReview = codeReviewRateLimit?.primaryWindow {
            windows.append(UsageWindow(kind: kind(for: codeReview, fallback: .week7d),
                                       usedPercent: clamp(codeReview.usedPercent),
                                       resetsAt: codeReview.resetAt,
                                       label: "Code review"))
        }
        return UsageSnapshot(planName: Self.planName(planType), windows: windows, fetchedAt: now)
    }

    /// Codex can move a quota between primary/secondary, so classify known
    /// windows by their reported duration instead of by their slot. Preserve
    /// the old slot fallback for unknown or legacy payloads.
    private func kind(for window: Window, fallback: WindowKind) -> WindowKind {
        switch window.limitWindowSeconds {
        case 18_000: return .session5h       // 5 hours
        case 604_800: return .week7d          // 7 days
        case 2_592_000: return .month         // 30 days
        default: return fallback
        }
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
