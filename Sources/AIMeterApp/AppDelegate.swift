import AIMeterCore
import AppKit
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController!
    private var updaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let vault = KeychainCredentialVault()
        let refresher = UsageRefresher(providers: Self.makeProviders(vault: vault))
        Task { await refresher.start() }
        // Sparkle auto-update (release builds point SUFeedURL at docs/appcast).
        updaterController = SPUStandardUpdaterController(startingUpdater: true,
                                                        updaterDelegate: nil,
                                                        userDriverDelegate: nil)
        statusController = StatusItemController(refresher: refresher, vault: vault,
                                               onCheckForUpdates: { [weak self] in
            self?.updaterController?.updater.checkForUpdates()
        })
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
            // auth.json live-read; a vault-imported token is the fallback when
            // ~/.codex/auth.json is missing (Deferred from M2, folded in here).
            CodexProvider(session: .shared,
                          tokenFallback: VaultCodexTokenFallback(vault: vault,
                                                                 providerID: CodexProvider.providerID)),
            // auth.json live-read preferred, imported key as fallback.
            OpenCodeProvider(session: .shared,
                             tokenSource: CompositeOpenCodeTokenSource([
                                 FileOpenCodeTokenSource(),
                                 VaultOpenCodeTokenSource(vault: vault, providerID: OpenCodeProvider.providerID),
                             ])),
            AntigravityProvider(),
            OllamaProvider(),
            ManualProvider(),
        ]
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
