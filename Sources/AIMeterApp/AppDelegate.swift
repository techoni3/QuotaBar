import AIMeterCore
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let vault = KeychainCredentialVault()
        let refresher = UsageRefresher(providers: Self.makeProviders(vault: vault))
        Task { await refresher.start() }
        statusController = StatusItemController(refresher: refresher, vault: vault)
        statusController.install()
    }

    /// Wires the credential sources per spec Decision 3: keychain live-read
    /// preferred by default, explicit import/paste when the user picks it in
    /// Settings. The choice is persisted per provider.
    static func makeProviders(vault: any CredentialVault) -> [any AIProvider] {
        let claudeMethod = UserDefaults.standard.string(forKey: SettingsKeys.credentialMethod(for: "claude"))
            ?? SettingsDefaults.credentialMethodKeychain
        let claudeTokens: any ClaudeTokenSource
        if claudeMethod == SettingsDefaults.credentialMethodImport {
            claudeTokens = VaultClaudeTokenSource(vault: vault, providerID: ClaudeProvider.providerID)
        } else {
            claudeTokens = CompositeClaudeTokenSource([
                LiveKeychainClaudeTokenSource(),
                VaultClaudeTokenSource(vault: vault, providerID: ClaudeProvider.providerID),
            ])
        }
        return [
            ClaudeProvider(session: .shared, tokenSource: claudeTokens),
            CodexProvider(session: .shared),
        ]
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
