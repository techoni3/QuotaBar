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

/// One usage window: how much of the quota was used and when it resets.
public struct UsageWindow: Hashable, Sendable, Codable {
    public var kind: WindowKind
    /// Used share of the quota, 0...100.
    public var usedPercent: Int
    /// When this window resets, if the provider reports it.
    public var resetsAt: Date?

    public init(kind: WindowKind, usedPercent: Int, resetsAt: Date? = nil) {
        precondition((0...100).contains(usedPercent), "usedPercent must be 0-100, got \(usedPercent)")
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
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