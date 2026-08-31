import AIMeterCore
import SwiftUI

/// One HUD row's display state, derived from a refresher result.
struct ProviderRowState: Identifiable, Equatable {
    struct WindowVM: Identifiable, Equatable {
        let id: String
        let title: String
        let percent: Int
        let tint: UsageTint
        let countdown: String?
    }

    let id: ProviderID
    let name: String
    var status: ProviderStatus
    var planName: String?
    var windows: [WindowVM]
    var fetchedAt: Date?
    var errorText: String?
    var enabled: Bool
}

/// Bridges the UsageRefresher actor to SwiftUI.
@MainActor
final class HUDViewModel: ObservableObject {
    @Published private(set) var rows: [ProviderRowState] = []
    @Published private(set) var worstTint: UsageTint = .green
    @Published private(set) var connectedCount = 0

    /// Row (if any) whose Connect sheet is currently presented.
    @Published var connectSheetRow: ProviderID?

    private let refresher: UsageRefresher
    private let vault: any CredentialVault
    private var streamTask: Task<Void, Never>?

    init(refresher: UsageRefresher, vault: any CredentialVault) {
        self.refresher = refresher
        self.vault = vault
        streamTask = Task { [weak self] in
            for await state in refresher.updates {
                self?.absorb(state)
            }
        }
        // Publish the initial (cached) state without waiting for a tick.
        Task { [weak self] in
            await self?.absorb(await refresher.currentState())
        }
    }

    deinit {
        streamTask?.cancel()
    }

    func refreshAll() {
        Task { await refresher.refreshAll() }
    }

    func refresh(_ id: ProviderID) {
        Task { await refresher.refresh(id) }
    }

    func setEnabled(_ id: ProviderID, _ isEnabled: Bool) {
        Task { await refresher.setEnabled(id, isEnabled) }
    }

    /// Stores a user-pasted token and immediately refreshes the provider.
    func connect(_ id: ProviderID, token: String) async throws {
        try vault.storeToken(token, for: id)
        await refresher.refresh(id)
        connectSheetRow = nil
    }

    func forget(_ id: ProviderID) {
        vault.deleteToken(for: id)
    }

    private func absorb(_ state: RefresherState) {
        var rows: [ProviderRowState] = []
        var worst = UsageTint.green
        var connected = 0
        for info in state.providers {
            let isEnabled = state.enabled[info.id] ?? true
            var row = ProviderRowState(
                id: info.id,
                name: info.displayName,
                status: isEnabled ? .ok : .disabled,
                planName: nil,
                windows: [],
                fetchedAt: nil,
                errorText: nil,
                enabled: isEnabled
            )
            if let result = state.results[info.id] {
                switch result {
                case .success(let snapshot):
                    connected += 1
                    row.planName = snapshot.planName
                    row.fetchedAt = snapshot.fetchedAt
                    row.status = snapshot.status ?? .ok
                    row.windows = snapshot.windows.map { window in
                        .init(id: "\(window.kind.rawValue)-\(window.label ?? "")",
                              title: window.title,
                              percent: window.usedPercent,
                              tint: window.tint,
                              countdown: window.resetCountdownText())
                    }
                    if isEnabled, snapshot.worstTint.severityRank > worst.severityRank {
                        worst = snapshot.worstTint
                    }
                case .failure(let error):
                    row.errorText = error.displayText
                    switch error {
                    case .unauthorized:
                        row.status = .unauthorized
                    case .notInstalled:
                        row.status = .unavailable
                    default:
                        row.status = .unavailable
                    }
                }
            } else if isEnabled {
                row.status = .unavailable
                row.errorText = "No data yet"
            }
            rows.append(row)
        }
        self.rows = rows
        self.worstTint = worst
        self.connectedCount = connected
    }
}
