import AppKit
import Foundation

/// Aggregate menu-bar icon state, derived from the freshest enabled providers'
/// windows plus refresher health (spec §4, PER-6).
///
/// Precedence: **critical** (any enabled window ≥90%) > **warning** (any ≥70%)
/// > **stale** (an enabled provider is currently failing) > **normal**
/// (everything fine or no data yet). Usage thresholds dominate the icon so a
/// near-limit quota is never masked by an unrelated provider error; the grey
/// stale state appears when nothing is over threshold but something is down.
public enum StatusItemState: Int, Sendable, Equatable, CaseIterable {
    case normal = 0
    case warning = 1
    case stale = 2
    case critical = 3

    public static func derive(from state: RefresherState) -> StatusItemState {
        var worstWindowPercent = -1
        var anyFailure = false
        for id in state.providers.map(\.id) where state.enabled[id] ?? true {
            guard let result = state.results[id] else { continue }
            switch result {
            case .success(let snapshot):
                for window in snapshot.windows {
                    worstWindowPercent = max(worstWindowPercent, window.usedPercent)
                }
            case .failure:
                anyFailure = true
            }
        }
        if worstWindowPercent >= UsageTint.redThreshold { return .critical }
        if worstWindowPercent >= UsageTint.amberThreshold { return .warning }
        if anyFailure { return .stale }
        return .normal
    }

    public var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .stale: return "Stale"
        case .critical: return "Critical"
        }
    }

    /// Semantic neutral colors adapt to the status button's effective appearance.
    /// Avoid an untinted custom black glyph or fixed grey that disappears on a
    /// dark menu bar; warning and critical retain their status colors.
    @MainActor
    public var statusItemColor: NSColor? {
        switch self {
        case .normal: return .labelColor
        case .warning: return .systemOrange
        case .stale: return .secondaryLabelColor
        case .critical: return .systemRed
        }
    }

    /// VoiceOver label for the menu-bar button.
    public var statusItemAccessibilityLabel: String {
        switch self {
        case .normal: return "AIMeter — usage normal"
        case .warning: return "AIMeter — usage warning, 70% or more of a window used"
        case .stale: return "AIMeter — a provider is stale or failing"
        case .critical: return "AIMeter — usage critical, 90% or more of a window used"
        }
    }
}