import Foundation

/// Stable identifier for a subscription provider, e.g. "claude", "codex", "ollama".
public struct ProviderID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Lifecycle/health state of a provider as displayed in the HUD.
public enum ProviderStatus: String, Sendable, Codable, CaseIterable {
    case ok
    case unauthorized
    case unavailable
    case local
    case disabled
}

/// Kind of usage window a plan exposes.
public enum WindowKind: String, Sendable, Codable, CaseIterable {
    /// Rolling 5-hour session window (e.g. Claude, Codex).
    case session5h
    /// Rolling 7-day weekly window.
    case week7d
    /// Calendar/rolling monthly window.
    case month
    /// Prepaid or granted credits.
    case credits
}

extension WindowKind {
    public var displayName: String {
        switch self {
        case .session5h: return "Session (5h)"
        case .week7d: return "Week (7d)"
        case .month: return "Month"
        case .credits: return "Credits"
        }
    }
}

/// One usage window: how much of the quota was used and when it resets.
public struct UsageWindow: Hashable, Sendable, Codable {
    public var kind: WindowKind
    /// Used share of the quota, 0...100.
    public var usedPercent: Int
    /// When this window resets, if the provider reports it.
    public var resetsAt: Date?
    /// Optional human label distinguishing multiple windows of the same kind
    /// (e.g. model-specific weekly limits: "Opus", "Code review").
    public var label: String?

    public init(kind: WindowKind, usedPercent: Int, resetsAt: Date? = nil, label: String? = nil) {
        precondition((0...100).contains(usedPercent), "usedPercent must be 0-100, got \(usedPercent)")
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.label = label
    }

    private enum CodingKeys: String, CodingKey {
        case kind, usedPercent, resetsAt, label
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(WindowKind.self, forKey: .kind)
        usedPercent = try c.decode(Int.self, forKey: .usedPercent)
        resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
        // decodeIfPresent keeps pre-M2 caches (no label) decodable.
        label = try c.decodeIfPresent(String.self, forKey: .label)
    }

    /// Human-facing title: label if present, otherwise the window kind.
    public var title: String {
        label ?? kind.displayName
    }
}

extension UsageWindow {
    /// Countdown string like "resets in 3h 24m"; nil when no reset time is known.
    public func resetCountdownText(now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        let secs = Int(resetsAt.timeIntervalSince(now).rounded())
        guard secs > 0 else { return "resetting…" }
        let days = secs / 86_400
        let hours = (secs % 86_400) / 3_600
        let minutes = (secs % 3_600) / 60
        if days >= 1 { return "resets in \(days)d \(hours)h" }
        if hours >= 1 { return "resets in \(hours)h \(minutes)m" }
        return "resets in \(minutes)m"
    }
}

/// A point-in-time snapshot of a provider's plan and usage.
public struct UsageSnapshot: Hashable, Sendable, Codable {
    public var planName: String?
    public var windows: [UsageWindow]
    public var fetchedAt: Date

    public init(planName: String? = nil, windows: [UsageWindow], fetchedAt: Date = Date()) {
        self.planName = planName
        self.windows = windows
        self.fetchedAt = fetchedAt
    }
}
