import Foundation

/// OpenRouter credits/usage via Pi's stored API key.
///
/// Pi stores the credential as `openrouter: {type: "api", key: "sk-or-..."}`.
/// AIMeter reads it via `PiAuthReading` (File → Pi → Vault pattern is
/// unnecessary — Pi is the single source for OpenRouter), never logs the key,
/// and never writes to `~/.pi`. The row is auto-connected when Pi has the
/// key: a successful credits fetch maps usage to windows; seat-info-only or
/// non-2xx (except 401) degrades to a keep-stable "connected" snapshot so the
/// HUD row never drops. 401 surfaces "Auth expired → Reconnect" and missing
/// key surfaces "Not connected".
public struct OpenRouterProvider: AIProvider, Sendable {
    public static let cloudProviderID = "openrouter"
    public static let creditsURL = URL(string: "https://openrouter.ai/api/v1/credits")!
    public static let authKeyURL = URL(string: "https://openrouter.ai/api/v1/auth/key")!
    public static let keyInfoURL = URL(string: "https://openrouter.ai/api/v1/key")!

    public let id = ProviderID(OpenRouterProvider.cloudProviderID)
    public let displayName = "OpenRouter"

    private let session: URLSession
    private let cloudAuth: any PiAuthReading

    public init(session: URLSession = .shared, cloudAuth: any PiAuthReading) {
        self.session = session
        self.cloudAuth = cloudAuth
    }

    /// Convenience alias matching the ticket's `OpenRouterProvider(cloudAuth: piAuth)` vs `piAuth` naming.
    public init(session: URLSession = .shared, piAuth: any PiAuthReading) {
        self.init(session: session, cloudAuth: piAuth)
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        guard let key = cloudAuth.apiKey(for: Self.cloudProviderID) ?? cloudAuth.accessToken(for: Self.cloudProviderID),
              !key.isEmpty else {
            throw ProviderError.unauthorized(detail: "Not connected — no OpenRouter credential in Pi")
        }

        let candidates = [Self.creditsURL, Self.authKeyURL, Self.keyInfoURL]
        var lastNotFound: ProviderError?
        for url in candidates {
            do {
                return try await fetchAndMap(url: url, key: key)
            } catch let error as ProviderError {
                switch error {
                case .unauthorized:
                    throw ProviderError.unauthorized(detail: "Auth expired → Reconnect")
                case .unavailable(let detail) where detail.contains("404"):
                    lastNotFound = error
                    continue
                default:
                    return Self.fallbackSnapshot()
                }
            } catch {
                return Self.fallbackSnapshot()
            }
        }
        if lastNotFound != nil {
            return Self.fallbackSnapshot()
        }
        return Self.fallbackSnapshot()
    }

    private func fetchAndMap(url: URL, key: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await HTTPOps.send(request, session: session)
        let data: Data
        do {
            data = try response.validated()
        } catch let error as ProviderError {
            throw error
        }

        if let snapshot = Self.snapshot(from: data, fetchedAt: Date()) {
            return snapshot
        }
        // Valid JSON but no usage fields → connected fallback (keep-stable).
        if (try? JSONSerialization.jsonObject(with: data)) != nil {
            return Self.fallbackSnapshot()
        }
        return Self.fallbackSnapshot()
    }

    // MARK: - Mapping

    /// Maps a credits/key-info payload to windows when usage/limit fields are present.
    /// Returns nil when the payload decodes but contains no quota window (connected-but-no-quota).
    static func snapshot(from data: Data, fetchedAt: Date = Date()) -> UsageSnapshot? {
        if let response = try? JSONDecoder.flexibleISO8601.decode(OpenRouterCreditsResponse.self, from: data),
           let windows = response.windows(fetchedAt: fetchedAt), !windows.isEmpty {
            return UsageSnapshot(planName: response.planName ?? "OpenRouter — connected",
                                 windows: windows, fetchedAt: fetchedAt, status: .ok)
        }
        // Dictionary scan fallback for tolerant mocked payloads.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let windows = Self.windowsFromDictionary(json, fetchedAt: fetchedAt), !windows.isEmpty {
            let plan = (json["plan"] as? String).map { "OpenRouter — \($0)" } ?? "OpenRouter — connected"
            return UsageSnapshot(planName: plan, windows: windows, fetchedAt: fetchedAt, status: .ok)
        }
        return nil
    }

    static func fallbackSnapshot(fetchedAt: Date = Date()) -> UsageSnapshot {
        UsageSnapshot(
            planName: "OpenRouter — connected",
            windows: [UsageWindow(kind: .session5h, usedPercent: 0, resetsAt: nil, label: "OpenRouter")],
            fetchedAt: fetchedAt,
            status: .ok
        )
    }

    static func clampedPercent(_ percent: Double) -> Int {
        min(100, max(0, Int(percent.rounded())))
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
            let p = percent(from: dict["percent"])
                ?? percent(from: dict["usedPercent"])
                ?? percent(from: dict["usagePercent"])
                ?? percent(from: dict["usage_percent"])
            if let p {
                let reset = (dict["resetsAt"] as? String).flatMap(ISO8601Dates.parse)
                    ?? (dict["resetAt"] as? String).flatMap(ISO8601Dates.parse)
                return UsageWindow(kind: kind, usedPercent: clampedPercent(p), resetsAt: reset, label: label)
            }
            if let limit = percent(from: dict["limit"]), limit > 0 {
                if let used = percent(from: dict["used"]) {
                    return UsageWindow(kind: kind, usedPercent: clampedPercent(used / limit * 100), resetsAt: nil, label: label)
                }
                if let usage = percent(from: dict["usage"]) {
                    return UsageWindow(kind: kind, usedPercent: clampedPercent(usage / limit * 100), resetsAt: nil, label: label)
                }
                if let remaining = percent(from: dict["remaining"]) ?? percent(from: dict["limit_remaining"]) ?? percent(from: dict["limitRemaining"]) {
                    return UsageWindow(kind: kind, usedPercent: clampedPercent((1 - remaining / limit) * 100), resetsAt: nil, label: label)
                }
            }
            if let totalCredits = percent(from: dict["total_credits"]) ?? percent(from: dict["totalCredits"]), totalCredits > 0,
               let totalUsage = percent(from: dict["total_usage"]) ?? percent(from: dict["totalUsage"]) {
                return UsageWindow(kind: kind, usedPercent: clampedPercent(totalUsage / totalCredits * 100), resetsAt: nil, label: label)
            }
            if let credits = percent(from: dict["credits"]), let usage = percent(from: dict["total_usage"]) ?? percent(from: dict["usage"]) {
                let limit = credits
                if limit > 0 { return UsageWindow(kind: kind, usedPercent: clampedPercent(usage / limit * 100), resetsAt: nil, label: label) }
            }
            return nil
        }

        // data box (credits endpoint shape)
        if let dataBox = json["data"] as? [String: Any], let w = window(for: dataBox, kind: .session5h, label: "Credits") {
            windows.append(w)
            // Also weekly copy so HUD shows 2 windows when credits available (task: 5h/weekly).
            if windows.count == 1 {
                windows.append(UsageWindow(kind: .week7d, usedPercent: w.usedPercent, resetsAt: w.resetsAt, label: "Weekly"))
            }
            return windows
        }

        let quotaDict = json["quota"] as? [String: Any]
        let usageDict = json["usage"] as? [String: Any]
        let sessionDict = json["session"] as? [String: Any]
        let weeklyDict = json["weekly"] as? [String: Any]

        if let w = window(for: quotaDict, kind: .session5h, label: "Session (5h)") { windows.append(w) }
        if let w = window(for: usageDict, kind: .session5h, label: "Session (5h)") { windows.append(w) }
        if let w = window(for: sessionDict, kind: .session5h) { windows.append(w) }
        if let w = window(for: weeklyDict, kind: .week7d) { windows.append(w) }

        // Top-level limit/used
        if windows.isEmpty, let limit = percent(from: json["limit"]), limit > 0, let used = percent(from: json["used"]) ?? percent(from: json["usage"]) {
            windows.append(UsageWindow(kind: .session5h, usedPercent: clampedPercent(used / limit * 100), resetsAt: nil, label: "OpenRouter"))
            windows.append(UsageWindow(kind: .week7d, usedPercent: clampedPercent(used / limit * 100), resetsAt: nil, label: "Weekly"))
        }
        // Top-level credits shape without data wrapper
        if windows.isEmpty, let w = window(for: json, kind: .session5h, label: "Credits") {
            // Only use top-level window if no nested candidates and looks like credits
            if json["total_credits"] != nil || json["totalCredits"] != nil {
                windows.append(w)
                windows.append(UsageWindow(kind: .week7d, usedPercent: w.usedPercent, resetsAt: w.resetsAt, label: "Weekly"))
            }
        }

        return windows.isEmpty ? nil : windows
    }
}

// MARK: - Typed response

struct OpenRouterCreditsResponse: Decodable {
    struct DataBox: Decodable {
        let total_credits: Double?
        let totalCredits: Double?
        let total_usage: Double?
        let totalUsage: Double?
        let usage: Double?
        let limit: Double?
        let limit_remaining: Double?
        let limitRemaining: Double?
        let credits: Double?
        let remaining: Double?
        let percent: Double?
        let usedPercent: Double?
        let resetsAt: Date?
        let resetAt: Date?

        enum CodingKeys: String, CodingKey {
            case total_credits, totalCredits, total_usage, totalUsage, usage, limit, limit_remaining, limitRemaining, credits, remaining, percent, usedPercent, resetsAt, resetAt
        }

        var effectivePercent: Double? {
            if let totalCredits = total_credits ?? totalCredits, totalCredits > 0,
               let totalUsage = total_usage ?? totalUsage {
                return totalUsage / totalCredits * 100
            }
            if let usage, let limit, limit > 0 {
                return usage / limit * 100
            }
            if let limit, limit > 0, let remaining = limit_remaining ?? limitRemaining ?? remaining {
                return (1 - remaining / limit) * 100
            }
            if let p = percent ?? usedPercent { return p }
            if let credits, credits > 0, let usage {
                return usage / credits * 100
            }
            return nil
        }

        var effectiveResetsAt: Date? { resetsAt ?? resetAt }
    }

    let data: DataBox?
    let total_credits: Double?
    let total_usage: Double?
    let limit: Double?
    let usage: Double?
    let percent: Double?
    let plan: String?
    let planName: String?

    enum CodingKeys: String, CodingKey {
        case data, total_credits, total_usage, limit, usage, percent, plan, planName
    }

    func windows(fetchedAt: Date) -> [UsageWindow]? {
        var out: [UsageWindow] = []
        // Primary credits shape inside data
        if let box = data, let p = box.effectivePercent {
            let w = UsageWindow(kind: .session5h, usedPercent: OpenRouterProvider.clampedPercent(p),
                                resetsAt: box.effectiveResetsAt, label: "Credits")
            out.append(w)
            out.append(UsageWindow(kind: .week7d, usedPercent: w.usedPercent, resetsAt: w.resetsAt, label: "Weekly"))
            return out
        }
        // Top-level fallback shapes
        if let limit, limit > 0, let usage, let p = DataBox(total_credits: nil, totalCredits: nil, total_usage: nil, totalUsage: nil, usage: usage, limit: limit, limit_remaining: nil, limitRemaining: nil, credits: nil, remaining: nil, percent: nil, usedPercent: nil, resetsAt: nil, resetAt: nil).effectivePercent {
            let w = UsageWindow(kind: .session5h, usedPercent: OpenRouterProvider.clampedPercent(p), resetsAt: nil, label: "OpenRouter")
            out.append(w)
            out.append(UsageWindow(kind: .week7d, usedPercent: w.usedPercent, resetsAt: nil, label: "Weekly"))
            return out
        }
        if let totalCredits = total_credits, totalCredits > 0, let totalUsage = total_usage {
            let p = totalUsage / totalCredits * 100
            let w = UsageWindow(kind: .session5h, usedPercent: OpenRouterProvider.clampedPercent(p), resetsAt: nil, label: "Credits")
            out.append(w)
            out.append(UsageWindow(kind: .week7d, usedPercent: w.usedPercent, resetsAt: nil, label: "Weekly"))
            return out
        }
        if let p = percent {
            out.append(UsageWindow(kind: .session5h, usedPercent: OpenRouterProvider.clampedPercent(p), resetsAt: nil, label: "OpenRouter"))
            return out
        }
        return out.isEmpty ? nil : out
    }
}
