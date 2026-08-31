import Foundation

/// A user-managed static subscription (name, plan, usage %, reset date).
public struct ManualPlan: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var planName: String?
    public var usedPercent: Int
    public var resetsAt: Date?

    public init(id: String = UUID().uuidString,
                name: String,
                planName: String? = nil,
                usedPercent: Int,
                resetsAt: Date? = nil) {
        precondition((0...100).contains(usedPercent), "usedPercent must be 0-100, got \(usedPercent)")
        self.id = id
        self.name = name
        self.planName = planName
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

/// Persists the manual subscription list (injectable for tests).
public protocol ManualPlanStore: Sendable {
    func loadPlans() -> [ManualPlan]
    func savePlans(_ plans: [ManualPlan])
}

/// UserDefaults-backed store. Dates use the flexibleISO8601 coding so they
/// round-trip exactly like the refresher's disk cache. A class so the
/// non-Sendable UserDefaults stays behind @unchecked Sendable isolation.
public final class UserDefaultsManualPlanStore: ManualPlanStore, @unchecked Sendable {
    public static let key = "manual.plans.v1"

    private let defaults: UserDefaults

    public init(defaultsSuiteName: String? = nil) {
        self.defaults = defaultsSuiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    public func loadPlans() -> [ManualPlan] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder.flexibleISO8601.decode([ManualPlan].self, from: data)) ?? []
    }

    public func savePlans(_ plans: [ManualPlan]) {
        if let data = try? JSONEncoder.flexibleISO8601.encode(plans) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

/// Static provider: renders each manual subscription as a labeled window.
/// There is no refresh — data changes only when the user edits Settings.
public struct ManualProvider: AIProvider {
    public let id = ProviderID("manual")
    public let displayName = "Manual"

    private let store: any ManualPlanStore

    public init(store: any ManualPlanStore = UserDefaultsManualPlanStore()) {
        self.store = store
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        let plans = store.loadPlans()
        return UsageSnapshot(
            planName: plans.isEmpty ? nil : "Manual subscriptions",
            windows: plans.map {
                UsageWindow(kind: .month,
                            usedPercent: $0.usedPercent,
                            resetsAt: $0.resetsAt,
                            label: $0.name)
            },
            fetchedAt: Date()
        )
    }
}