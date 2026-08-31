import Foundation
import Testing
@testable import AIMeterCore

struct ManualProviderTests {
    @Test func storeRoundTripsAcrossInstances() throws {
        let name = "aimeter-manual-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let plan = ManualPlan(name: "NotebookLM", planName: "Pro",
                              usedPercent: 34, resetsAt: Date(timeIntervalSince1970: 1_800_500_000))
        try UserDefaultsManualPlanStore(defaultsSuiteName: name).savePlans([plan])

        let loaded = UserDefaultsManualPlanStore(defaultsSuiteName: name).loadPlans()
        #expect(loaded == [plan])
    }

    @Test func providerSnapshotShowsPlansAsWindows() async throws {
        let store = InMemoryManualPlanStore(plans: [
            ManualPlan(name: "NotebookLM", planName: "Pro", usedPercent: 34),
            ManualPlan(name: "ChatGPT", planName: "Plus", usedPercent: 88, resetsAt: Date(timeIntervalSince1970: 1_800_000_000)),
        ])
        let provider = ManualProvider(store: store)

        let snapshot = try await provider.fetchUsage()

        #expect(snapshot.planName == "Manual subscriptions")
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.windows.first?.label == "NotebookLM")
        #expect(snapshot.windows.first?.usedPercent == 34)
        #expect(snapshot.windows.last?.resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func emptyStoreYieldsEmptySnapshot() async throws {
        let provider = ManualProvider(store: InMemoryManualPlanStore(plans: []))

        let snapshot = try await provider.fetchUsage()

        #expect(snapshot.planName == nil)
        #expect(snapshot.windows.isEmpty)
    }

    @Test func planPercentIsClampedAtConstruction() {
        #expect(ManualPlan(name: "x", usedPercent: 100).usedPercent == 100)
        #expect(ManualPlan(name: "x", usedPercent: 0).usedPercent == 0)
    }
}

private final class InMemoryManualPlanStore: ManualPlanStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ManualPlan]

    init(plans: [ManualPlan]) {
        self.stored = plans
    }

    func loadPlans() -> [ManualPlan] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func savePlans(_ plans: [ManualPlan]) {
        lock.lock(); defer { lock.unlock() }
        stored = plans
    }
}