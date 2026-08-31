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
        // Sparkle auto-update (release builds point SUFeedURL at docs/aimeter-appcast.xml).
        updaterController = SPUStandardUpdaterController(startingUpdater: true,
                                                        updaterDelegate: nil,
                                                        userDriverDelegate: nil)
        statusController = StatusItemController(refresher: refresher, vault: vault,
                                               onCheckForUpdates: { [weak self] in
            self?.updaterController?.updater.checkForUpdates()
        })
        statusController.install()
    }

    /// Live provider sessions use a short request timeout so a stalled remote
    /// endpoint (observed with Google oauth2/cloudcode-pa) fails in seconds
    /// instead of hanging the HUD for URLSession's 60s default.
    static func liveSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }

    /// Wires the credential sources per spec Decision 3: keychain live-read
    /// preferred, explicit import/paste fallback, plus Pi's own credential
    /// file for the auto-connect (File freshest > Pi > Vault on OpenCode;
    /// Ollama cloud key proves the ollama.com account).
    static func makeProviders(vault: any CredentialVault) -> [any AIProvider] {
        let piAuth = FilePiAuthSource()
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
            ClaudeProvider(session: liveSession(), tokenSource: claudeTokens),
            // auth.json live-read; a vault-imported token is the fallback when
            // ~/.codex/auth.json is missing (Deferred from M2, folded in here).
            CodexProvider(session: liveSession(),
                          tokenFallback: VaultCodexTokenFallback(vault: vault,
                                                                 providerID: CodexProvider.providerID)),
            // OpenCode CLI auth.json freshest > Pi's stored key > imported vault.
            OpenCodeProvider(session: liveSession(),
                             tokenSource: CompositeOpenCodeTokenSource([
                                 FileOpenCodeTokenSource(),
                                 PiOpenCodeTokenSource(auth: piAuth),
                                 VaultOpenCodeTokenSource(vault: vault, providerID: OpenCodeProvider.providerID),
                             ])),
            // Pi auto-connect: PiAntigravityTokenSource (inside the provider)
            // supplies the remote-OAuth credential when ~/.pi has the oauth
            // entry — probe (local LS) → Pi → keychain.
            AntigravityProvider(session: liveSession(), piAuth: piAuth),
            // Cloud (Pi ollama key) → .ok "Ollama Cloud"; else local daemon.
            OllamaProvider(cloudAuth: piAuth),
            ManualProvider(),
        ]
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
