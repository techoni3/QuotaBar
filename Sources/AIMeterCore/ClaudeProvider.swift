import Foundation

/// Claude (claude-code) subscription usage via the OAuth usage API:
/// `GET https://api.anthropic.com/api/oauth/usage` with
/// `anthropic-beta: oauth-2025-04-20`.
///
/// Response shape (per CodexBar docs + tae0y/claude-usage-menubar):
/// `{ "five_hour": {"utilization": 27.5, "resets_at": "…Z"}, "seven_day": {…},
///    "seven_day_opus"?, "seven_day_sonnet"?, "seven_day_routines"?,
///    "seven_day_cowork"?, "subscriptionType"?, "rate_limit_tier"?,
///    "extra_usage": {"is_enabled", "monthly_limit", "used_monthly", "currency"}? }`
public struct ClaudeProvider: AIProvider {
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let providerID = ProviderID("claude")

    public let id = ClaudeProvider.providerID
    public let displayName = "Claude"

    private let session: URLSession
    private let tokenSource: any ClaudeTokenSource

    public init(session: URLSession = .shared, tokenSource: any ClaudeTokenSource) {
        self.session = session
        self.tokenSource = tokenSource
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        let token = try await tokenSource.accessToken()
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await HTTPOps.send(request, session: session)
        let data = try response.validated()
        do {
            let decoded = try JSONDecoder.flexibleISO8601.decode(ClaudeUsageResponse.self, from: data)
            return decoded.snapshot()
        } catch {
            throw ProviderError.unavailable("unexpected Claude usage payload")
        }
    }
}

// MARK: - Response model

struct ClaudeUsageResponse: Decodable {
    struct Window: Decodable {
        let utilization: Double
        let resetsAt: Date?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    struct ExtraUsage: Decodable {
        let isEnabled: Bool?
        let monthlyLimit: Double?
        let usedMonthly: Double?
        let currency: String?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case monthlyLimit = "monthly_limit"
            case usedMonthly = "used_monthly"
            case currency
        }
    }

    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDayOpus: Window?
    let sevenDaySonnet: Window?
    let sevenDayRoutines: Window?
    let sevenDayCowork: Window?
    let subscriptionType: String?
    let rateLimitTier: String?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayRoutines = "seven_day_routines"
        case sevenDayCowork = "seven_day_cowork"
        case subscriptionType
        case rateLimitTier = "rate_limit_tier"
        case extraUsage = "extra_usage"
    }
}

extension ClaudeUsageResponse {
    /// Maps the payload onto a UsageSnapshot. Model-specific weekly windows are
    /// preserved as labeled `week7d` windows (per CodexBar mapping; the shared
    /// pools share the main weekly limit, so only labeled extras are kept).
    func snapshot(now: Date = Date()) -> UsageSnapshot {
        var windows: [UsageWindow] = []
        func append(_ window: Window?, _ kind: WindowKind, label: String? = nil) {
            guard let window else { return }
            windows.append(UsageWindow(
                kind: kind,
                usedPercent: Self.clampedPercent(window.utilization),
                resetsAt: window.resetsAt,
                label: label
            ))
        }
        append(fiveHour, .session5h)
        append(sevenDay, .week7d)
        append(sevenDayOpus, .week7d, label: "Opus")
        append(sevenDaySonnet, .week7d, label: "Sonnet")
        append(sevenDayRoutines, .week7d, label: "Routines")
        append(sevenDayCowork, .week7d, label: "Cowork")

        if let extra = extraUsage, extra.isEnabled == true,
           let limit = extra.monthlyLimit, limit > 0,
           let used = extra.usedMonthly {
            let percent = Self.clampedPercent(used / limit * 100)
            windows.append(UsageWindow(kind: .month, usedPercent: percent, label: "Extra usage"))
        }

        return UsageSnapshot(planName: Self.planName(subscriptionType: subscriptionType,
                                                     rateLimitTier: rateLimitTier),
                             windows: windows,
                             fetchedAt: now)
    }

    static func clampedPercent(_ utilization: Double) -> Int {
        min(100, max(0, Int(utilization.rounded())))
    }

    /// Plan inference per CodexBar: `subscriptionType` is preferred, with
    /// `rate_limit_tier` as fallback; a Max multiplier in the tier
    /// (`default_claude_max_20x`) is surfaced as "Max 20x".
    static func planName(subscriptionType: String?, rateLimitTier: String?) -> String? {
        func multiplierName(_ tier: String) -> String? {
            guard let range = tier.range(of: #"default_claude_max_(\d+)x"#, options: .regularExpression) else {
                return nil
            }
            let digits = tier[range].replacingOccurrences(of: #"[^0-9]"#, with: "", options: .regularExpression)
            guard let n = Int(digits), n > 0 else { return nil }
            return "Claude Max \(n)x"
        }

        func friendlyType(_ type: String) -> String? {
            switch type.lowercased() {
            case "max": return "Claude Max"
            case "pro": return "Claude Pro"
            case "team": return "Claude Team"
            case "enterprise": return "Claude Enterprise"
            default: return nil
            }
        }

        func friendlyTier(_ tier: String) -> String? {
            switch tier {
            case "default_claude_pro": return "Claude Pro"
            case "default_claude_team": return "Claude Team"
            case "default_claude_enterprise": return "Claude Enterprise"
            default: return nil
            }
        }

        // 1) Explicit Max multiplier wins (it carries information the plain
        //    type lacks).
        if let tier = rateLimitTier, let name = multiplierName(tier) { return name }
        // 2) subscriptionType, per CodexBar preference order.
        if let type = subscriptionType, let name = friendlyType(type) { return name }
        // 3) Tier fallback.
        if let tier = rateLimitTier, let name = friendlyTier(tier) { return name }
        // 4) Unknown-but-present values pass through capitalized.
        if let type = subscriptionType { return type.capitalized }
        if let tier = rateLimitTier { return tier.capitalized }
        return nil
    }
}
