import AIMeterCore
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let vault = KeychainCredentialVault()
        let refresher = UsageRefresher(providers: Self.makeProviders(vault: vault))
        refresher.start()
        statusController = StatusItemController(refresher: refresher, vault: vault)
        statusController.install()
    }

    /// Wires the credential sources per spec Decision 3: keychain live-read
    /// preferred, explicit import as fallback.
    static func makeProviders(vault: any CredentialVault) -> [any AIProvider] {
        let claudeTokens = CompositeClaudeTokenSource([
            LiveKeychainClaudeTokenSource(),
            VaultClaudeTokenSource(vault: vault, providerID: ClaudeProvider.providerID),
        ])
        return [
            ClaudeProvider(session: .shared, tokenSource: claudeTokens),
            CodexProvider(session: .shared),
        ]
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
