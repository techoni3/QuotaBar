import AIMeterCore
import Foundation
import Testing
@testable import AIMeterApp

@MainActor
struct HUDViewModelTests {
    @Test func successfulProviderBecomesHiddenWhenDisabled() async {
        let provider = SuccessfulProvider()
        let suiteName = "aimeter-hud-view-model-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let refresher = UsageRefresher(
            providers: [provider],
            interval: 60,
            cacheURL: nil,
            defaultsSuiteName: suiteName
        )
        let viewModel = HUDViewModel(refresher: refresher, vault: InMemoryCredentialVault())

        await refresher.refreshAll()
        let becameVisible = await eventually {
            viewModel.visibleRows.map(\.id) == [provider.id]
        }
        #expect(becameVisible)

        viewModel.setEnabled(provider.id, false)
        let becameHidden = await eventually {
            viewModel.rows.first?.enabled == false && viewModel.visibleRows.isEmpty
        }
        #expect(becameHidden)
    }

    private func eventually(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}

private struct SuccessfulProvider: AIProvider {
    let id = ProviderID("successful")
    let displayName = "Successful"

    func fetchUsage() async throws -> UsageSnapshot {
        UsageSnapshot(windows: [UsageWindow(kind: .session5h, usedPercent: 25)])
    }
}
