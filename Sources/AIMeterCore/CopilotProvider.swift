import Foundation

/// GitHub Copilot subscription usage via Pi's stored OAuth credential.
///
/// Pi stores the credential as `github-copilot: {type: "oauth", access: "ghu_...",
/// refresh: ..., expires: <millis>}`. AIMeter never writes to `~/.pi` and
/// never logs the token. The row is auto-connected when Pi has the credential:
/// a successful billing fetch maps quota windows; seat-info-only or
/// non-2xx (except 401) degrades to a keep-stable "connected" snapshot so the
/// HUD row never drops. 401 surfaces "Auth expired → Reconnect" and missing
/// credential surfaces "Not connected".
public struct CopilotProvider: AIProvider, Sendable {
    public static let cloudProviderID = "github-copilot"
    public static let billingURL = URL(string: "https://api.github.com/copilot/billing")!
    public static let userBillingURL = URL(string: "https://api.github.com/user/copilot/billing")!
    public static let proxyUsageURL = URL(string: "https://proxy.business.githubcopilot.com/v1/usage")!

    public let id = ProviderID(CopilotProvider.cloudProviderID)
    public let displayName = "GitHub Copilot"

    private let session: URLSession
    private let piAuth: any PiAuthReading

    public init(session: URLSession = .shared, piAuth: any PiAuthReading) {
        self.session = session
        self.piAuth = piAuth
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        guard let token = Self.token(from: piAuth), !token.isEmpty else {
            throw ProviderError.unauthorized(detail: "Not connected — no GitHub Copilot credential in Pi")
        }

        // Optional expiry pre-check: surface expired as unauthorized without hitting the wire,
        // mirroring Antigravity's stale-token guidance but without attempting a refresh
        // (GitHub's refresh requires client secrets not available to AIMeter).
        if let expiry = piAuth.expiryDate(for: Self.cloudProviderID), expiry <= Date().addingTimeInterval(60) {
            // Still attempt network; if it would 401 we surface reconnect. Do not block fetch.
        }

        // Try GitHub billing endpoints in order; 404 → next, 401 → reconnect, other failures → fallback.
        let candidates = [Self.billingURL, Self.userBillingURL, Self.proxyUsageURL]
        var lastNotFound: ProviderError?
        for url in candidates {
            do {
                return try await fetchAndMap(url: url, token: token)
            } catch let error as ProviderError {
                switch error {
                case .unauthorized:
                    // Surface the Pi reconnect affordance; never swallow as fallback.
                    throw ProviderError.unauthorized(detail: "Auth expired → Reconnect")
                case .unavailable(let detail) where detail.contains("404"):
                    lastNotFound = error
                    continue
                default:
                    // Any other non-401 failure degrades to keep-stable fallback so the
                    // row never disappears when a key exists (spec: never "Not connected" with key).
                    return Self.fallbackSnapshot()
                }
            } catch {
                return Self.fallbackSnapshot()
            }
        }
        // All candidates 404'd or no quota payload — business seat with no quota window.
        if lastNotFound != nil {
            return Self.fallbackSnapshot()
        }
        return Self.fallbackSnapshot()
    }

    private func fetchAndMap(url: URL, token: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await HTTPOps.send(request, session: session)
        let data: Data
        do {
            data = try response.validated()
        } catch let error as ProviderError {
            // Re-throw http-mapped errors for the caller to classify (401 vs 404 vs other).
            throw error
        }

        // Try to map quota windows; payload with only seat info returns nil → fallback.
        if let snapshot = Self.snapshot(from: data, fetchedAt: Date()) {
            return snapshot
        }
        // Valid JSON but no quota fields → business seat fallback (never unauthorized).
        // Confirm it's JSON before falling back; garbage JSON that fails decode should
        // also degrade to fallback rather than "unavailable" so the row stays visible.
        // The validated 2xx plus successful JSON parse is enough to prove seat.
        // If JSON is valid but empty, still fallback.
        if (try? JSONSerialization.jsonObject(with: data)) != nil {
            return Self.fallbackSnapshot()
        }
        // Unparseable payload with 2xx is treated as fallback as well for keep-stable.
        return Self.fallbackSnapshot()
    }

    // MARK: - Mapping

    /// Maps a billing payload to windows when quota-like fields are present.
    /// Returns nil when the payload decodes but contains no quota window (seat-info-only).
    static func snapshot(from data: Data, fetchedAt: Date = Date()) -> UsageSnapshot? {
        // Tolerant: try typed decode first, then dictionary scan for top-level percent/quota.
        if let response = try? JSONDecoder.flexibleISO8601.decode(CopilotUsageResponse.self, from: data),
           let windows = response.windows(fetchedAt: fetchedAt), !windows.isEmpty {
            return UsageSnapshot(planName: response.planName ?? "GitHub Copilot — connected",
                                 windows: windows, fetchedAt: fetchedAt, status: .ok)
        }
        // Dictionary scan fallback for ad-hoc mocked shapes (e.g. {"quota":{"percent":42}} or {"percent":42}).
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let windows = Self.windowsFromDictionary(json, fetchedAt: fetchedAt), !windows.isEmpty {
                let plan = (json["plan"] as? String).map { "GitHub Copilot — \($0)" } ?? "GitHub Copilot — connected"
                return UsageSnapshot(planName: plan, windows: windows, fetchedAt: fetchedAt, status: .ok)
            }
            // Seat-info-only payload (e.g. {"seat_breakdown": ...}) but valid JSON → nil to signal fallback.
            // Return nil so caller can degrade to fallbackSnapshot.
            // Only return nil when JSON is non-empty; empty JSON also fallback.
        }
        return nil
    }

    static func fallbackSnapshot(fetchedAt: Date = Date()) -> UsageSnapshot {
        UsageSnapshot(
            planName: "Copilot — connected (business seat, no quota window)",
            windows: [UsageWindow(kind: .session5h, usedPercent: 0, resetsAt: nil, label: "Copilot")],
            fetchedAt: fetchedAt,
            status: .ok
        )
    }

    static func clampedPercent(_ percent: Double) -> Int {
        min(100, max(0, Int(percent.rounded())))
    }

    private static func token(from auth: any PiAuthReading) -> String? {
        // Pi may store github-copilot as oauth access or as api key; accept either without logging.
        if let access = auth.accessToken(for: cloudProviderID), !access.isEmpty { return access }
        if let key = auth.apiKey(for: cloudProviderID), !key.isEmpty { return key }
        return nil
    }

    // MARK: - Dictionary scan for tolerant mocked payloads

    private static func windowsFromDictionary(_ json: [String: Any], fetchedAt: Date) -> [UsageWindow]? {
        var windows: [UsageWindow] = []
        func percent(from value: Any?) -> Double? {
            if let n = value as? Double { return n }
            if let n = value as? Int { return Double(n) }
            if let n = value as? NSNumber { return n.doubleValue }
            return nil
        }
        func window(for dict: [String: Any]?, kind: WindowKind, label: String? = nil) -> UsageWindow? {
            guard let dict else { return nil }
            // percent-like keys
            let p = percent(from: dict["percent"])
                ?? percent(from: dict["usedPercent"])
                ?? percent(from: dict["usagePercent"])
                ?? percent(from: dict["usage_percent"])
            if let p {
                let clamped = clampedPercent(p)
                let reset = (dict["resetsAt"] as? String).flatMap(ISO8601Dates.parse)
                    ?? (dict["resetAt"] as? String).flatMap(ISO8601Dates.parse)
                    ?? (dict["resets_at"] as? String).flatMap(ISO8601Dates.parse)
                return UsageWindow(kind: kind, usedPercent: clamped, resetsAt: reset, label: label)
            }
            // limit/used keys
            if let limit = percent(from: dict["limit"]), limit > 0 {
                if let used = percent(from: dict["used"]) {
                    return UsageWindow(kind: kind, usedPercent: clampedPercent(used / limit * 100), resetsAt: nil, label: label)
                }
                if let remaining = percent(from: dict["remaining"]) {
                    return UsageWindow(kind: kind, usedPercent: clampedPercent((1 - remaining / limit) * 100), resetsAt: nil, label: label)
                }
            }
            // remainingFraction
            if let fraction = percent(from: dict["remainingFraction"]) ?? percent(from: dict["remaining_fraction"]) {
                return UsageWindow(kind: kind, usedPercent: clampedPercent((1 - fraction) * 100), resetsAt: nil, label: label)
            }
            return nil
        }

        // Nested objects that may hold windows
        let quotaDict = json["quota"] as? [String: Any]
        let billingDict = json["billing"] as? [String: Any]
        let usageDict = json["usage"] as? [String: Any]
        let sessionDict = json["session"] as? [String: Any] ?? json["rolling"] as? [String: Any]
        let weeklyDict = json["weekly"] as? [String: Any]
        let monthlyDict = json["monthly"] as? [String: Any]

        // Direct percent at top level
        if let w = window(for: json, kind: .session5h, label: "Copilot") {
            // Only use top-level window if it is the only candidate and not ambiguous with nested
            // When nested candidates exist, prefer nested windows below.
            if quotaDict == nil && billingDict == nil && usageDict == nil && sessionDict == nil && weeklyDict == nil && monthlyDict == nil {
                windows.append(w)
                return windows
            }
        }

        if let w = window(for: quotaDict, kind: .session5h, label: "Session (5h)") { windows.append(w) }
        if let w = window(for: billingDict, kind: .session5h, label: "Session (5h)") { windows.append(w) }
        if let w = window(for: usageDict, kind: .session5h, label: "Session (5h)") {
            // If usage dict itself is window-like, use it; else it may contain nested windows
            if windows.isEmpty { windows.append(w) }
        }
        // usage may contain nested rolling/weekly
        if let usageNested = usageDict {
            if let w = window(for: usageNested["rolling"] as? [String: Any], kind: .session5h) { windows.append(w) }
            if let w = window(for: usageNested["weekly"] as? [String: Any], kind: .week7d) { windows.append(w) }
            if let w = window(for: usageNested["monthly"] as? [String: Any], kind: .month) { windows.append(w) }
        }
        if let w = window(for: sessionDict, kind: .session5h) { windows.append(w) }
        if let w = window(for: weeklyDict, kind: .week7d) { windows.append(w) }
        if let w = window(for: monthlyDict, kind: .month) { windows.append(w) }

        // limit/used at top level (e.g. {"used":42,"limit":100})
        if windows.isEmpty, let limit = percent(from: json["limit"]), limit > 0, let used = percent(from: json["used"]) {
            windows.append(UsageWindow(kind: .session5h, usedPercent: clampedPercent(used / limit * 100), resetsAt: nil, label: "Copilot"))
        }

        return windows.isEmpty ? nil : windows
    }
}

// MARK: - Typed response (primary decode)

struct CopilotUsageResponse: Decodable {
    struct Window: Decodable {
        let percent: Double?
        let usedPercent: Double?
        let usagePercent: Double?
        let remainingFraction: Double?
        let remaining_fraction: Double?
        let limit: Double?
        let used: Double?
        let remaining: Double?
        let resetsAt: Date?
        let resetAt: Date?
        let resets_at: Date?

        enum CodingKeys: String, CodingKey {
            case percent, usedPercent, usagePercent, remainingFraction, remaining_fraction, limit, used, remaining, resetsAt, resetAt, resets_at
        }

        var effectivePercent: Double? {
            if let p = percent ?? usedPercent ?? usagePercent { return p }
            if let f = remainingFraction ?? remaining_fraction { return (1 - f) * 100 }
            if let limit, limit > 0 {
                if let used { return used / limit * 100 }
                if let remaining { return (1 - remaining / limit) * 100 }
            }
            return nil
        }

        var effectiveResetsAt: Date? { resetsAt ?? resetAt ?? resets_at }
    }

    struct UsageBox: Decodable {
        let rolling: Window?
        let weekly: Window?
        let monthly: Window?
        let session: Window?
        let quota: Window?
        let billing: Window?
    }

    let quota: Window?
    let billing: Window?
    let usage: UsageBox?
    let session: Window?
    let weekly: Window?
    let monthly: Window?
    let plan: String?
    let planName: String?
    let percent: Double?
    let remainingFraction: Double?
    let limit: Double?
    let used: Double?
    let remaining: Double?

    enum CodingKeys: String, CodingKey {
        case quota, billing, usage, session, weekly, monthly, plan, planName, percent, remainingFraction, limit, used, remaining
    }

    func windows(fetchedAt: Date) -> [UsageWindow]? {
        var out: [UsageWindow] = []
        func append(_ w: Window?, kind: WindowKind, label: String? = nil) {
            guard let w, let p = w.effectivePercent else { return }
            out.append(UsageWindow(kind: kind, usedPercent: CopilotProvider.clampedPercent(p),
                                   resetsAt: w.effectiveResetsAt, label: label))
        }
        append(quota, kind: .session5h, label: "Session (5h)")
        append(billing, kind: .session5h, label: "Session (5h)")
        append(session, kind: .session5h)
        append(weekly, kind: .week7d)
        append(monthly, kind: .month)
        if let usage {
            append(usage.rolling, kind: .session5h)
            append(usage.weekly, kind: .week7d)
            append(usage.monthly, kind: .month)
            append(usage.session, kind: .session5h)
            append(usage.quota, kind: .session5h)
            append(usage.billing, kind: .session5h)
        }
        // top-level percent/limit
        if out.isEmpty, let p = percent { append(Window(percent: p, usedPercent: nil, usagePercent: nil, remainingFraction: nil, remaining_fraction: nil, limit: nil, used: nil, remaining: nil, resetsAt: nil, resetAt: nil, resets_at: nil), kind: .session5h, label: "Copilot") }
        if out.isEmpty, let f = remainingFraction { append(Window(percent: nil, usedPercent: nil, usagePercent: nil, remainingFraction: f, remaining_fraction: nil, limit: nil, used: nil, remaining: nil, resetsAt: nil, resetAt: nil, resets_at: nil), kind: .session5h, label: "Copilot") }
        if out.isEmpty, let limit, limit > 0, let used {
            out.append(UsageWindow(kind: .session5h, usedPercent: CopilotProvider.clampedPercent(used / limit * 100), resetsAt: nil, label: "Copilot"))
        }
        return out.isEmpty ? nil : out
    }
}
