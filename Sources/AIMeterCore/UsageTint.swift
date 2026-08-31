import Foundation

#if canImport(AppKit)
import AppKit

/// Color tint for a usage bar, keyed off the used-percentage thresholds
/// decided in the spec: green below 70%, amber 70-89%, red at 90+.
public enum UsageTint: Equatable, Sendable, CaseIterable {
    case green
    case amber
    case red

    /// Threshold for switching from green to amber.
    public static let amberThreshold: Int = 70
    /// Threshold for switching to red.
    public static let redThreshold: Int = 90

    /// Numeric severity for ordering: 0 green, 1 amber, 2 red.
    public var severityRank: Int {
        switch self {
        case .green: return 0
        case .amber: return 1
        case .red: return 2
        }
    }

    @MainActor
    public var color: NSColor {
        switch self {
        case .green: NSColor.systemGreen
        case .amber: NSColor.systemOrange
        case .red: NSColor.systemRed
        }
    }
}

extension UsageWindow {
    public var tint: UsageTint {
        if usedPercent >= UsageTint.redThreshold { return .red }
        if usedPercent >= UsageTint.amberThreshold { return .amber }
        return .green
    }
}

extension UsageSnapshot {
    /// The worst (highest-severity) tint across all tracked windows,
    /// used for aggregate indicators like the menu bar icon.
    public var worstTint: UsageTint {
        windows.map(\.tint).max { a, b in
            let rank: (UsageTint) -> Int = { $0 == .green ? 0 : ($0 == .amber ? 1 : 2) }
            return rank(a) < rank(b)
        } ?? .green
    }
}
#endif