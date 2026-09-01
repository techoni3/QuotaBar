import Foundation

/// Ollama Cloud usage response: `GET https://ollama.com/api/usage` (Bearer
/// api_key). Shape verified live (2026-08-31, plus monthly 2026-09-01) and documented in
/// can1357/oh-my-pi#10101:
/// `{"activity": {…}, "limits": {"session": {"usage": <0..1>, "models":
/// [{"name", "request_count"}]}, "weekly": {…}, "monthly": {…}}}`.
struct OllamaCloudUsage: Decodable, Equatable, Sendable {
    struct Limits: Decodable, Equatable, Sendable {
        let session: Window?
        let weekly: Window?
        let monthly: Window?
    }
    struct Window: Decodable, Equatable, Sendable {
        /// Fraction of the 5h/7d allowance, 0..1.
        let usage: Double?
        let models: [Model]?
    }
    struct Model: Decodable, Equatable, Sendable {
        let name: String?
        let requestCount: Int?

        enum CodingKeys: String, CodingKey {
            case name
            case requestCount = "request_count"
        }
    }

    let limits: Limits?
}

extension OllamaProvider {
    /// session/weekly usage fraction → windows with clamped percents and top
    /// consumers (up to 4) appended to the label.
    static func cloudSnapshot(from usage: OllamaCloudUsage, fetchedAt: Date) -> UsageSnapshot {
        var windows: [UsageWindow] = []
        func append(_ window: OllamaCloudUsage.Window?, _ kind: WindowKind, baseLabel: String) {
            guard let window, let fraction = window.usage else { return }
            let suffix = consumersText(window.models)
            windows.append(UsageWindow(kind: kind,
                                       usedPercent: clampedPercent(fraction),
                                       resetsAt: nil,
                                       label: suffix.isEmpty ? baseLabel : "\(baseLabel) · \(suffix)"))
        }
        append(usage.limits?.session, .session5h, baseLabel: "Cloud session (5h)")
        append(usage.limits?.weekly, .week7d, baseLabel: "Cloud weekly")
        append(usage.limits?.monthly, .month, baseLabel: "Cloud monthly")
        return UsageSnapshot(planName: "Ollama Cloud — connected", windows: windows, fetchedAt: fetchedAt, status: .ok)
    }

    /// Keep-stable fallback for network/non-2xx/JSON failures: the row never
    /// drops from the HUD and never throws unauthorized.
    static func cloudFallbackSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            planName: "Ollama Cloud — connected",
            windows: [
                UsageWindow(kind: .session5h, usedPercent: 0, resetsAt: nil, label: "Cloud session (5h)"),
                UsageWindow(kind: .week7d, usedPercent: 0, resetsAt: nil, label: "Cloud weekly"),
                UsageWindow(kind: .month, usedPercent: 0, resetsAt: nil, label: "Cloud monthly"),
            ],
            fetchedAt: Date(),
            status: .ok
        )
    }

    /// Clamps the 0..1 fraction to a 0...100 percent (out-of-range tolerated).
    static func clampedPercent(_ fraction: Double) -> Int {
        min(100, max(0, Int((fraction * 100).rounded())))
    }

    /// "name×count" for the top 4 consumers, comma-joined; empty when absent.
    static func consumersText(_ models: [OllamaCloudUsage.Model]?) -> String {
        guard let models else { return "" }
        return models.prefix(4).compactMap { model in
            guard let name = model.name else { return nil }
            return model.requestCount.map { "\(name)×\($0)" } ?? name
        }.joined(separator: ", ")
    }
}