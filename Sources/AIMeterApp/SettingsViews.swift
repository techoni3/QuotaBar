import AIMeterCore
import AppKit
import SwiftUI

/// Holds the Settings window alive between invocations.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "AIMeter Settings"
            window.contentView = NSHostingView(rootView: SettingsView())
            window.center()
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: false)
    }
}

/// M1 settings: stub rows persisted to UserDefaults.
struct SettingsView: View {
    @AppStorage(SettingsKeys.refreshIntervalSeconds) private var refreshInterval = SettingsDefaults.refreshIntervalSeconds
    @AppStorage(SettingsKeys.hotkeyDisplay) private var hotkeyDisplay = SettingsDefaults.hotkeyDisplay
    @AppStorage(SettingsKeys.credentialMethod(for: "claude")) private var claudeCredentialMethod = SettingsDefaults.credentialMethodKeychain

    var body: some View {
        Form {
            Section("Provider polling") {
                Stepper(value: $refreshInterval, in: 15...300, step: 5) {
                    LabeledContent {
                        Text("\(refreshInterval) s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } label: {
                        Text("Refresh interval")
                    }
                }
            }
            Section("General") {
                LabeledContent("Global hotkey") {
                    Text(hotkeyDisplay)
                        .foregroundStyle(.secondary)
                }
                Text("Hotkey recording arrives in M4.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Section("Providers") {
                Picker("Claude credentials", selection: $claudeCredentialMethod) {
                    Text("Keychain (live)").tag(SettingsDefaults.credentialMethodKeychain)
                    Text("Imported token").tag(SettingsDefaults.credentialMethodImport)
                }
                .pickerStyle(.segmented)
                LabeledContent("Codex") {
                    Text("Reads ~/.codex/auth.json")
                        .foregroundStyle(.secondary)
                }
                Text("Keychain (live) reads Claude Code's own keychain entry (system prompt on first launch); imported tokens live in AIMeter's own keychain item. Codex always reads its CLI auth file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 380, height: 300)
    }
}

enum SettingsKeys {
    static let refreshIntervalSeconds = "refreshIntervalSeconds"
    static let hotkeyDisplay = "hotkeyDisplay"
    static func credentialMethod(for provider: String) -> String { "credentialMethod.\(provider)" }
}

enum SettingsDefaults {
    static let refreshIntervalSeconds = 60
    static let hotkeyDisplay = "⌘⇧U"
    static let credentialMethodKeychain = "keychain"
    static let credentialMethodImport = "import"
}